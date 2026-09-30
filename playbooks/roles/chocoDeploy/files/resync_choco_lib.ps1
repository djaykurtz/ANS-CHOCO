<#
.SYNOPSIS
Re-stamp Chocolatey's local lib metadata for a package to match the actual
installed version reported by the Windows registry, WITHOUT reinstalling
the binary.

.DESCRIPTION
Self-updating apps (Docker Desktop, Chrome, Greenshot, VS Code, etc.)
silently upgrade past whatever version Chocolatey originally installed.
The registry's DisplayVersion reflects reality; Chocolatey's lib metadata
stays stuck at the version it last installed. Without a Chocolatey for
Business `choco sync` license, there's no first-party way to update
the lib record without re-running the installer.

This script does the "no-premium" re-stamp by directly editing the three
filesystem records Chocolatey uses for `choco list`:

  C:\ProgramData\chocolatey\lib\<id>\<id>.nupkg
    THE AUTHORITATIVE SOURCE for `choco list` version readout in choco
    2.x. choco resolves the lib folder as a NuGet folder feed using
    NuGet's PackageSearchResource, which reads the EMBEDDED nuspec
    inside each .nupkg. Editing the loose .nuspec on disk has no
    effect on `choco list` output. Confirmed June 10 2026 against
    Chocolatey 2.6.0.

  C:\ProgramData\chocolatey\lib\<id>\<id>.nuspec
    Loose copy that choco writes alongside the nupkg. Kept in sync
    with the embedded one as a courtesy; doesn't affect `choco list`
    but other tooling may read it.

  C:\ProgramData\chocolatey\.chocolatey\<id>.<OLD_VER>\
    Per-version install record (named with the version). Renamed to
    `<id>.<NEW_VER>\` so future uninstall/upgrade paths see the
    correct version dir.

It does NOT touch the binary on disk, does NOT run the installer, does
NOT modify the registry, and does NOT pull anything from any feed. It
just makes choco's bookkeeping match what the registry already says.

Mandatory inputs:
  -PackageId  Chocolatey package id (e.g. 'docker-desktop')
  -NewVersion The version to stamp (typically the registry's DisplayVersion)

Behaviour:
  - If choco lib doesn't have this package: refuse, NoOp.
  - If lib version already equals NewVersion: NoOp.
  - Otherwise: backup the lib dir + .chocolatey per-version dir to
    `.bak.<timestamp>`, then edit + rename. Verify `choco list` reports
    the new version. On failure restore from backup.

Emits a single JSON line for the calling playbook.

.NOTES
Hacky on purpose. Choco's lib format isn't a documented API. Validated
against Chocolatey 1.x and 2.x on Server 2022 in June 2026. Re-validate
after any major choco version bump.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$PackageId,
  [Parameter(Mandatory=$true)] [string]$NewVersion,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Emit-Result {
  param([hashtable]$Data)
  ($Data | ConvertTo-Json -Compress -Depth 4) | Write-Output
}

function Get-ChocoLibVersion {
  param([string]$Id)
  $line = (& choco list --local-only --limit-output $Id 2>$null) | Select-Object -First 1
  if ($line) { return ($line -split '\|')[1] }
  return $null
}

try {
  $libRoot       = 'C:\ProgramData\chocolatey\lib'
  $chocRoot      = 'C:\ProgramData\chocolatey\.chocolatey'
  $libDir        = Join-Path $libRoot $PackageId
  $nuspecPath    = Join-Path $libDir "$PackageId.nuspec"
  $nupkgPath     = Join-Path $libDir "$PackageId.nupkg"
  $stamp         = Get-Date -Format 'yyyyMMddHHmmss'

  # ---- Preconditions -------------------------------------------------
  if (-not (Test-Path $libDir)) {
    Emit-Result @{
      Status = 'NoOp'; Reason = 'NoLibDir'; PackageId = $PackageId
      Message = "choco lib has no entry for $PackageId; nothing to re-stamp"
    }
    return
  }
  if (-not (Test-Path $nupkgPath)) {
    Emit-Result @{
      Status = 'NoOp'; Reason = 'NoNupkg'; PackageId = $PackageId
      Message = "lib dir exists but no .nupkg at $nupkgPath (choco list reads from this file)"
    }
    return
  }

  $currentLibVersion = Get-ChocoLibVersion -Id $PackageId
  if (-not $currentLibVersion) {
    Emit-Result @{
      Status = 'NoOp'; Reason = 'ChocoListEmpty'; PackageId = $PackageId
      Message = "choco list reports no $PackageId entry despite lib dir present"
    }
    return
  }

  if ($currentLibVersion -eq $NewVersion) {
    Emit-Result @{
      Status = 'AlreadyAligned'; PackageId = $PackageId
      LibVersion = $currentLibVersion; NewVersion = $NewVersion
      Message = 'choco lib already reports the target version; no change needed'
    }
    return
  }

  $oldChocDir = Join-Path $chocRoot "$PackageId.$currentLibVersion"
  $newChocDir = Join-Path $chocRoot "$PackageId.$NewVersion"

  if ($DryRun) {
    Emit-Result @{
      Status = 'DryRun'; PackageId = $PackageId
      CurrentLibVersion = $currentLibVersion; NewVersion = $NewVersion
      WillEditNupkgEmbeddedNuspec = $nupkgPath
      WillEditLooseNuspec = $nuspecPath
      WillRenameChocDir = if (Test-Path $oldChocDir) { "$oldChocDir -> $newChocDir" } else { "<no per-version dir found>" }
      Message = 'Dry run only -- no changes made'
    }
    return
  }

  # ---- Real run: backup, edit, rename, verify -----------------------
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem

  $libBak  = "$libDir.bak.$stamp"
  $chocBakSrc = if (Test-Path $oldChocDir) { $oldChocDir } else { $null }
  $chocBak = if ($chocBakSrc) { "$oldChocDir.bak.$stamp" } else { $null }

  # Backup lib dir by copying (preserve the live one we're about to edit)
  Copy-Item -LiteralPath $libDir -Destination $libBak -Recurse -Force

  # Backup the per-version .chocolatey dir by RENAMING -- we want it
  # out of the way so we can recreate at the new version name. We will
  # restore on failure.
  if ($chocBakSrc) {
    Move-Item -LiteralPath $chocBakSrc -Destination $chocBak -Force
  }

  $rollback = {
    if (Test-Path $libDir) { Remove-Item -LiteralPath $libDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $libBak) { Move-Item -LiteralPath $libBak -Destination $libDir -Force }
    if ($chocBak -and (Test-Path $chocBak)) {
      if (Test-Path $newChocDir) { Remove-Item -LiteralPath $newChocDir -Recurse -Force -ErrorAction SilentlyContinue }
      Move-Item -LiteralPath $chocBak -Destination $oldChocDir -Force
    }
  }

  try {
    # ---- 1. Rewrite embedded nuspec inside the .nupkg ---------------
    # Extract -> edit -> repack with forward-slash entry names (NuGet
    # rejects backslash entries; chocoBuild documents this same gotcha).
    $extractDir = Join-Path $env:TEMP "choco-resync-$PackageId-$stamp"
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkgPath, $extractDir)

    $embeddedNuspec = Get-ChildItem -Path $extractDir -Filter '*.nuspec' -File -Recurse | Select-Object -First 1
    if (-not $embeddedNuspec) {
      throw "No .nuspec found inside extracted $nupkgPath"
    }
    $embeddedContent = Get-Content -Raw -LiteralPath $embeddedNuspec.FullName
    $pattern = "<version>$([regex]::Escape($currentLibVersion))</version>"
    $replace = "<version>$NewVersion</version>"
    if ($embeddedContent -match $pattern) {
      $embeddedContent = $embeddedContent -replace $pattern, $replace
      $versionEditMode = 'exact'
    } else {
      $embeddedContent = [regex]::Replace($embeddedContent, '(?is)<version>\s*[^<]*\s*</version>', $replace, 1)
      $versionEditMode = 'fallback-regex'
    }
    Set-Content -LiteralPath $embeddedNuspec.FullName -Value $embeddedContent -Encoding UTF8 -NoNewline

    # Repack with forward-slash entry names. Mirrors chocoBuild's
    # repack_nupkg.ps1 / build_wrapper_nupkg.ps1 technique.
    $newNupkg = "$nupkgPath.new.zip"
    if (Test-Path $newNupkg) { Remove-Item -LiteralPath $newNupkg -Force }
    $sourceRoot = (Resolve-Path $extractDir).Path.TrimEnd('\','/')
    $stream = [System.IO.File]::Create($newNupkg)
    try {
      $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
      try {
        Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | ForEach-Object {
          $rel = $_.FullName.Substring($sourceRoot.Length).TrimStart('\','/')
          $entryName = $rel -replace '\\','/'
          $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
          $entryStream = $entry.Open()
          try {
            $src = [System.IO.File]::OpenRead($_.FullName)
            try { $src.CopyTo($entryStream) } finally { $src.Dispose() }
          } finally { $entryStream.Dispose() }
        }
      } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
    Move-Item -LiteralPath $newNupkg -Destination $nupkgPath -Force
    Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue

    # ---- 2. Edit the loose on-disk nuspec (cosmetic but kept in sync)
    if (Test-Path $nuspecPath) {
      $looseContent = Get-Content -Raw -LiteralPath $nuspecPath
      if ($looseContent -match $pattern) {
        $looseContent = $looseContent -replace $pattern, $replace
      } else {
        $looseContent = [regex]::Replace($looseContent, '(?is)<version>\s*[^<]*\s*</version>', $replace, 1)
      }
      Set-Content -LiteralPath $nuspecPath -Value $looseContent -Encoding UTF8 -NoNewline
    }

    # ---- 3. Recreate the per-version .chocolatey dir at the new version
    if ($chocBak) {
      Copy-Item -LiteralPath $chocBak -Destination $newChocDir -Recurse -Force
    } else {
      New-Item -ItemType Directory -Force -Path $newChocDir | Out-Null
    }

    # ---- 4. Verify choco list now reports the new version
    Start-Sleep -Milliseconds 200
    $verifyVersion = Get-ChocoLibVersion -Id $PackageId
    if ($verifyVersion -ne $NewVersion) {
      throw "Post-edit verification failed: choco list reports '$verifyVersion', expected '$NewVersion'"
    }

    # ---- 5. Success -- clean up backups
    if (Test-Path $libBak) { Remove-Item -LiteralPath $libBak -Recurse -Force -ErrorAction SilentlyContinue }
    if ($chocBak -and (Test-Path $chocBak)) { Remove-Item -LiteralPath $chocBak -Recurse -Force -ErrorAction SilentlyContinue }

    Emit-Result @{
      Status            = 'Resynced'
      PackageId         = $PackageId
      PreviousLibVersion= $currentLibVersion
      NewVersion        = $NewVersion
      VerifiedVersion   = $verifyVersion
      VersionEditMode   = $versionEditMode
      ChocoMetaRenamed  = [bool]$chocBak
      Message           = "Re-stamped lib from $currentLibVersion to $NewVersion (binary untouched)"
    }
  } catch {
    & $rollback
    Emit-Result @{
      Status    = 'Failed'
      PackageId = $PackageId
      PreviousLibVersion = $currentLibVersion
      AttemptedNewVersion= $NewVersion
      Error     = $_.Exception.Message
      Message   = 'Re-stamp failed; rolled back from backup'
    }
    exit 1
  }
} catch {
  Emit-Result @{
    Status    = 'Failed'
    PackageId = $PackageId
    Error     = $_.Exception.Message
    Message   = 'Preflight failed before any changes were made'
  }
  exit 1
}
