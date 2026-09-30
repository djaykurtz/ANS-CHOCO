<#
scan_python_state.ps1

READ-ONLY scan. Emits a single compact JSON object describing all
Python-related installs visible from the machine context. Use this to
plan vendor python remediation before running remove_vendor_python_track.ps1.

Does NOT scan HKEY_USERS (covered separately by chocoDeploy's HKU advisory).

OUTPUT
  {
    "host": "...",
    "collected_at": "ISO8601 UTC",
    "choco_pkgs": [ {"pkg":"python313","version":"3.13.5"}, ... ],
    "vendor_total": <int>,
    "by_track": [
      {
        "track": "3.10",
        "from_chocolatey": false,
        "component_count": 9,
        "has_parent": false,
        "patches_seen": ["0","11"],
        "sample_publisher": "Python Software Foundation"
      }, ...
    ],
    "python_in_path": [ "C:\\Python313\\python.exe", ... ]
  }

The fleet aggregator on the control node lives at:
  playbooks/roles/chocoDeploy/files/fleet_python_scan_summary.py
#>
$ErrorActionPreference = 'SilentlyContinue'

function NowIso { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

# --- Chocolatey-managed python packages ---
$chocoPkgs = @()
$chocoRaw  = & choco list --local-only --limit-output 2>$null
foreach ($ln in $chocoRaw) {
    if ($ln -match '^(python[0-9]*|python|python3)\|(.+)$') {
        $chocoPkgs += [pscustomobject]@{
            pkg     = $Matches[1]
            version = $Matches[2]
        }
    }
}

# --- HKLM uninstall registry: anything matching Python at start of DisplayName ---
$vendorEntries = @()
$paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($p in $paths) {
    Get-ItemProperty $p -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Python' } |
        ForEach-Object {
            $dn = "" + $_.DisplayName
            $track = $null
            $patch = $null
            $component = $null
            if ($dn -match '^Python\s+(\d+)\.(\d+)(?:\.(\d+))?(?:\s+(.+?))?\s*\((\d+)-bit(?:\s+symbols)?\)\s*$') {
                $track     = $Matches[1] + '.' + $Matches[2]
                $patch     = if ($Matches[3]) { $Matches[3] } else { $null }
                $component = if ($Matches[4]) { $Matches[4].Trim() } else { 'PARENT' }
            } elseif ($dn -match '^Python\s+(\d+)\.(\d+)(?:\.(\d+))?$') {
                $track     = $Matches[1] + '.' + $Matches[2]
                $patch     = if ($Matches[3]) { $Matches[3] } else { $null }
                $component = 'PARENT'
            }
            $vendorEntries += [pscustomobject]@{
                displayName     = $dn
                publisher       = ("" + $_.Publisher)
                displayVersion  = ("" + $_.DisplayVersion)
                productCode     = ("" + $_.PSChildName)
                installLocation = ("" + $_.InstallLocation)
                uninstallString = ("" + $_.UninstallString)
                track           = $track
                patch_version   = $patch
                component       = $component
                from_chocolatey = (("" + $_.Publisher) -match 'Chocolatey')
            }
        }
}

$byTrack = @{}
foreach ($v in $vendorEntries) {
    if (-not $v.track) { continue }
    $key = $v.track + '|' + ($v.from_chocolatey)
    if (-not $byTrack.ContainsKey($key)) {
        $byTrack[$key] = [pscustomobject]@{
            track            = $v.track
            from_chocolatey  = $v.from_chocolatey
            component_count  = 0
            has_parent       = $false
            patches_seen     = New-Object System.Collections.Generic.HashSet[string]
            sample_publisher = $v.publisher
        }
    }
    $g = $byTrack[$key]
    $g.component_count++
    if ($v.component -eq 'PARENT') { $g.has_parent = $true }
    if ($v.patch_version) { [void]$g.patches_seen.Add($v.patch_version) }
}

$pythonInPath = @()
Get-Command python -All -ErrorAction SilentlyContinue | ForEach-Object {
    $pythonInPath += ("" + $_.Source)
}

$payload = [ordered]@{
    host          = $env:COMPUTERNAME
    collected_at  = NowIso
    choco_pkgs    = @($chocoPkgs)
    vendor_total  = $vendorEntries.Count
    by_track      = @($byTrack.Values | ForEach-Object {
        [pscustomobject]@{
            track           = $_.track
            from_chocolatey = $_.from_chocolatey
            component_count = $_.component_count
            has_parent      = $_.has_parent
            patches_seen    = @($_.patches_seen)
            sample_publisher= $_.sample_publisher
        }
    })
    python_in_path = @($pythonInPath)
}

$payload | ConvertTo-Json -Depth 6 -Compress
