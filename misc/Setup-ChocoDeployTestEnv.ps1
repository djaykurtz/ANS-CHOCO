#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Stages test-host-01 as a diverse test environment for the chocoDeploy Ansible role.

.DESCRIPTION
    Creates a variety of software install states that exercise every major code path
    in the chocoDeploy role:

    - NoChange:   apps already at/above approved version (git, docker-desktop, 7zip)
    - Upgrade:    choco-managed apps below approved version (greenshot, vscode)
    - Convert:    vendor/MSI installs with no choco tracking (putty, vim)
    - Conflict:   old/wrong choco package names (pycharm-community)
    - Install:    app completely absent (winscp) - only hit in baseline mode
    - Remove:     blacklisted software present (notepad++)
    - RuntimeUp:  choco-owned runtime below minimum (powershell-core)
    - RuntimeCvt: vendor-installed runtime, no choco ownership (python)
    - RuntimeOK:  runtime already aligned (dotnet aspnetruntime)
    - RebootAdv:  simulated pending reboot registry marker

    Run this script ONCE on the target before exercising the role.
    Use Teardown-ChocoDeployTestEnv.ps1 to undo the simulation artifacts.

.PARAMETER SkipRebootMarker
    Skip creating the simulated pending-reboot registry key.

.EXAMPLE
    .\Setup-ChocoDeployTestEnv.ps1
    .\Setup-ChocoDeployTestEnv.ps1 -SkipRebootMarker
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipRebootMarker
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
function Write-Step {
    param([string]$Scenario, [string]$Message)
    Write-Host "`n[$Scenario] $Message" -ForegroundColor Cyan
}

function Write-Done {
    param([string]$Message)
    Write-Host "  -> $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "  -> SKIP: $Message" -ForegroundColor Yellow
}

function Remove-ChocoTracking {
    <#
    .SYNOPSIS
        Removes Chocolatey's knowledge of a package while leaving the actual
        installed software in place. This makes the app appear as a vendor/MSI
        install that chocoDeploy must detect via registry patterns and convert.
    #>
    param([string]$PackageName)

    $libPath = Join-Path $env:ChocolateyInstall "lib\$PackageName"
    $badPath = Join-Path $env:ChocolateyInstall ".chocolatey\$PackageName"

    if (Test-Path $libPath) {
        Remove-Item $libPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Done "Removed choco lib tracking: $libPath"
    }
    if (Test-Path $badPath) {
        Remove-Item $badPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Done "Removed choco .chocolatey tracking: $badPath"
    }
    # Also clear the choco cache entry if present
    $cachePath = Join-Path $env:ChocolateyInstall "cache\$PackageName"
    if (Test-Path $cachePath) {
        Remove-Item $cachePath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Done "Removed choco cache: $cachePath"
    }
}

function Get-ChocoPackageVersion {
    param([string]$PackageName)
    $output = choco list --local-only --exact --limit-output $PackageName 2>$null
    if ($output -match "^$([regex]::Escape($PackageName))\|(.+)$") {
        return $Matches[1].Trim()
    }
    return $null
}

# -------------------------------------------------------------------
# Pre-flight
# -------------------------------------------------------------------
Write-Host "========================================" -ForegroundColor White
Write-Host " chocoDeploy Test Environment Setup" -ForegroundColor White
Write-Host " Target: $env:COMPUTERNAME" -ForegroundColor White
Write-Host " Date:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White

if (-not $env:ChocolateyInstall) {
    throw "Chocolatey is not installed. Cannot proceed."
}

Write-Host "`nCapturing pre-setup inventory..." -ForegroundColor Gray
$preInventory = choco list --local-only --limit-output 2>$null
Write-Host "  $($preInventory.Count) packages currently installed." -ForegroundColor Gray


# ===================================================================
# SCENARIO 1: NoChange -- already at approved version
# Apps: git, docker-desktop, 7zip.install
# Action: leave untouched
# ===================================================================
Write-Step "NoChange" "git, docker-desktop, 7zip.install -- leaving at current approved versions"
@('git', 'docker-desktop', '7zip.install') | ForEach-Object {
    $ver = Get-ChocoPackageVersion $_
    if ($ver) {
        Write-Done "$_ $ver -- already installed, keeping as-is"
    } else {
        Write-Skip "$_ -- not installed; chocoDeploy will handle it"
    }
}


# ===================================================================
# SCENARIO 2: Upgrade -- choco-managed but below minimum
# App: greenshot (approved min 1.3.312)
# Action: downgrade to 1.2.10.6
# ===================================================================
Write-Step "Upgrade" "greenshot -- downgrading to 1.2.10.6 (approved min is 1.3.312)"

$greenshotVer = Get-ChocoPackageVersion 'greenshot'
if ($greenshotVer) {
    Write-Host "  Current greenshot: $greenshotVer -- removing first..." -ForegroundColor Gray
    choco uninstall greenshot -y --force 2>&1 | Out-Null
}
choco install greenshot --version 1.2.10.6 -y --allow-downgrade --force --ignore-checksums 2>&1 | Out-Null
$newVer = Get-ChocoPackageVersion 'greenshot'
Write-Done "greenshot now at $newVer (chocoDeploy should upgrade to >= 1.3.312)"


# ===================================================================
# SCENARIO 3: Upgrade -- vscode already below minimum naturally
# App: vscode.install (approved min 1.111.0, currently 1.106.3)
# Action: verify it is below, no action needed
# ===================================================================
Write-Step "Upgrade" "vscode.install -- verifying below approved minimum"

$vscodeVer = Get-ChocoPackageVersion 'vscode.install'
if ($vscodeVer) {
    Write-Done "vscode.install at $vscodeVer (approved min is 1.111.0 -- upgrade expected)"
} else {
    Write-Skip "vscode.install not found -- chocoDeploy will handle it in baseline"
}
# Also remove the bare 'vscode' metapackage if present to keep things clean
$vscodeMeta = Get-ChocoPackageVersion 'vscode'
if ($vscodeMeta) {
    Write-Host "  Removing bare 'vscode' metapackage to avoid confusion..." -ForegroundColor Gray
    choco uninstall vscode -y --force 2>&1 | Out-Null
    Write-Done "Removed bare 'vscode' metapackage"
}


# ===================================================================
# SCENARIO 4: Convert -- vendor-only PuTTY (no choco tracking)
# App: putty.install (approved min 0.83.0)
# Action: install old version via choco, then strip choco tracking,
#         leaving the vendor install in-place for registry detection
# ===================================================================
Write-Step "Convert" "putty -- creating vendor-only install (no choco tracking)"

# Ensure we have an OLD version installed, then strip tracking
$puttyVer = Get-ChocoPackageVersion 'putty.install'
if ($puttyVer) {
    Write-Host "  Current putty.install: $puttyVer -- removing choco package first..." -ForegroundColor Gray
    choco uninstall putty.install -y --force 2>&1 | Out-Null
}
Write-Host "  Installing putty.install 0.81 via choco (old version for conversion test)..." -ForegroundColor Gray
choco install putty.install --version 0.81 -y --force --allow-downgrade --ignore-checksums 2>&1 | Out-Null
# Also remove any portable/bare putty packages
@('putty', 'putty.portable') | ForEach-Object {
    $v = Get-ChocoPackageVersion $_
    if ($v) { choco uninstall $_ -y --force 2>&1 | Out-Null }
}
# Strip choco's knowledge -- leaves the actual PuTTY installed in Program Files
Remove-ChocoTracking -PackageName 'putty.install'
$puttyCheck = Get-ChocoPackageVersion 'putty.install'
if (-not $puttyCheck) {
    Write-Done "putty.install choco tracking removed -- vendor install remains in registry"
    Write-Done "chocoDeploy should detect via registry pattern 'putty', remove vendor, install choco"
} else {
    Write-Skip "Could not fully strip choco tracking for putty.install ($puttyCheck)"
}


# ===================================================================
# SCENARIO 5: Convert -- vendor-only Vim (no choco tracking)
# App: vim (approved min 9.1.2130)
# Action: install via choco, then strip choco tracking
# ===================================================================
Write-Step "Convert" "vim -- creating vendor-only install (no choco tracking)"

# Ensure vim is installed (any version) then strip tracking
$vimVer = Get-ChocoPackageVersion 'vim'
$vimTuxVer = Get-ChocoPackageVersion 'vim-tux.install'
if (-not $vimVer -and -not $vimTuxVer) {
    Write-Host "  Installing vim via choco (will strip tracking after)..." -ForegroundColor Gray
    choco install vim -y --force --ignore-checksums 2>&1 | Out-Null
}
# Strip choco tracking
Remove-ChocoTracking -PackageName 'vim'
Remove-ChocoTracking -PackageName 'vim-tux.install'
$vimCheck = Get-ChocoPackageVersion 'vim'
if (-not $vimCheck) {
    Write-Done "vim choco tracking removed -- vendor gvim/vim install remains in registry"
    Write-Done "chocoDeploy should detect via registry patterns '^vim' / 'gvim'"
} else {
    Write-Skip "Could not fully strip choco tracking for vim ($vimCheck)"
}


# ===================================================================
# SCENARIO 6: Conflict -- old pycharm-community package
# App: pycharm (approved min 2025.3.3)
# Action: install pycharm-community via choco (conflict for unified pycharm pkg)
# ===================================================================
Write-Step "Conflict" "pycharm -- installing conflict package 'pycharm-community'"

# Remove unified pycharm if present
$pycharmVer = Get-ChocoPackageVersion 'pycharm'
if ($pycharmVer) {
    Write-Host "  Removing existing 'pycharm' package first..." -ForegroundColor Gray
    choco uninstall pycharm -y --force 2>&1 | Out-Null
}
# Install the old conflict package name
Write-Host "  Installing pycharm-community (old package name)..." -ForegroundColor Gray
choco install pycharm-community -y --force --ignore-checksums 2>&1 | Out-Null
$pcVer = Get-ChocoPackageVersion 'pycharm-community'
if ($pcVer) {
    Write-Done "pycharm-community at $pcVer -- chocoDeploy should remove conflict, install 'pycharm'"
} else {
    Write-Skip "pycharm-community install may have failed -- check manually"
}


# ===================================================================
# SCENARIO 7: Install (baseline only) -- winscp completely absent
# App: winscp.install (approved min 6.5.5)
# Action: remove all winscp packages and any vendor install
# ===================================================================
Write-Step "Install" "winscp -- removing completely for baseline fresh-install test"

@('winscp', 'winscp.install') | ForEach-Object {
    $v = Get-ChocoPackageVersion $_
    if ($v) {
        choco uninstall $_ -y --force 2>&1 | Out-Null
        Write-Done "Removed $_ ($v)"
    }
}
# Belt-and-suspenders: kill any vendor winscp from registry
$winscpReg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'winscp' }
if ($winscpReg) {
    foreach ($entry in $winscpReg) {
        if ($entry.QuietUninstallString) {
            cmd.exe /c $entry.QuietUninstallString 2>$null
        } elseif ($entry.UninstallString) {
            cmd.exe /c $entry.UninstallString /VERYSILENT 2>$null
        }
    }
    Write-Done "Removed vendor WinSCP install(s)"
} else {
    Write-Done "No vendor WinSCP found"
}
Write-Done "winscp completely absent -- baseline mode should install, conversion should skip"


# ===================================================================
# SCENARIO 8: Remove -- blacklisted Notepad++ present
# App: notepadplusplus (in choco_always_remove_catalog)
# Action: install via choco
# ===================================================================
Write-Step "Remove" "notepad++ -- installing blacklisted software"

$nppVer = Get-ChocoPackageVersion 'notepadplusplus'
$nppInstVer = Get-ChocoPackageVersion 'notepadplusplus.install'
if (-not $nppVer -and -not $nppInstVer) {
    choco install notepadplusplus -y --force --ignore-checksums 2>&1 | Out-Null
    $nppVer = Get-ChocoPackageVersion 'notepadplusplus'
}
if ($nppVer -or $nppInstVer) {
    $nppDisplay = if ($nppVer) { $nppVer } else { $nppInstVer }
    Write-Done "notepadplusplus at $nppDisplay -- chocoDeploy should remove this"
} else {
    Write-Skip "notepad++ install may have failed -- check manually"
}


# ===================================================================
# SCENARIO 9: Runtime Upgrade -- powershell-core below minimum
# Runtime: powershell-core (approved min 7.5.6, currently 7.5.4)
# Action: verify it is below, no action needed
# ===================================================================
Write-Step "RuntimeUpgrade" "powershell-core -- verifying below approved minimum"

$pwshVer = Get-ChocoPackageVersion 'powershell-core'
if ($pwshVer) {
    Write-Done "powershell-core at $pwshVer (approved min is 7.5.6 -- upgrade expected when targeted)"
} else {
    Write-Done "powershell-core not found -- chocoDeploy will install if targeted in baseline mode"
}


# ===================================================================
# SCENARIO 10: Runtime Convert -- vendor Python (no choco tracking)
# Runtime: python313 (approved min 3.13.5)
# Action: strip choco tracking for python packages, leave vendor install
# ===================================================================
Write-Step "RuntimeConvert" "python -- creating vendor-only runtime install"

$py313Ver = Get-ChocoPackageVersion 'python313'
if ($py313Ver) {
    Write-Host "  Current python313: $py313Ver" -ForegroundColor Gray
}
# Strip choco tracking -- leaves the actual python install
Remove-ChocoTracking -PackageName 'python313'
Remove-ChocoTracking -PackageName 'python3'
$pyCheck = Get-ChocoPackageVersion 'python313'
if (-not $pyCheck) {
    Write-Done "python313 choco tracking removed -- vendor python remains on disk/registry"
    Write-Done "pythonAlign should detect via registry 'Python' pattern and convert"
} else {
    Write-Skip "Could not fully strip choco tracking for python313 ($pyCheck)"
}


# ===================================================================
# SCENARIO 11: Runtime OK -- .NET aspnetruntime already aligned
# Runtime: dotnet-10.0-aspnetruntime (approved min 10.0.1)
# Action: leave as-is
# ===================================================================
Write-Step "RuntimeOK" "dotnet aspnetruntime -- leaving at approved version"

$dotnetVer = Get-ChocoPackageVersion 'dotnet-10.0-aspnetruntime'
if ($dotnetVer) {
    Write-Done "dotnet-10.0-aspnetruntime at $dotnetVer -- no change expected"
} else {
    Write-Done "dotnet-10.0-aspnetruntime not found -- will be installed if targeted"
}


# ===================================================================
# SCENARIO 12: Pending Reboot -- simulated CBS marker
# Action: create the registry key that indicates a pending reboot
# ===================================================================
if (-not $SkipRebootMarker) {
    Write-Step "RebootAdvisory" "Creating simulated pending reboot registry marker"

    $cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    if (-not (Test-Path "$cbsPath\RebootPending")) {
        New-Item -Path "$cbsPath\RebootPending" -Force | Out-Null
        Write-Done "Created CBS RebootPending key -- chocoDeploy should log advisory warning"
        # Tag it so teardown knows we created it
        New-ItemProperty -Path "$cbsPath\RebootPending" -Name '_ChocoDeployTestMarker' `
            -Value 1 -PropertyType DWord -Force | Out-Null
    } else {
        Write-Done "CBS RebootPending key already exists -- genuine or previous test run"
    }
} else {
    Write-Step "RebootAdvisory" "Skipped (use without -SkipRebootMarker to enable)"
}


# ===================================================================
# Summary
# ===================================================================
Write-Host "`n========================================" -ForegroundColor White
Write-Host " Setup Complete -- Final Chocolatey State" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
$postInventory = choco list --local-only --limit-output 2>$null
$postInventory | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Write-Host "`n  Total: $($postInventory.Count) packages" -ForegroundColor Gray

Write-Host "`n========================================" -ForegroundColor White
Write-Host " Test Scenarios Ready" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White

$rebootStatus = if (-not $SkipRebootMarker) { 'CBS RebootPending marker set' } else { 'SKIPPED' }
$summaryLines = @(
    ""
    "  NoChange (keep):      git, docker-desktop, 7zip.install"
    "  Upgrade (choco):      greenshot (old), vscode.install (below min)"
    "  Convert (vendor):     putty (vendor-only), vim (vendor-only)"
    "  Conflict (old pkg):   pycharm-community -> should become pycharm"
    "  Install (absent):     winscp (removed -- baseline only)"
    "  Remove (blacklist):   notepadplusplus (installed -- should be removed)"
    "  Runtime upgrade:      powershell-core 7.5.4 -> 7.5.6"
    "  Runtime convert:      python (vendor-only -- no choco tracking)"
    "  Runtime OK:           dotnet-10.0-aspnetruntime (aligned)"
    "  Reboot advisory:      $rebootStatus"
    ""
    "Recommended test runs (from Ansible control node):"
    ""
    "  # 1. Conversion mode"
    "  ansible-playbook playbooks/chocoDeploy.yml -i inventory/TEST/inv-TEST.yml -l test-host-01 ``"
    "    -e 'deployment=choco_conversion' ``"
    "    -e '{""targetRuntimes"":[""powershell_core"",""python"",""dotnet_runtime""]}' ``"
    "    -e '{""removeSoftware"":[""notepad++""]}' ``"
    "    --vault-password-file=vault/.vault_key.txt"
    ""
    "  # 2. Baseline mode"
    "  ansible-playbook playbooks/chocoDeploy.yml -i inventory/TEST/inv-TEST.yml -l test-host-01 ``"
    "    -e 'deployment=choco_baseline' ``"
    "    -e '{""targetRuntimes"":[""powershell_core"",""python"",""dotnet_runtime""]}' ``"
    "    -e '{""removeSoftware"":[""notepad++""]}' ``"
    "    --vault-password-file=vault/.vault_key.txt"
    ""
    "  # 3. Update mode (fast pass)"
    "  ansible-playbook playbooks/chocoDeploy.yml -i inventory/TEST/inv-TEST.yml -l test-host-01 ``"
    "    -e 'deployment=choco_update' ``"
    "    --vault-password-file=vault/.vault_key.txt"
    ""
    "  # 4. Targeted with version override"
    "  ansible-playbook playbooks/chocoDeploy.yml -i inventory/TEST/inv-TEST.yml -l test-host-01 ``"
    "    -e 'deployment=choco_conversion' ``"
    "    -e '{""targetSoftware"":[""git"",""7zip"",{""key"":""teams"",""min_version"":""1.0.2508703""}]}'"
    ""
)
$summaryLines | ForEach-Object { Write-Host $_ -ForegroundColor White }
