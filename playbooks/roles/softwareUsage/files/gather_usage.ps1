<#
gather_usage.ps1
================

Read Security event log EventID 4688 (process creation) over a lookback
window, bucket each event by the EXE basename against a tracked-apps catalog,
and emit a single JSON blob on stdout.

Inputs (passed in via Ansible script module args -- arrived as strings):
    -CatalogJson <json>      JSON of tracked_apps (list of {key,label,executables,notes})
    -LookbackDays <int>      e.g. 30
    -MinExecutions <int>     threshold for verdict "used_recently"
    -MaxDetailRows <int>     cap on (parent,user,cmdline) detail rows per app; 0 disables

Output (stdout, single JSON object):
    {
      "host":               "<hostname>",
      "collected_at":       "ISO8601 UTC",
      "lookback_days":      30,
      "audit_on":           bool,
      "cmdline_capture":    bool,
      "scan_duration_sec":  float,
      "events_examined":    int,
      "events_matched":     int,
      "apps": {
          "<key>": {
              "label":           "...",
              "executions":      int,
              "distinct_users":  int,
              "distinct_parents": int,
              "first":           "ISO8601 UTC" | null,
              "last":            "ISO8601 UTC" | null,
              "verdict":         "used_recently" | "unused_in_window" | "audit_off",
              "details": [
                  { "parent": "...", "user": "DOM\\user", "cmdline": "...", "count": int, "last": "..." },
                  ...
              ]
          }
      },
      "errors": [ ... ]
    }

Notes
-----
* Reads ONLY the Security log. Requires admin (the role's vault user is admin).
* "Audit Process Creation" must be enabled for Success events to exist. We
  probe via `auditpol /get /subcategory:"Process Creation"` (en-US labels).
* "Include command line in process creation events" GPO controls whether the
  CommandLine field is populated. We probe via the
  HKLM:\...\Policies\System\Audit!ProcessCreationIncludeCmdLine_Enabled
  registry value.
* Get-WinEvent FilterHashtable cannot pattern-match strings, so basename
  filtering is done in PowerShell after the per-event fetch. We still bound
  the read with StartTime + Id so we are not scanning months of log.
* Output is UTF-8 JSON on stdout. Write-Host / Write-Verbose are used for
  any human-readable noise (none in normal operation) so Ansible's win_shell
  capture stays clean.
#>

param(
    [Parameter(Mandatory=$true)][string]$CatalogJson,
    [int]$LookbackDays  = 30,
    [int]$MinExecutions = 2,
    [int]$MaxDetailRows = 25
)

$ErrorActionPreference = 'Stop'
$startedAt = Get-Date
$errors    = New-Object System.Collections.Generic.List[string]

function NowIso { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function ToIsoUtc($dt) {
    if ($null -eq $dt) { return $null }
    if ($dt -isnot [datetime]) {
        try { $dt = [datetime]$dt } catch { return $null }
    }
    return $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# ---------------------------------------------------------------------------
# Parse catalog
# ---------------------------------------------------------------------------
try {
    $catalog = $CatalogJson | ConvertFrom-Json
} catch {
    $errors.Add("Failed to parse CatalogJson: $($_.Exception.Message)")
    $catalog = @()
}

# Build a lookup: exe basename (lowercase) -> list of app keys
$exeToKeys = @{}
foreach ($app in $catalog) {
    foreach ($exe in $app.executables) {
        $k = $exe.ToLowerInvariant()
        if (-not $exeToKeys.ContainsKey($k)) { $exeToKeys[$k] = New-Object System.Collections.Generic.List[string] }
        $exeToKeys[$k].Add($app.key)
    }
}

# Pre-seed per-app accumulators
$appAccum = @{}
foreach ($app in $catalog) {
    $appAccum[$app.key] = [pscustomobject]@{
        label             = $app.label
        executions        = 0
        users             = New-Object System.Collections.Generic.HashSet[string]
        parents           = New-Object System.Collections.Generic.HashSet[string]
        first             = $null
        last              = $null
        # bucketed details: keyed by "$parent||$user||$cmdline"
        detail            = @{}
    }
}

# ---------------------------------------------------------------------------
# Probe audit policy
# ---------------------------------------------------------------------------
$auditOn        = $false
$cmdlineCapture = $false
try {
    # auditpol output looks like:
    #   System audit policy
    #   Category/Subcategory                      Setting
    #   Detailed Tracking
    #     Process Creation                          Success
    $apOut = & auditpol.exe /get /subcategory:"Process Creation" 2>$null
    if ($LASTEXITCODE -eq 0 -and $apOut) {
        foreach ($line in $apOut) {
            if ($line -match '(?i)Process Creation\s+(.*)$') {
                $setting = $Matches[1].Trim()
                if ($setting -match '(?i)Success') { $auditOn = $true }
            }
        }
    }
} catch {
    $errors.Add("auditpol probe failed: $($_.Exception.Message)")
}

try {
    $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' -Name 'ProcessCreationIncludeCmdLine_Enabled' -ErrorAction Stop
    if ($reg.ProcessCreationIncludeCmdLine_Enabled -eq 1) { $cmdlineCapture = $true }
} catch {
    # registry value not set -> off
}

# ---------------------------------------------------------------------------
# Read events (only if audit is on)
# ---------------------------------------------------------------------------
$eventsExamined = 0
$eventsMatched  = 0

if ($auditOn) {
    $start = (Get-Date).AddDays(-1 * [Math]::Abs($LookbackDays))
    $filter = @{ LogName = 'Security'; Id = 4688; StartTime = $start }

    # Property indexes for EventID 4688 (EventData):
    #   0  SubjectUserSid
    #   1  SubjectUserName
    #   2  SubjectDomainName
    #   3  SubjectLogonId
    #   4  NewProcessId
    #   5  NewProcessName     <-- full path to image
    #   6  TokenElevationType
    #   7  ProcessId          <-- parent PID
    #   8  CommandLine        (only when GPO enabled)
    #   9  TargetUserSid
    #  10  TargetUserName
    #  11  TargetDomainName
    #  12  TargetLogonId
    #  13  ParentProcessName  <-- full path to parent image
    try {
        # -Oldest forces server-side ordering and lets us page; large logs benefit.
        Get-WinEvent -FilterHashtable $filter -ErrorAction Stop | ForEach-Object {
            $eventsExamined++
            $props = $_.Properties
            if ($null -eq $props -or $props.Count -lt 6) { return }

            $imagePath = [string]$props[5].Value
            if (-not $imagePath) { return }
            $exeBase = [System.IO.Path]::GetFileName($imagePath).ToLowerInvariant()
            if (-not $exeToKeys.ContainsKey($exeBase)) { return }

            $eventsMatched++

            $user = if ($props.Count -ge 3) {
                $u = [string]$props[1].Value
                $d = [string]$props[2].Value
                if ($d) { "$d\$u" } else { $u }
            } else { '' }

            $parent = if ($props.Count -ge 14) {
                $pp = [string]$props[13].Value
                if ($pp) { [System.IO.Path]::GetFileName($pp) } else { '' }
            } else { '' }

            $cmdline = if ($cmdlineCapture -and $props.Count -ge 9) {
                [string]$props[8].Value
            } else { '' }

            $ts = $_.TimeCreated

            foreach ($key in $exeToKeys[$exeBase]) {
                $a = $appAccum[$key]
                $a.executions = $a.executions + 1
                [void]$a.users.Add($user)
                [void]$a.parents.Add($parent)
                if ($null -eq $a.first -or $ts -lt $a.first) { $a.first = $ts }
                if ($null -eq $a.last  -or $ts -gt $a.last)  { $a.last  = $ts }

                if ($MaxDetailRows -gt 0 -or $MaxDetailRows -eq -1) {
                    $detailKey = "$parent||$user||$cmdline"
                    if ($a.detail.ContainsKey($detailKey)) {
                        $row = $a.detail[$detailKey]
                        $row.count = $row.count + 1
                        if ($null -eq $row.last -or $ts -gt $row.last) { $row.last = $ts }
                    } else {
                        $a.detail[$detailKey] = [pscustomobject]@{
                            parent  = $parent
                            user    = $user
                            cmdline = $cmdline
                            count   = 1
                            last    = $ts
                        }
                    }
                }
            }
        }
    } catch {
        $errors.Add("Get-WinEvent failed: $($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------------------
# Build output
# ---------------------------------------------------------------------------
$appsOut = @{}
foreach ($app in $catalog) {
    $a = $appAccum[$app.key]
    $verdict = if (-not $auditOn) {
        'audit_off'
    } elseif ($a.executions -ge $MinExecutions) {
        'used_recently'
    } else {
        'unused_in_window'
    }

    # Sort details by count desc and cap.
    $detailRows = @($a.detail.Values | Sort-Object -Property count -Descending)
    if ($MaxDetailRows -gt 0 -and $detailRows.Count -gt $MaxDetailRows) {
        $detailRows = $detailRows[0..($MaxDetailRows - 1)]
    }
    $detailOut = foreach ($r in $detailRows) {
        @{
            parent  = $r.parent
            user    = $r.user
            cmdline = $r.cmdline
            count   = $r.count
            last    = ToIsoUtc $r.last
        }
    }

    $appsOut[$app.key] = @{
        label            = $a.label
        executions       = $a.executions
        distinct_users   = $a.users.Count
        distinct_parents = $a.parents.Count
        first            = ToIsoUtc $a.first
        last             = ToIsoUtc $a.last
        verdict          = $verdict
        details          = @($detailOut)
    }
}

$elapsed = (Get-Date) - $startedAt

$result = @{
    host              = $env:COMPUTERNAME
    collected_at      = NowIso
    lookback_days     = $LookbackDays
    min_executions    = $MinExecutions
    audit_on          = $auditOn
    cmdline_capture   = $cmdlineCapture
    scan_duration_sec = [math]::Round($elapsed.TotalSeconds, 2)
    events_examined   = $eventsExamined
    events_matched    = $eventsMatched
    apps              = $appsOut
    errors            = @($errors)
}

# Compact JSON keeps the WinRM payload small for big fleets.
$result | ConvertTo-Json -Depth 8 -Compress
