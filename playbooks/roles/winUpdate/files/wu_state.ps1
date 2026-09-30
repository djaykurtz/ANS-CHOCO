<#
.SYNOPSIS
    Reports Windows Update client state and recent install history as JSON.

.DESCRIPTION
    Called by the winUpdate role before and after the install pass. Reports the
    Windows Update service state, the configured update source, pending-reboot
    signals, disk headroom, and the most recent installed updates. Read-only.

.PARAMETER HistoryCount
    How many history entries to return. Zero skips the history read, which is
    the slow part on a long-lived server.
#>
[CmdletBinding()]
param(
    [int] $HistoryCount = 25
)

$ErrorActionPreference = 'SilentlyContinue'

$result = [ordered]@{}
$result['hostname']     = $env:COMPUTERNAME
$result['collected_utc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# --- Update source ----------------------------------------------------------
# A host pointed at WSUS behaves very differently from one going to Microsoft
# Update, so the report always states which it was.
$wuPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$wsus     = (Get-ItemProperty $wuPolicy -Name WUServer -ErrorAction SilentlyContinue).WUServer
$useWsus  = (Get-ItemProperty "$wuPolicy\AU" -Name UseWUServer -ErrorAction SilentlyContinue).UseWUServer

$result['wsus_server'] = if ($wsus) { [string]$wsus } else { '' }
$result['update_source'] = if ($wsus -and $useWsus -eq 1) { 'WSUS' } else { 'Microsoft Update' }

# --- Service health ---------------------------------------------------------
$services = @{}
foreach ($name in @('wuauserv', 'bits', 'cryptsvc', 'trustedinstaller')) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    $services[$name] = if ($svc) {
        [ordered]@{ status = [string]$svc.Status; start_type = [string]$svc.StartType }
    } else {
        [ordered]@{ status = 'missing'; start_type = '' }
    }
}
$result['services'] = $services

# --- Pending reboot ---------------------------------------------------------
$reasons = @()
$actionable = $false
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    $reasons += 'CBS:RebootPending'; $actionable = $true
}
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    $reasons += 'WU:RebootRequired'; $actionable = $true
}
try {
    $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfr) { $reasons += 'SessionMgr:PendingFileRename' }
} catch {}

$result['reboot_pending']    = ($reasons.Count -gt 0)
$result['reboot_actionable'] = $actionable
$result['reboot_reasons']    = @($reasons)

# --- Disk headroom ----------------------------------------------------------
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
$result['disk_free_gb']  = if ($disk) { [math]::Round($disk.FreeSpace / 1GB, 1) } else { 0 }
$result['disk_total_gb'] = if ($disk) { [math]::Round($disk.Size / 1GB, 1) } else { 0 }

# --- Last boot --------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os -and $os.LastBootUpTime) {
    $result['last_boot_utc'] = $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $result['uptime_days']   = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
} else {
    $result['last_boot_utc'] = ''
    $result['uptime_days']   = 0
}

# --- Install history --------------------------------------------------------
# Read through the COM update session rather than Get-HotFix, because
# Get-HotFix misses everything that is not a classic QFE.
$history = @()
if ($HistoryCount -gt 0) {
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $total    = $searcher.GetTotalHistoryCount()
        if ($total -gt 0) {
            $take    = [Math]::Min($HistoryCount, $total)
            $entries = $searcher.QueryHistory(0, $take)
            foreach ($e in $entries) {
                # ResultCode 2 is succeeded, 3 is succeeded with errors, 4 is failed.
                $outcome = switch ([int]$e.ResultCode) {
                    2 { 'succeeded' }
                    3 { 'succeeded_with_errors' }
                    4 { 'failed' }
                    5 { 'aborted' }
                    default { 'unknown' }
                }
                $history += [ordered]@{
                    title       = [string]$e.Title
                    date_utc    = if ($e.Date) { $e.Date.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
                    result      = $outcome
                    result_code = [int]$e.ResultCode
                    operation   = [int]$e.Operation
                }
            }
        }
    } catch {
        $result['history_error'] = $_.Exception.Message
    }
}
$result['history'] = @($history)

$result | ConvertTo-Json -Depth 6 -Compress
