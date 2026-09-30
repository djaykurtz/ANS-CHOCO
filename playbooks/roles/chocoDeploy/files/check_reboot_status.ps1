<#
.SYNOPSIS
Classify Windows pending-reboot indicators as HARD vs SOFT.

.DESCRIPTION
Companion to chocoDeploy's rebootStatus.yml. Reads the well-known reboot
markers and emits a single JSON line for Ansible to parse.

Classification:
  HARD reasons genuinely block or risk MSI/installer operations:
    - CBS:RebootPending           servicing stack pending; new MSI installs
                                  can fail or leave the host broken
    - SCM:UpdateExeVolatile        mid-install marker; another installer
                                  is racing or crashed
    - ComputerName:RenamePending   active vs target name differ;
                                  breaks anything that resolves
                                  machine name at install time

  SOFT reasons are informational and DO NOT block normal installs:
    - WU:RebootRequired            WU has staged work; compounds the
                                  servicing backlog but does not block
                                  third-party installs
    - SessionMgr:PendingFileRenameOperations   queued renames from a
                                  prior install. Most apps -- Docker
                                  Desktop especially -- leave PFRO on
                                  every install. Routine and safe.

Emits compact JSON: {PendingReboot, Reasons[], HardReasons[], SoftReasons[],
Hard, Actionable}. Actionable is kept as alias for Hard for back-compat with
the main.yml skip gate.

.NOTES
Written as a script-on-disk because complex inline PowerShell in win_shell
trips Ansible's Jinja/quote splitter (documented chocoDeploy gotcha).
#>
$ErrorActionPreference = 'SilentlyContinue'
$reasons = @()

# ---- HARD reasons ----
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
  $reasons += 'CBS:RebootPending'
}

$scmPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
try {
  $uev = (Get-ItemProperty -Path $scmPath -Name UpdateExeVolatile -ErrorAction SilentlyContinue).UpdateExeVolatile
  if ($null -ne $uev -and [int]$uev -ne 0) {
    $reasons += 'SCM:UpdateExeVolatile'
  }
} catch {}

$activeNamePath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'
$currentNamePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
try {
  $active  = (Get-ItemProperty -Path $activeNamePath  -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
  $current = (Get-ItemProperty -Path $currentNamePath -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
  if ($active -and $current -and ($active -ne $current)) {
    $reasons += 'ComputerName:RenamePending'
  }
} catch {}

# ---- SOFT reasons ----
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
  $reasons += 'WU:RebootRequired'
}

try {
  $pendingRename = (Get-ItemProperty -Path $scmPath -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
  if ($pendingRename) {
    $reasons += 'SessionMgr:PendingFileRenameOperations'
  }
} catch {}

$hardPattern = 'CBS:|SCM:|ComputerName:'
$hard = @($reasons | Where-Object { $_ -match $hardPattern })
$soft = @($reasons | Where-Object { $_ -notmatch $hardPattern })

[pscustomobject]@{
  PendingReboot = ($reasons.Count -gt 0)
  Reasons       = $reasons
  HardReasons   = $hard
  SoftReasons   = $soft
  Hard          = ($hard.Count -gt 0)
  Actionable    = ($hard.Count -gt 0)
} | ConvertTo-Json -Compress
