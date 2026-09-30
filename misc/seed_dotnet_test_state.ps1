#requires -Version 5.1
<#
.SYNOPSIS
    Seed a Windows test host with EOL .NET runtime tracks for chocoDeploy testing.

.DESCRIPTION
    Installs choco-managed .NET 6 LTS (EOL Nov 2024) and .NET 7 (EOL May 2024)
    runtime tracks across all three families (aspnetcore, runtime, windowsdesktop).
    The chocoDeploy role's dotnetSweep should then remove these on the next
    conversion or baseline run because they are below min_supported_track (8.0).

    Idempotent: skips installs already at the requested version.
    Reversible: every install can be undone with `choco uninstall <pkg>`.

.PARAMETER WhatIf
    Standard PowerShell switch. When set, prints what would be installed
    without actually installing.

.EXAMPLE
    # On the target host as an Administrator:
    .\seed_dotnet_test_state.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'

# Packages to seed. These are all officially-supported choco packages even
# though the underlying runtimes are EOL. The sweep test relies on them
# being recognized as below-floor (8.0).
$packages = @(
    @{ Name = 'dotnet-6.0-aspnetruntime';        Version = '6.0.36' }
    @{ Name = 'dotnet-7.0-aspnetruntime';        Version = '7.0.20' }
    @{ Name = 'dotnet-7.0-runtime';              Version = '7.0.20' }
    @{ Name = 'dotnet-7.0-windowsdesktop-runtime'; Version = '7.0.20' }
)

# Sanity check: choco must be available.
$choco = Get-Command choco.exe -ErrorAction SilentlyContinue
if (-not $choco) {
    throw 'Chocolatey is not on PATH. Run chocoDeploy initChoco first or install choco manually.'
}

foreach ($p in $packages) {
    $name = $p.Name
    $version = $p.Version
    $existing = & choco list --local-only --exact --limit-output $name 2>$null |
        Where-Object { $_ -match "^$name\|" } |
        Select-Object -First 1

    if ($existing) {
        Write-Host "[skip] $name already installed: $existing"
        continue
    }

    if ($PSCmdlet.ShouldProcess($name, "choco install --version=$version")) {
        Write-Host "[install] $name $version"
        & choco install $name --version=$version --yes --no-progress --no-color --execution-timeout=600
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "choco install $name failed with exit code $LASTEXITCODE"
        }
    }
}

Write-Host ''
Write-Host '=== Resulting choco-managed .NET packages ==='
& choco list --local-only --limit-output |
    Where-Object { $_ -match '^dotnet-[0-9]+\.[0-9]+-' }

Write-Host ''
Write-Host '=== Vendor .NET runtimes per dotnet --list-runtimes ==='
$dotnetExe = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
if (Test-Path $dotnetExe) {
    & $dotnetExe --list-runtimes
}
