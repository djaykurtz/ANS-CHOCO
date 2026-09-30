<#
.SYNOPSIS
Build a Chocolatey wrapper .nupkg by cloning an already-internalized
BASE version of a package and swapping in a NEW vendor installer
binary, verified against an official SHA256 hash.

.DESCRIPTION
Generic, package-agnostic helper for chocoBuild's wrapper synthesis
pipeline. Driven by a spec file (wrapper-spec.yml) on the orchestrator
side; this script gets one entry's worth of parameters at a time.

Pipeline:
  1. Extract <RepoRoot>\<PackageId>\<PackageId>.<BaseVersion>.nupkg
     into a staging dir.
  2. Locate the bundled installer in the extracted tree using
     -InstallerGlob (PowerShell wildcard form).
  3. Verify the new installer's SHA256 using ONE of:
       a) -ChecksumsUrl + -ChecksumsMatch (fetch the vendor's
          checksums file, find the line containing -ChecksumsMatch,
          take the first whitespace-separated token as the SHA256)
       b) -ExpectedSha256 (a pinned hash provided directly)
  4. Download -InstallerUrl over the bundled installer path so the
     existing chocolateyInstall.ps1's hardcoded path still works.
  5. Bump <version> in the .nuspec from BaseVersion -> NewVersion.
  6. Drop .signature.p7s if present (we mutated content; signature
     would no longer validate).
  7. Repack with System.IO.Compression.ZipArchive using forward-slash
     entry names. (Compress-Archive emits backslashes which NuGet's
     OPC reader rejects; same gotcha documented in internalize-package.ps1.)
  8. Write sentinel <RepoRoot>\<PackageId>\.internalized\<NewVersion>.done.

Emits a single JSON line to stdout for the playbook to consume.

.PARAMETER RepoRoot
Mirror root, e.g. C:\tools\chocoRepo. The per-package directory is
joined as $RepoRoot\$PackageId.

.PARAMETER PackageId
Chocolatey package id (e.g. 'docker-desktop'). Used to locate the
base .nupkg under $RepoRoot\$PackageId\$PackageId.$BaseVersion.nupkg.

.PARAMETER BaseVersion
Version of the existing internalized .nupkg to clone.

.PARAMETER NewVersion
Version label to stamp on the new wrapper.

.PARAMETER InstallerUrl
Direct vendor URL for the new installer binary.

.PARAMETER InstallerGlob
PowerShell -Filter pattern that matches the bundled installer to swap.
Searched recursively under the extracted tools/ directory. Example:
'*Docker*Desktop*Installer*.exe'.

.PARAMETER ChecksumsUrl
URL of a text file where each line begins "<sha256>  <filename>" or
similar. The script downloads it and finds the line containing
$ChecksumsMatch.

.PARAMETER ChecksumsMatch
Substring to locate the right line inside the file at $ChecksumsUrl.
Typically the installer filename as the vendor publishes it.

.PARAMETER ExpectedSha256
Pinned SHA256 hex (64 chars). Use this when the vendor does not
publish a checksums file. At least one of -ChecksumsUrl or
-ExpectedSha256 is required.

.PARAMETER BaseNupkgSha256
Optional pinned SHA256 of the BASE .nupkg itself. When supplied, the
base package is hashed before extraction and the build aborts on
mismatch. This protects against tampering of the cached base on the
mirror (e.g. supply-chain compromise that swapped the cached
community package). Strongly recommended once a base has been
manually reviewed and accepted.

.PARAMETER Force
Rebuild even if the sentinel exists.

.NOTES
First wrapper consumer: docker-desktop 4.76 (cloned from internalized
4.75.0). See wrapper-spec.yml for the catalog of all wrappers and
playbooks/roles/chocoBuild/README.md for the role's broader scope.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]  [string]$RepoRoot,
  [Parameter(Mandatory=$true)]  [string]$PackageId,
  [Parameter(Mandatory=$true)]  [string]$BaseVersion,
  [Parameter(Mandatory=$true)]  [string]$NewVersion,
  [Parameter(Mandatory=$true)]  [string]$InstallerUrl,
  [Parameter(Mandatory=$true)]  [string]$InstallerGlob,
  [Parameter(Mandatory=$false)] [string]$ChecksumsUrl,
  [Parameter(Mandatory=$false)] [string]$ChecksumsMatch,
  [Parameter(Mandatory=$false)] [string]$ExpectedSha256,
  [Parameter(Mandatory=$false)] [string]$BaseNupkgSha256,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Emit-Result {
  param([hashtable]$Data)
  ($Data | ConvertTo-Json -Compress -Depth 4) | Write-Output
}

try {
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem

  $repoDir     = Join-Path $RepoRoot $PackageId
  $baseNupkg   = Join-Path $repoDir "$PackageId.$BaseVersion.nupkg"
  $newNupkg    = Join-Path $repoDir "$PackageId.$NewVersion.nupkg"
  $sentinelDir = Join-Path $repoDir '.internalized'
  $sentinel    = Join-Path $sentinelDir "$NewVersion.done"

  if (-not (Test-Path $repoDir)) {
    throw "Per-package mirror dir not found: $repoDir"
  }

  if ((Test-Path $sentinel) -and (Test-Path $newNupkg) -and -not $Force) {
    Emit-Result @{
      Status      = 'AlreadyBuilt'
      PackageId   = $PackageId
      BaseVersion = $BaseVersion
      NewVersion  = $NewVersion
      Path        = $newNupkg
      Sentinel    = $sentinel
    }
    return
  }

  if (-not (Test-Path $baseNupkg)) {
    throw "Base internalized nupkg not found: $baseNupkg (run chocoBuild.yml --tags community to bundle $PackageId $BaseVersion first)"
  }

  # ---- Supply-chain guard on base .nupkg (optional but recommended) ----
  $baseNupkgActualSha = (Get-FileHash -Path $baseNupkg -Algorithm SHA256).Hash.ToLower()
  if ($BaseNupkgSha256) {
    $expectedBase = $BaseNupkgSha256.Trim().ToLower()
    if ($expectedBase.Length -ne 64) {
      throw "BaseNupkgSha256 has unexpected format: '$expectedBase' (length $($expectedBase.Length))"
    }
    if ($baseNupkgActualSha -ne $expectedBase) {
      throw "Base nupkg SHA256 MISMATCH for $PackageId $BaseVersion. Expected $expectedBase, got $baseNupkgActualSha. Refusing to clone an unverified base (supply-chain guard)."
    }
    $baseTrust = 'pinned-sha256-verified'
  } else {
    $baseTrust = 'unpinned-warning'
  }

  # ---- Resolve expected SHA256 -----------------------------------------
  $expectedSha = $null
  $verifySource = $null
  if ($ExpectedSha256) {
    $expectedSha  = $ExpectedSha256.Trim().ToLower()
    $verifySource = 'pinned-sha256'
  } elseif ($ChecksumsUrl -and $ChecksumsMatch) {
    $checksumsRaw = (Invoke-WebRequest -Uri $ChecksumsUrl -UseBasicParsing -TimeoutSec 120).Content
    $line = $checksumsRaw -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($ChecksumsMatch) } | Select-Object -First 1
    if (-not $line) {
      throw "Could not find '$ChecksumsMatch' line in checksums file at $ChecksumsUrl"
    }
    $expectedSha  = (($line -split '\s+', 2)[0]).Trim().ToLower()
    $verifySource = "checksums-url ($ChecksumsMatch)"
  } else {
    throw "Must supply EITHER -ExpectedSha256 OR (-ChecksumsUrl + -ChecksumsMatch)."
  }
  if ($expectedSha.Length -ne 64) {
    throw "Resolved SHA256 has unexpected format: '$expectedSha' (length $($expectedSha.Length))"
  }

  # ---- Extract base .nupkg ---------------------------------------------
  $stamp   = Get-Date -Format 'yyyyMMddHHmmss'
  $staging = Join-Path $env:TEMP "chocoBuild-wrap-$PackageId-$NewVersion-$stamp"
  if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  [System.IO.Compression.ZipFile]::ExtractToDirectory($baseNupkg, $staging)

  # ---- Locate bundled installer ----------------------------------------
  $candidates = Get-ChildItem -Path $staging -Recurse -File -Filter $InstallerGlob -ErrorAction SilentlyContinue
  if (-not $candidates -or $candidates.Count -eq 0) {
    throw "InstallerGlob '$InstallerGlob' matched no files inside extracted $BaseVersion package. Has the base internalize step actually run?"
  }
  if ($candidates.Count -gt 1) {
    # Multiple matches -- pick the largest as a heuristic (installers are
    # almost always the largest .exe in the package).
    $candidates = $candidates | Sort-Object -Property Length -Descending
  }
  $installerPath = $candidates[0].FullName

  # ---- Download new installer + verify ---------------------------------
  Remove-Item -Path $installerPath -Force
  Invoke-WebRequest -Uri $InstallerUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 1800

  $actualSha = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash.ToLower()
  if ($actualSha -ne $expectedSha) {
    throw "SHA256 mismatch on downloaded installer for $PackageId $NewVersion. Expected $expectedSha, got $actualSha (source: $verifySource)"
  }

  # ---- Bump <version> in nuspec ----------------------------------------
  $nuspec = Get-ChildItem -Path $staging -Filter '*.nuspec' -File | Select-Object -First 1
  if (-not $nuspec) {
    throw "No .nuspec found in extracted package"
  }
  $nuspecContent = Get-Content -Raw -Path $nuspec.FullName
  $patternExact  = [regex]::Escape("<version>$BaseVersion</version>")
  if ($nuspecContent -match $patternExact) {
    $nuspecContent  = $nuspecContent -replace $patternExact, "<version>$NewVersion</version>"
    $versionEditMode = 'exact'
  } else {
    $nuspecContent  = [regex]::Replace($nuspecContent, '(?is)<version>\s*[^<]*\s*</version>', "<version>$NewVersion</version>")
    $versionEditMode = 'fallback-regex'
  }
  Set-Content -Path $nuspec.FullName -Value $nuspecContent -Encoding UTF8 -NoNewline

  # ---- Drop signature (mutated content invalidates it) -----------------
  $sigPath    = Join-Path $staging '.signature.p7s'
  $sigRemoved = $false
  if (Test-Path $sigPath) {
    Remove-Item -Path $sigPath -Force
    $sigRemoved = $true
  }

  # ---- Repack (forward-slash entry names) ------------------------------
  if (Test-Path $newNupkg) { Remove-Item -Path $newNupkg -Force }
  $stagingZip = "$newNupkg.staging.zip"
  if (Test-Path $stagingZip) { Remove-Item -Path $stagingZip -Force }

  $sourceRoot = (Resolve-Path $staging).Path.TrimEnd('\','/')
  $stream     = [System.IO.File]::Create($stagingZip)
  try {
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      $files = Get-ChildItem -LiteralPath $sourceRoot -Recurse -File
      foreach ($f in $files) {
        $rel       = $f.FullName.Substring($sourceRoot.Length).TrimStart('\','/')
        $entryName = $rel -replace '\\','/'
        $entry     = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        try {
          $srcStream = [System.IO.File]::OpenRead($f.FullName)
          try { $srcStream.CopyTo($entryStream) } finally { $srcStream.Dispose() }
        } finally {
          $entryStream.Dispose()
        }
      }
    } finally {
      $zip.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
  Move-Item -Path $stagingZip -Destination $newNupkg -Force

  # ---- Sentinel + cleanup ----------------------------------------------
  New-Item -ItemType Directory -Force -Path $sentinelDir | Out-Null
  Set-Content -Path $sentinel -Value (Get-Date -Format o) -Force
  Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue

  Emit-Result @{
    Status              = 'Built'
    PackageId           = $PackageId
    BaseVersion         = $BaseVersion
    NewVersion          = $NewVersion
    BaseNupkg           = $baseNupkg
    BaseNupkgSha256     = $baseNupkgActualSha
    BaseTrust           = $baseTrust
    NewNupkg            = $newNupkg
    InstallerSha256     = $actualSha
    VerifySource        = $verifySource
    NewNupkgSizeBytes   = (Get-Item -Path $newNupkg).Length
    VersionEditMode     = $versionEditMode
    SignatureRemoved    = $sigRemoved
    Sentinel            = $sentinel
  }
} catch {
  Emit-Result @{
    Status    = 'Failed'
    PackageId = $PackageId
    NewVersion= $NewVersion
    Error     = $_.Exception.Message
  }
  exit 1
}
