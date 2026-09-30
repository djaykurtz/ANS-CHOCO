<#
.SYNOPSIS
    Runs the Dell update CLI on the target and returns the outcome as JSON.

.DESCRIPTION
    Called by the sysPatch role for runbook step 3. Resolves the first Dell
    update executable that exists from a candidate list, runs it, and returns
    the exit code, the captured output, and a verdict. Returns a skipped
    verdict instead of failing when no Dell tool is present.

    Reboot requirement is read back from the pending-reboot registry keys after
    the run rather than inferred from the exit code, because the code tables
    differ between DSU and Dell Command Update and between versions.

.PARAMETER CandidatesJson
    JSON array of absolute paths to try, in order.

.PARAMETER DsuArgs
    Argument string used when the resolved executable is dsu.exe.

.PARAMETER DcuArgs
    Argument string used when the resolved executable is dcu-cli.exe.

.PARAMETER SuccessCodesJson
    JSON array of exit codes treated as success. Defaults cover "applied
    updates" and "no applicable updates".

.PARAMETER AuditOnly
    Report what would be applied and change nothing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $CandidatesJson,
    [string] $DsuArgs          = '--non-interactive --apply-upgrades',
    [string] $DcuArgs          = '/applyUpdates -reboot=disable -silent',
    [string] $SuccessCodesJson = '[0,1,5,500]',
    [switch] $AuditOnly
)

$ErrorActionPreference = 'Stop'

$result = [ordered]@{
    verdict         = 'unknown'
    executable      = ''
    flavor          = ''
    arguments       = ''
    exit_code       = $null
    audit_only      = [bool]$AuditOnly
    reboot_required = $false
    reboot_reasons  = @()
    duration_sec    = 0
    output          = ''
    message         = ''
}

function Get-PendingReboot {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'CBS:RebootPending'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'WU:RebootRequired'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Dell\UpdateService\Clients\CommandUpdate\Preferences') {
        # Dell Command Update records its own pending state under this key.
        $p = Get-ItemProperty 'HKLM:\SOFTWARE\Dell\UpdateService\Clients\CommandUpdate\Preferences' -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties.Name -contains 'RebootRequired' -and $p.RebootRequired) {
            $reasons += 'DCU:RebootRequired'
        }
    }
    return @($reasons)
}

# --- Resolve the executable -------------------------------------------------
$candidates = @($CandidatesJson | ConvertFrom-Json)
$exe = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { $exe = $c; break }
}

if (-not $exe) {
    $result['verdict'] = 'skipped'
    $result['message'] = "No Dell update tool found. Tried: " + ($candidates -join '; ')
    $result | ConvertTo-Json -Depth 5 -Compress
    return
}

$result['executable'] = $exe
$leaf = Split-Path -Leaf $exe

if ($leaf -match '(?i)^dcu-cli') {
    $result['flavor'] = 'dcu'
    $arguments = if ($AuditOnly) { '/scan -silent' } else { $DcuArgs }
} else {
    $result['flavor'] = 'dsu'
    $arguments = if ($AuditOnly) { '--non-interactive --preview' } else { $DsuArgs }
}
$result['arguments'] = $arguments

# --- Run --------------------------------------------------------------------
$stdoutFile = Join-Path $env:TEMP ('sysPatch_dsu_out_' + [guid]::NewGuid().ToString('N') + '.log')
$stderrFile = Join-Path $env:TEMP ('sysPatch_dsu_err_' + [guid]::NewGuid().ToString('N') + '.log')
$started    = Get-Date

try {
    $proc = Start-Process -FilePath $exe `
                          -ArgumentList $arguments `
                          -Wait -PassThru -NoNewWindow `
                          -RedirectStandardOutput $stdoutFile `
                          -RedirectStandardError  $stderrFile
    $code = $proc.ExitCode
} catch {
    $result['verdict'] = 'error'
    $result['message'] = "Failed to start $exe : $($_.Exception.Message)"
    $result | ConvertTo-Json -Depth 5 -Compress
    return
}

$result['duration_sec'] = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
$result['exit_code']    = $code

$out = ''
if (Test-Path $stdoutFile) { $out += (Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue) }
if (Test-Path $stderrFile) {
    $err = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
    if ($err -and $err.Trim()) { $out += "`n[stderr]`n" + $err }
}
Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue

# Keep the tail. These tools are chatty and the interesting lines are last.
$out = if ($out) { $out.Trim() } else { '' }
if ($out.Length -gt 8000) { $out = '...[truncated]...' + $out.Substring($out.Length - 8000) }
$result['output'] = $out

# --- Verdict ----------------------------------------------------------------
$successCodes = @($SuccessCodesJson | ConvertFrom-Json)
if ($successCodes -contains $code) {
    $result['verdict'] = if ($AuditOnly) { 'audited' } else { 'ok' }
    $result['message'] = "$leaf exited $code."
} else {
    $result['verdict'] = 'error'
    $result['message'] = "$leaf exited $code, which is not in the configured success set ($($successCodes -join ', ')). Review the output."
}

$reasons = Get-PendingReboot
$result['reboot_reasons']  = $reasons
$result['reboot_required'] = ($reasons.Count -gt 0)

$result | ConvertTo-Json -Depth 5 -Compress
