<#
.SYNOPSIS
    Collects the pre-change state of a maintenance target and returns it as JSON.

.DESCRIPTION
    Called by the sysPatch role before any state change. Reports hardware
    identity, disk headroom, pending-reboot signals, uptime, and interactive
    logon sessions. The role decides from this whether the window may proceed.
    Read-only. Nothing here modifies the host.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

$result = [ordered]@{}

$result['hostname']       = $env:COMPUTERNAME
$result['collected_utc']  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# --- Hardware identity ------------------------------------------------------
$cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
$os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

$result['manufacturer'] = if ($cs)   { [string]$cs.Manufacturer } else { '' }
$result['model']        = if ($cs)   { [string]$cs.Model }        else { '' }
$result['service_tag']  = if ($bios) { [string]$bios.SerialNumber } else { '' }
$result['bios_version'] = if ($bios) { [string]$bios.SMBIOSBIOSVersion } else { '' }
$result['is_dell']      = ($result['manufacturer'] -match '(?i)dell')

$result['os_caption'] = if ($os) { [string]$os.Caption } else { '' }
$result['os_build']   = if ($os) { [string]$os.BuildNumber } else { '' }

# --- Uptime -----------------------------------------------------------------
if ($os -and $os.LastBootUpTime) {
    $result['last_boot_utc'] = $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $result['uptime_days']   = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
} else {
    $result['last_boot_utc'] = ''
    $result['uptime_days']   = 0
}

# --- Disk headroom ----------------------------------------------------------
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
if ($disk) {
    $result['disk_free_gb']  = [math]::Round($disk.FreeSpace / 1GB, 1)
    $result['disk_total_gb'] = [math]::Round($disk.Size / 1GB, 1)
} else {
    $result['disk_free_gb']  = 0
    $result['disk_total_gb'] = 0
}

# --- Pending reboot ---------------------------------------------------------
# Same signal set patchReady uses. 'Actionable' means a reboot will actually
# clear something, as opposed to a cosmetic pending-file-rename entry.
$pending    = $false
$actionable = $false
$reasons    = @()

if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    $pending = $true; $actionable = $true; $reasons += 'CBS:RebootPending'
}
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    $pending = $true; $actionable = $true; $reasons += 'WU:RebootRequired'
}
try {
    $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfr) { $pending = $true; $reasons += 'SessionMgr:PendingFileRename' }
} catch {}
try {
    $active  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $current = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $current -and $active -ne $current) { $pending = $true; $actionable = $true; $reasons += 'ComputerName:RenamePending' }
} catch {}

$result['reboot_pending']    = $pending
$result['reboot_actionable'] = $actionable
$result['reboot_reasons']    = @($reasons)

# --- Interactive sessions ---------------------------------------------------
# The chat check is the real control on "is anyone using this box". This is the
# backstop for the case where somebody is still signed in at RDP.
$sessions = @()
try {
    $quser = & quser.exe 2>$null
    if ($LASTEXITCODE -eq 0 -and $quser) {
        # Skip the header row; the leading '>' marks the caller's own session.
        foreach ($line in ($quser | Select-Object -Skip 1)) {
            $trimmed = $line.TrimStart('>', ' ')
            $fields  = $trimmed -split '\s{2,}'
            if ($fields.Count -ge 3) {
                $sessions += [ordered]@{
                    user       = $fields[0]
                    session    = $fields[1]
                    state      = $fields[$fields.Count - 3]
                    idle       = $fields[$fields.Count - 2]
                    logon_time = $fields[$fields.Count - 1]
                }
            }
        }
    }
} catch {}

$result['sessions']       = @($sessions)
$result['session_count']  = @($sessions).Count

# --- Windows Update service health -----------------------------------------
$wu = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
$result['wuauserv_status']     = if ($wu) { [string]$wu.Status } else { 'missing' }
$result['wuauserv_start_type'] = if ($wu) { [string]$wu.StartType } else { '' }

$result | ConvertTo-Json -Depth 5 -Compress
