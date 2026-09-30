# nxlog_audit.ps1 -- read-only nxlog presence audit.
#
# Reports every trace of nxlog on the host and returns JSON. Changes nothing.
# Run before the purge to establish a baseline and after it to prove the host
# is clean. The 'clean' field is the single answer.

$ErrorActionPreference = 'SilentlyContinue'

$r = [ordered]@{}
$r['hostname'] = $env:COMPUTERNAME

# --- Service ---------------------------------------------------------------
$svc = Get-Service -Name 'nxlog' -ErrorAction SilentlyContinue
$r['service_present'] = [bool]$svc
$r['service_status'] = if ($svc) { [string]$svc.Status } else { '' }
$r['service_start_type'] = if ($svc) { [string]$svc.StartType } else { '' }

# --- Chocolatey package ----------------------------------------------------
$choco = ''
try {
    $out = & choco list --local-only --limit-output --exact nxlog 2>$null
    if ($out) { $choco = ($out | Out-String).Trim() }
} catch {}
$r['choco_package'] = $choco
$r['choco_present'] = ($choco -match 'nxlog')

# --- Uninstall registry ----------------------------------------------------
$paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$reg = @(
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '(?i)^nxlog' } |
        ForEach-Object {
            [ordered]@{
                display_name    = [string]$_.DisplayName
                display_version = [string]$_.DisplayVersion
                publisher       = [string]$_.Publisher
                uninstall       = [string]$_.UninstallString
            }
        }
)
$r['registry_entries'] = @($reg)
$r['registry_present'] = (@($reg).Count -gt 0)

# --- Files on disk ---------------------------------------------------------
# The config we deployed lives under conf\, and the shipper writes into data\.
# A package uninstall commonly leaves both behind.
$dirs = @('C:\Program Files\nxlog', 'C:\Program Files (x86)\nxlog', 'C:\ProgramData\nxlog')
$found = @()
foreach ($d in $dirs) {
    if (Test-Path -LiteralPath $d) {
        $files = Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue
        $found += [ordered]@{
            path       = $d
            file_count = @($files).Count
            size_mb    = [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 2)
            has_exe    = [bool](Test-Path -LiteralPath (Join-Path $d 'nxlog.exe'))
            has_conf   = [bool](Test-Path -LiteralPath (Join-Path $d 'conf\nxlog.conf'))
        }
    }
}
$r['directories'] = @($found)
$r['files_present'] = (@($found).Count -gt 0)

# --- Pending reboot --------------------------------------------------------
# Relevant because these hosts cannot be rebooted. A queued file rename means
# leftovers persist until a natural restart.
$reasons = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WU' }
$pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($pfr) {
    $reasons += 'PendingFileRename'
    $r['pending_rename_mentions_nxlog'] = [bool](($pfr -join "`n") -match '(?i)nxlog')
} else {
    $r['pending_rename_mentions_nxlog'] = $false
}
$r['reboot_pending'] = ($reasons.Count -gt 0)
$r['reboot_reasons'] = @($reasons)

# --- Verdict ---------------------------------------------------------------
$r['clean'] = (-not $r['service_present']) -and
              (-not $r['choco_present'])   -and
              (-not $r['registry_present']) -and
              (-not $r['files_present'])

$r | ConvertTo-Json -Depth 6 -Compress
