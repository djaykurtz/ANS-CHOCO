#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Reverses the test environment created by Setup-ChocoDeployTestEnv.ps1.

.DESCRIPTION
    Removes simulation artifacts:
    - Restores choco packages to current approved versions where they were downgraded
    - Reinstalls packages whose choco tracking was stripped
    - Removes the simulated pending reboot registry marker (if tagged)
    - Removes blacklisted test software

    This does NOT restore the exact pre-setup state. It brings the system to a
    clean baseline suitable for another test cycle.

.EXAMPLE
    .\Teardown-ChocoDeployTestEnv.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Scenario, [string]$Message)
    Write-Host "`n[$Scenario] $Message" -ForegroundColor Cyan
}

function Write-Done {
    param([string]$Message)
    Write-Host "  -> $Message" -ForegroundColor Green
}

Write-Host "========================================" -ForegroundColor White
Write-Host " chocoDeploy Test Environment Teardown" -ForegroundColor White
Write-Host " Target: $env:COMPUTERNAME" -ForegroundColor White
Write-Host " Date:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White


# --- Remove simulated pending reboot marker (only if we created it) ---
Write-Step "RebootMarker" "Removing simulated CBS RebootPending key"
$cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
if (Test-Path $cbsPath) {
    $marker = Get-ItemProperty -Path $cbsPath -Name '_ChocoDeployTestMarker' -ErrorAction SilentlyContinue
    if ($marker) {
        Remove-Item -Path $cbsPath -Recurse -Force
        Write-Done "Removed test CBS RebootPending marker"
    } else {
        Write-Done "CBS RebootPending exists but was NOT created by the test script -- leaving it"
    }
} else {
    Write-Done "No CBS RebootPending key found"
}


# --- Restore stripped choco packages ---
Write-Step "Restore" "Re-registering packages whose choco tracking was stripped"

# putty.install - reinstall to restore choco tracking
Write-Host "  Reinstalling putty.install to restore choco tracking..." -ForegroundColor Gray
choco install putty.install -y --force --ignore-checksums 2>&1 | Out-Null
Write-Done "putty.install restored to choco management"

# vim - reinstall to restore choco tracking
Write-Host "  Reinstalling vim to restore choco tracking..." -ForegroundColor Gray
choco install vim -y --force --ignore-checksums 2>&1 | Out-Null
Write-Done "vim restored to choco management"

# python313 - reinstall to restore choco tracking
Write-Host "  Reinstalling python313 to restore choco tracking..." -ForegroundColor Gray
choco install python313 -y --force --ignore-checksums 2>&1 | Out-Null
Write-Done "python313 restored to choco management"

# python3 metapackage
choco install python3 -y --force --ignore-checksums 2>&1 | Out-Null
Write-Done "python3 metapackage restored"


# --- Restore downgraded packages ---
Write-Step "Restore" "Upgrading packages that were downgraded"

Write-Host "  Upgrading greenshot..." -ForegroundColor Gray
choco upgrade greenshot -y --force --ignore-checksums 2>&1 | Out-Null
Write-Done "greenshot upgraded to latest"


# --- Remove conflict test packages ---
Write-Step "Cleanup" "Removing conflict test packages"

$conflicts = @('pycharm-community')
foreach ($pkg in $conflicts) {
    $output = choco list --local-only --exact --limit-output $pkg 2>$null
    if ($output) {
        choco uninstall $pkg -y --force 2>&1 | Out-Null
        Write-Done "Removed conflict package: $pkg"
    }
}


# --- Remove blacklisted test software ---
Write-Step "Cleanup" "Removing blacklisted test software"

@('notepadplusplus', 'notepadplusplus.install') | ForEach-Object {
    $output = choco list --local-only --exact --limit-output $_ 2>$null
    if ($output) {
        choco uninstall $_ -y --force 2>&1 | Out-Null
        Write-Done "Removed blacklisted: $_"
    }
}


# --- Reinstall winscp for completeness ---
Write-Step "Restore" "Reinstalling winscp.install"
choco install winscp.install -y --force --ignore-checksums 2>&1 | Out-Null
Write-Done "winscp.install restored"


# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host " Teardown Complete" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
$inventory = choco list --local-only --limit-output 2>$null
$inventory | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Write-Host "`n  Total: $($inventory.Count) packages" -ForegroundColor Gray
Write-Host "`nSystem is ready for another test cycle." -ForegroundColor Green
