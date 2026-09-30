<#
.SYNOPSIS
Repack a directory tree into a .nupkg using forward-slash entry names.

.DESCRIPTION
NuGet/OPC requires forward-slash separators inside the archive. PowerShell
5.1's Compress-Archive emits backslashes on Windows and produces a zip
that NuGet rejects with "is not a valid nupkg" / "End of Central
Directory record could not be found". This helper builds the archive
entry-by-entry via System.IO.Compression.ZipArchive with explicit
backslash-to-forward-slash conversion in entry names.

Pattern lifted from Repack-Nupkg in internalize-package.ps1; kept as a
standalone script so the iterate workflow can repack without needing
the whole internalizer.

.PARAMETER SourceDir
Directory tree to pack. The directory's contents (not the directory
itself) become the archive root - typical chocolatey package layout is
<SourceDir>/<id>.nuspec + <SourceDir>/tools/...

.PARAMETER DestNupkg
Absolute path to the .nupkg to produce. Overwritten if present.

.NOTES
Stages output to "<DestNupkg>.staging.zip" first so the destination
file is never half-written - rename at the end is atomic on NTFS.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SourceDir,
  [Parameter(Mandatory)][string]$DestNupkg
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $SourceDir)) {
  throw "SourceDir not found: $SourceDir"
}

$destDir = Split-Path -Parent $DestNupkg
if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
  New-Item -ItemType Directory -Force -Path $destDir | Out-Null
}

if (Test-Path -LiteralPath $DestNupkg) { Remove-Item -LiteralPath $DestNupkg -Force }
$stagedZip = "$DestNupkg.staging.zip"
if (Test-Path -LiteralPath $stagedZip) { Remove-Item -LiteralPath $stagedZip -Force }

$sourceRoot = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\','/')
$stream     = [System.IO.File]::Create($stagedZip)
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
        $src = [System.IO.File]::OpenRead($f.FullName)
        try { $src.CopyTo($entryStream) } finally { $src.Dispose() }
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

Move-Item -LiteralPath $stagedZip -Destination $DestNupkg -Force

[pscustomobject]@{
  Source      = $sourceRoot
  Dest        = $DestNupkg
  SizeBytes   = (Get-Item -LiteralPath $DestNupkg).Length
  EntryCount  = $files.Count
  Status      = 'Packed'
} | ConvertTo-Json -Compress
