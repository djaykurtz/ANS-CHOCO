<#
remove_vendor_python_track.ps1

Surgically remove all "Python <TRACK>.*" components from HKLM uninstall
registry, regardless of how they got there. Designed for fleet remediation
when vendor Python installs (registered as 8-9 component MSIs per track)
need to be wiped without affecting other Python tracks or choco-managed
Python packages.

IMPORTANT BACKGROUND (see chocoDeploy_Guide.md / repo memory):
- Vendor Python installs from python.org register one MSI per feature
  (Core Interpreter, Standard Library, Tcl/Tk Support, Test Suite,
  Documentation, pip Bootstrap, Add to Path, Executables, etc.). There is
  NO single "parent" MSI or bundle entry visible in the Uninstall hive on
  hosts running silent installs.
- The python.org bundle EXE (the Burn bootstrapper) can technically uninstall
  these, but it depends on cached payloads in C:\ProgramData\Package Cache\
  that are routinely missing on fleet hosts. We have observed exit_code=1603
  failures from `python-X.Y.Z-amd64.exe /uninstall /quiet` on hosts where
  Package Cache was empty.
- `choco uninstall pythonXY` only works when Chocolatey installed the package
  itself (returns "Unable to find package" otherwise).
- The reliable cleanup path is: `msiexec /x <ProductCode>` for each component
  ProductCode found in the Uninstall hive. Most return 0 (success). Some
  components (typically pip Bootstrap and Tcl/Tk Support) include custom
  actions that fail with 1603 if their dependency chain is already broken
  (Core Interpreter removed first by msiexec). In that case the actual files
  are already gone; the orphan registry key is removed directly with
  Remove-Item to leave the host in a clean state.

PARAMETERS
  -Track   e.g. "3.10" -- the major.minor to remove. Case-insensitive.
  -DryRun  enumerate but don't remove.
  -LogDir  where to write per-component msiexec logs (default C:\Windows\Temp).

OUTPUT
  Single JSON object on stdout describing the action and results. Schema:
    {
      track, dry_run, started_at, finished_at,
      entries_before, entries_after, total_elapsed_sec,
      msiexec_succeeded, msiexec_failed_then_reg_deleted,
      msiexec_still_present, install_dirs_removed,
      details: [ {component, product_code, exit_code, action, sec}, ... ]
    }

EXIT
  0  on success (entries_after == 0)
  1  on partial (entries_after > 0)

DOES NOT TOUCH
  - Chocolatey's own package db. If you also need to clean choco's record
    after this (because choco installed the package but the components were
    already removed externally), follow with:
      choco uninstall pythonXY -y --skipautouninstaller --no-progress
  - Per-user (HKEY_USERS) installs. Use chocoDeploy's HKU advisory to find
    those; they require per-user remediation.
  - Other Python tracks. The track-anchored regex prevents cross-track removal.

#>
param(
    [Parameter(Mandatory=$true)][string]$Track,
    [switch]$DryRun,
    [string]$LogDir = 'C:\Windows\Temp'
)

$ErrorActionPreference = 'SilentlyContinue'
$started = Get-Date

# Escape the track for regex (3.10 -> 3\.10) so the dot is literal.
$trackEsc = [regex]::Escape($Track)
# DisplayName pattern: "Python 3.10 <component>" or "Python 3.10.11 <component>"
$matchPattern = "^Python\s+$trackEsc(?:\.\d+)?\s+"

function GetEntries {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($h in $hives) {
        Get-ItemProperty $h -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match $matchPattern }
    }
}

$entries = @(GetEntries)
$entriesBefore = $entries.Count

$details = @()
$msiOk = 0
$msiFailRegDel = 0
$msiStill = 0
$installDirsRemoved = @()

if (-not $DryRun) {
    foreach ($e in $entries) {
        $pc = $e.PSChildName
        $dn = $e.DisplayName
        $start = Get-Date
        $logArg = Join-Path $LogDir ("msi-uninstall-" + $pc.Trim('{','}') + ".log")
        $proc = Start-Process -FilePath msiexec.exe `
            -ArgumentList @('/x', $pc, '/qn', '/norestart', 'REBOOT=ReallySuppress', '/log', $logArg) `
            -Wait -PassThru -NoNewWindow
        $sec = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
        $action = 'msiexec_ok'
        if ($proc.ExitCode -ne 0) {
            # MSI failed (typically 1603 from a custom action that needs
            # the Core Interpreter which may already be gone). Files are
            # almost always gone too -- just remove the orphan registry
            # key in both hives so the host reports clean.
            $keyPath = Join-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' $pc
            $wow64KeyPath = Join-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' $pc
            Remove-Item -Path $keyPath -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $wow64KeyPath -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $keyPath) -and -not (Test-Path $wow64KeyPath)) {
                $action = 'msi_fail_reg_deleted'
                $msiFailRegDel++
            } else {
                $action = 'msi_fail_reg_persist'
                $msiStill++
            }
        } else {
            $msiOk++
        }
        $details += [pscustomobject]@{
            component    = $dn
            product_code = $pc
            exit_code    = $proc.ExitCode
            action       = $action
            sec          = $sec
        }
    }

    # Clean up empty install directories left behind by component removals.
    # Only remove if completely empty (operator hand-edits, .pyc caches, user
    # site-packages, etc. mean we must NEVER recursive-delete a non-empty dir).
    $trackNoDot = $Track -replace '\.',''
    $candidateDirs = @(
        "C:\Python$trackNoDot",
        "C:\Program Files\Python$trackNoDot",
        "C:\Program Files (x86)\Python$trackNoDot"
    )
    foreach ($d in $candidateDirs) {
        if (Test-Path $d) {
            $remaining = @(Get-ChildItem $d -Recurse -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item $d -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path $d)) { $installDirsRemoved += $d }
            } else {
                $installDirsRemoved += "$d (NOT_EMPTY -- left in place)"
            }
        }
    }
}

$entriesAfter = @(GetEntries).Count
$finished = Get-Date

$result = [ordered]@{
    track                              = $Track
    dry_run                            = [bool]$DryRun.IsPresent
    started_at                         = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    finished_at                        = $finished.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    entries_before                     = $entriesBefore
    entries_after                      = $entriesAfter
    total_elapsed_sec                  = [math]::Round(($finished - $started).TotalSeconds, 1)
    msiexec_succeeded                  = $msiOk
    msiexec_failed_then_reg_deleted    = $msiFailRegDel
    msiexec_still_present              = $msiStill
    install_dirs_removed               = @($installDirsRemoved)
    details                            = @($details)
}

$result | ConvertTo-Json -Depth 6 -Compress

if ($entriesAfter -gt 0) { exit 1 }
exit 0
