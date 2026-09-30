<#
.SYNOPSIS
    Runs the sysPatch verification catalog against the local host and returns
    the results as JSON.

.DESCRIPTION
    Called by the sysPatch role for runbook steps 6 through 9. Takes the
    verification catalog as JSON, evaluates every check, and returns a per-check
    verdict of pass, fail, warn, skipped, or delegated. Read-only. Nothing here
    starts, stops, or modifies anything on the host.

    Verdicts:
      pass       the check met its requirement
      fail       the check did not meet its requirement and critical is true
      warn       the check did not meet its requirement and critical is false
      skipped    the check could not run, for example a non-applicable type
      delegated  the check runs from the control node, not the target
      manual     the check is a human step that automation cannot assert. It
                 is carried into the report as an action item and never
                 reports pass or fail.

.PARAMETER CatalogJson
    JSON array of check definitions. See defaults/main.yml for the schema.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $CatalogJson
)

$ErrorActionPreference = 'SilentlyContinue'
$started = Get-Date

# Some corp endpoints still negotiate down. Pin TLS 1.2 so an HTTP check does
# not fail for a reason that has nothing to do with the application.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
} catch {}

$catalog = @($CatalogJson | ConvertFrom-Json)
$checks  = @()

function Get-Field {
    param($Obj, [string]$Name, $Default = $null)
    if ($Obj.PSObject.Properties.Name -contains $Name -and $null -ne $Obj.$Name) { return $Obj.$Name }
    return $Default
}

function New-Verdict {
    param([bool]$Ok, [bool]$Critical)
    if ($Ok) { return 'pass' }
    if ($Critical) { return 'fail' }
    return 'warn'
}

foreach ($item in $catalog) {

    $critical = [bool](Get-Field $item 'critical' $false)

    $row = [ordered]@{
        key      = [string](Get-Field $item 'key' 'unnamed')
        label    = [string](Get-Field $item 'label' (Get-Field $item 'key' 'unnamed'))
        type     = [string](Get-Field $item 'type' 'unknown')
        critical = $critical
        notes    = [string](Get-Field $item 'notes' '')
        verdict  = 'skipped'
        actual   = ''
        expected = ''
        detail   = ''
    }

    switch ($row['type']) {

        # -------------------------------------------------------------------
        'service' {
            $name  = [string](Get-Field $item 'name' '')
            $want  = [string](Get-Field $item 'state' 'Running')
            $row['expected'] = "$name = $want"

            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if (-not $svc) {
                $row['actual']  = 'not installed'
                $row['verdict'] = New-Verdict $false $critical
                $row['detail']  = "No service named '$name' on this host."
            } else {
                $row['actual']  = [string]$svc.Status
                $ok = ([string]$svc.Status -eq $want)
                $row['verdict'] = New-Verdict $ok $critical
                $row['detail']  = "DisplayName='$($svc.DisplayName)'; StartType=$($svc.StartType)"
            }
        }

        # -------------------------------------------------------------------
        'scheduled_task' {
            $path         = [string](Get-Field $item 'path' '')
            $requireReady = [bool](Get-Field $item 'require_ready' $true)
            $maxAge       = [int](Get-Field $item 'max_age_hours' 0)
            $expectResult = [int](Get-Field $item 'expect_result' 0)

            $bits = @()
            if ($requireReady) { $bits += 'State in (Ready, Running)' }
            if ($maxAge -gt 0) { $bits += "LastRunTime within ${maxAge}h" }
            $bits += "LastTaskResult = $expectResult"
            $row['expected'] = ($bits -join '; ')

            $task = Get-ScheduledTask -ErrorAction SilentlyContinue |
                    Where-Object { ($_.TaskPath + $_.TaskName) -eq $path } |
                    Select-Object -First 1

            if (-not $task) {
                $row['actual']  = 'not found'
                $row['verdict'] = New-Verdict $false $critical
                $row['detail']  = "No scheduled task at '$path'. Check the folder and the exact task name."
            } else {
                $info    = Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue
                $state   = [string]$task.State
                $lastRun = if ($info) { $info.LastRunTime } else { $null }
                $lastRes = if ($info) { [int]$info.LastTaskResult } else { $null }

                $ageHours = $null
                if ($lastRun -and $lastRun.Year -gt 1980) {
                    $ageHours = [math]::Round(((Get-Date) - $lastRun).TotalHours, 1)
                }

                $problems = @()
                if ($requireReady -and $state -notin @('Ready', 'Running')) { $problems += "state is $state" }
                if ($maxAge -gt 0) {
                    if ($null -eq $ageHours) { $problems += 'never run' }
                    elseif ($ageHours -gt $maxAge) { $problems += "last run ${ageHours}h ago" }
                }
                if ($null -ne $lastRes -and $lastRes -ne $expectResult) { $problems += "last result $lastRes" }

                $row['actual']  = "state=$state; last_run=$(if ($lastRun) { $lastRun.ToString('yyyy-MM-dd HH:mm') } else { 'never' }); last_result=$lastRes"
                $row['verdict'] = New-Verdict ($problems.Count -eq 0) $critical
                $row['detail']  = if ($problems.Count -eq 0) { 'All conditions met.' } else { ($problems -join '; ') }
            }
        }

        # -------------------------------------------------------------------
        'http' {
            $from = [string](Get-Field $item 'from' 'target')
            if ($from -eq 'control') {
                $row['verdict'] = 'delegated'
                $row['detail']  = 'Probed from the control node by the role, not from the target.'
                break
            }

            $url        = [string](Get-Field $item 'url' '')
            $wantStatus = [int](Get-Field $item 'status' 200)
            $match      = [string](Get-Field $item 'match' '')
            $validate   = [bool](Get-Field $item 'validate_certs' $true)

            $row['expected'] = "HTTP $wantStatus from $url" + $(if ($match) { " containing '$match'" } else { '' })

            $priorCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
            if (-not $validate) {
                [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            }

            try {
                $sw   = [Diagnostics.Stopwatch]::StartNew()
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 45 -MaximumRedirection 5
                $sw.Stop()

                $status = [int]$resp.StatusCode
                $body   = [string]$resp.Content

                $problems = @()
                if ($status -ne $wantStatus) { $problems += "status $status" }
                if ($match -and ($body -notmatch [regex]::Escape($match))) { $problems += "body did not contain '$match'" }

                $row['actual']  = "HTTP $status in $([math]::Round($sw.Elapsed.TotalMilliseconds)) ms"
                $row['verdict'] = New-Verdict ($problems.Count -eq 0) $critical
                $row['detail']  = if ($problems.Count -eq 0) { 'Endpoint responded as expected.' } else { ($problems -join '; ') }
            } catch {
                $row['actual']  = 'request failed'
                $row['verdict'] = New-Verdict $false $critical
                $row['detail']  = $_.Exception.Message
            } finally {
                [Net.ServicePointManager]::ServerCertificateValidationCallback = $priorCallback
            }
        }

        # -------------------------------------------------------------------
        'log_freshness' {
            $path   = [string](Get-Field $item 'path' '')
            $maxAge = [int](Get-Field $item 'max_age_hours' 24)
            $match  = [string](Get-Field $item 'match' '')

            $row['expected'] = "A file under $path written within ${maxAge}h" + $(if ($match) { " matching /$match/" } else { '' })

            if (-not (Test-Path -LiteralPath $path)) {
                $row['actual']  = 'path not found'
                $row['verdict'] = New-Verdict $false $critical
                $row['detail']  = "'$path' does not exist. Point this check at the artifact the job actually writes."
                break
            }

            $newest = if ((Get-Item -LiteralPath $path).PSIsContainer) {
                Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
            } else {
                Get-Item -LiteralPath $path
            }

            if (-not $newest) {
                $row['actual']  = 'no files'
                $row['verdict'] = New-Verdict $false $critical
                $row['detail']  = "'$path' contains no files."
                break
            }

            $ageHours = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalHours, 1)
            $problems = @()
            if ($ageHours -gt $maxAge) { $problems += "newest file is ${ageHours}h old" }
            if ($match) {
                $content = Get-Content -LiteralPath $newest.FullName -Tail 400 -ErrorAction SilentlyContinue
                if (-not ($content -match $match)) { $problems += "no line matched /$match/" }
            }

            $row['actual']  = "$($newest.Name) written $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) (${ageHours}h ago)"
            $row['verdict'] = New-Verdict ($problems.Count -eq 0) $critical
            $row['detail']  = if ($problems.Count -eq 0) { 'Artifact is fresh.' } else { ($problems -join '; ') }
        }

        # -------------------------------------------------------------------
        # A human step. Verifying end-to-end mail delivery is the canonical
        # case. The role refuses to imply it checked something it did not.
        'manual' {
            $row['verdict']  = 'manual'
            $row['expected'] = [string](Get-Field $item 'instruction' 'Operator confirmation required.')
            $row['actual']   = 'not automated'
            $row['detail']   = 'Carried into the report as an operator action item.'
        }

        # -------------------------------------------------------------------
        default {
            $row['verdict'] = 'skipped'
            $row['detail']  = "Unsupported check type '$($row['type'])'."
        }
    }

    $checks += $row
}

$summary = [ordered]@{
    hostname         = $env:COMPUTERNAME
    checked_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    duration_sec     = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    total            = @($checks).Count
    passed           = @($checks | Where-Object { $_.verdict -eq 'pass' }).Count
    failed           = @($checks | Where-Object { $_.verdict -eq 'fail' }).Count
    warned           = @($checks | Where-Object { $_.verdict -eq 'warn' }).Count
    skipped          = @($checks | Where-Object { $_.verdict -eq 'skipped' }).Count
    delegated        = @($checks | Where-Object { $_.verdict -eq 'delegated' }).Count
    manual           = @($checks | Where-Object { $_.verdict -eq 'manual' }).Count
    checks           = @($checks)
}

$summary | ConvertTo-Json -Depth 6 -Compress
