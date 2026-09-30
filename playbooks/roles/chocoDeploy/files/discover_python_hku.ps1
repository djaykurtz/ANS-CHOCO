<#
discover_python_hku.ps1
=======================

READ-ONLY discovery of per-user Python installs across all loaded user
hives under HKEY_USERS. The HKLM-based pythonSweep does not see per-user
installs; this script lets the role surface them as an advisory without
removing anything.

Output (stdout, single JSON object):
    {
      "loaded_user_hives": <int>,
      "findings": [
          { "sid", "user", "displayName", "displayVersion", "track",
            "installLocation", "productCode" }, ...
      ]
    }

Cost: ~0.5-1s on a typical host; ~2-5s on a multi-session Terminal
Services host with many loaded user hives. The cost is in registry
enumeration; no disk I/O for values.
#>

$ErrorActionPreference = 'SilentlyContinue'

if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
    try { New-PSDrive -Name HKU -PSProvider Registry -Root 'HKEY_USERS' -ErrorAction Stop | Out-Null } catch {}
}

$hits = @()

# Only walk real interactive-user SIDs (S-1-5-21-...). Skip system SIDs,
# _Classes subkeys, and the .DEFAULT profile.
$userSids = @(Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue |
    Where-Object {
        $_.PSChildName -match '^S-1-5-21-' -and
        $_.PSChildName -notmatch '_Classes$'
    })

foreach ($sid in $userSids) {
    $sidName  = $sid.PSChildName
    $resolved = $null
    try {
        $sidObj   = New-Object System.Security.Principal.SecurityIdentifier($sidName)
        $resolved = $sidObj.Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        $resolved = $null
    }

    $unin = "Registry::HKEY_USERS\$sidName\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    Get-ItemProperty $unin -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -match '^Python\s+(\d+)\.(\d+)' -and
            $_.Publisher  -notmatch 'Chocolatey'
        } |
        ForEach-Object {
            if ($_.DisplayName -match '^Python\s+(\d+)\.(\d+)') {
                $track = "$($Matches[1]).$($Matches[2])"
                $hits += [pscustomobject]@{
                    sid             = $sidName
                    user            = $resolved
                    displayName     = $_.DisplayName
                    displayVersion  = $_.DisplayVersion
                    track           = $track
                    installLocation = $_.InstallLocation
                    productCode     = $_.PSChildName
                }
            }
        }
}

$payload = @{
    loaded_user_hives = $userSids.Count
    findings          = @($hits)
}

$payload | ConvertTo-Json -Depth 4 -Compress
