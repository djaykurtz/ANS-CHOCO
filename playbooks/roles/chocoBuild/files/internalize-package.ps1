<#
.SYNOPSIS
Internalize a Chocolatey .nupkg: download embedded URLs as local files and
rewrite install scripts to use them.

.DESCRIPTION
Extracts a .nupkg, scans tools\chocolateyInstall.ps1 and tools\data.ps1 for
HTTP(S) URLs to installer payloads (exe/msi/zip/7z/msix/etc.), downloads each
to tools\files\, and rewrites the scripts to reference the local files via
Install-ChocolateyPackage / Install-ChocolateyInstallPackage's -File / -File64
parameters (which bypass the URL downloader).

Supported install-script patterns:
  - Install-ChocolateyPackage with inline url / url64 / url64bit
  - Install-ChocolateyPackage with URLs coming from a sibling data.ps1
  - Get-ChocolateyWebFile then direct execution (replaced with Copy-Item)
  - Install-DotNetFramework (rewritten to Install-ChocolateyInstallPackage)
  - Meta packages with no install script (no-op, package left as a manifest)

After rewriting, repacks the directory as a new .nupkg next to the original
(or to -OutputDir if specified). The original .nupkg is not modified.

.PARAMETER NupkgPath
Absolute path to the input .nupkg file.

.PARAMETER OutputDir
Directory to write the internalized .nupkg into. Defaults to the same
directory as the input, with -internalized appended before the version.

.PARAMETER WorkDir
Working directory for extraction and repacking. Defaults to $env:TEMP\chocoInt.

.PARAMETER Force
Re-download URLs and overwrite output even if the internalized .nupkg already
exists.

.NOTES
URL detection is regex-based and limited to common installer file extensions.
URLs constructed at runtime from variables / expressions are not detected.
Such packages need package-specific handling.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$NupkgPath,
  [string]$OutputDir,
  [string]$WorkDir = "$env:TEMP\chocoInt",
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---- helpers -------------------------------------------------------------

function Write-Log {
  param([string]$Level, [string]$Msg)
  # Emit via Verbose stream so the calling orchestrator's stdout (used to
  # transport a JSON report) stays clean. Caller can pass -Verbose to see.
  Write-Verbose ("[{0}] {1}" -f $Level, $Msg)
}

function Get-FileNameFromUrl {
  param([string]$Url)
  $uri = [System.Uri]$Url
  # IMPORTANT: AbsolutePath returns URL-encoded form (spaces -> %20). We need
  # the DECODED filename on disk because the install script will pass the
  # local path verbatim to Get-ChocolateyWebFile / Install-ChocolateyPackage,
  # which interpret %-encoded local paths as broken URLs. Use
  # UnescapeDataString on the basename so 'Docker%20Desktop%20Installer.exe'
  # becomes 'Docker Desktop Installer.exe' on disk. Caught when patched
  # docker-desktop 4.75 install failed with "Cannot find path '...%20...'"
  # even though the encoded-name file was present (June 9 2026).
  $rawName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
  $name = [System.Uri]::UnescapeDataString($rawName)
  $hasExt = $name -match '\.(exe|msi|zip|7z|cab|msix|appx|msu)$'
  if ([string]::IsNullOrWhiteSpace($name) -or -not $hasExt) {
    # Build a synthetic filename from the URL path. Used when the URL ends in
    # a routing token (e.g. vscode's .../win32-x64/stable). Default to .exe
    # since the vast majority of these are EXE installers.
    $slug = ([System.Uri]::UnescapeDataString($uri.AbsolutePath).Trim('/') -replace '/', '_' -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = $uri.Host -replace '[^A-Za-z0-9._-]', '_' }
    if ($slug -notmatch '\.(exe|msi|zip|7z|cab|msix|appx|msu)$') { $slug += '.exe' }
    $name = $slug
  }
  return $name
}

function Find-Urls {
  param([string]$Text)
  $found = [System.Collections.Generic.HashSet[string]]::new()
  # Primary pattern: URLs ending in a recognised installer extension.
  $extPattern = 'https?://[^\s''"<>)]+\.(?:exe|msi|zip|7z|cab|appx|msix|msu|tar\.gz)\b'
  foreach ($m in [regex]::Matches($Text, $extPattern, 'IgnoreCase')) {
    [void]$found.Add($m.Value)
  }
  # Secondary pattern: URLs found inside `url(64)?(bit)? = '...'` lines in
  # hashtable entries, even when the URL has no recognisable extension
  # (e.g. https://update.code.visualstudio.com/1.114.0/win32-x64/stable).
  # We trust the surrounding `url = ` context to mean it's an installer.
  $hashPattern = '(?im)\burl(?:64(?:bit)?)?\s*=\s*[''"](?<u>https?://[^\s''"<>)]+)[''"]'
  foreach ($m in [regex]::Matches($Text, $hashPattern)) {
    [void]$found.Add($m.Groups['u'].Value)
  }
  return $found
}

function Download-File {
  param([string]$Url, [string]$Dest)
  if ((Test-Path $Dest) -and (-not $Force)) {
    return [pscustomobject]@{ Url=$Url; Path=$Dest; Status='Cached'; Bytes=(Get-Item $Dest).Length }
  }
  try {
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 600
    return [pscustomobject]@{ Url=$Url; Path=$Dest; Status='Downloaded'; Bytes=(Get-Item $Dest).Length }
  } catch {
    return [pscustomobject]@{ Url=$Url; Path=$Dest; Status='Failed'; Bytes=0; Error=$_.Exception.Message }
  }
}

# Rewrite "url = '<URL>'" / "url64 = '<URL>'" / "url64bit = '<URL>'" / "Url = '<URL>'"
# inside a hashtable into the corresponding file = / file64 = local-path entry.
# Also comments out adjacent checksum lines for that URL.
# When -AddOnly is set, the original url=/Url= lines are PRESERVED and a new
# file=/File= line is inserted immediately after each. Required for data.ps1
# scripts that are dot-sourced and read under Set-StrictMode by an install.ps1
# expecting the Url/Checksum properties to exist - removing them under strict
# mode throws "property cannot be found". The runtime forwarding block we
# inject into the install script swaps url -> file in the args hashtable.
function Rewrite-HashtableUrls {
  param(
    [string]$Content,
    [hashtable]$UrlToLocalPath,
    [switch]$AddOnly
  )
  $modified = $Content
  foreach ($url in $UrlToLocalPath.Keys) {
    $localPath = $UrlToLocalPath[$url]
    $escUrl = [regex]::Escape($url)
    $rx = "(?im)^(\s*)(url(?:64(?:bit)?)?)(\s*=\s*)['""]" + $escUrl + "['""]"
    if ($AddOnly) {
      # Keep the original line, append a sibling file= / File= line.
      $modified = [regex]::Replace($modified, $rx, {
        param($m)
        $indent  = $m.Groups[1].Value
        $origKey = $m.Groups[2].Value
        $eq      = $m.Groups[3].Value
        $lower   = $origKey.ToLower()
        $fileKey = if ($lower -in @('url64','url64bit')) { 'File64' } elseif ($lower -eq 'url') { 'File' } else { 'File' }
        if ($origKey -cmatch '^[a-z]') {
          $fileKey = $fileKey.ToLower()
        }
        $orig = $m.Value
        "$orig`r`n$indent$fileKey$eq'$localPath'"
      })
    } else {
      $modified = [regex]::Replace($modified, $rx, {
        param($m)
        $indent = $m.Groups[1].Value
        $key    = $m.Groups[2].Value.ToLower()
        $eq     = $m.Groups[3].Value
        $origKey = $m.Groups[2].Value
        $fileKey = if ($key -in @('url64','url64bit')) { 'file64' } elseif ($key -eq 'url') { 'file' } else { 'file' }
        if ($origKey -cmatch '^[A-Z]') {
          $fileKey = if ($key -in @('url64','url64bit')) { 'File64' } else { 'File' }
        }
        "$indent$fileKey$eq'$localPath'"
      })
    }
  }
  if (-not $AddOnly) {
    # Comment out checksum/checksumType lines (case-insensitive, both lowercase
    # and capitalised variants used by community packages).
    $modified = $modified -replace '(?im)^(\s*)(checksum(?:64)?(?:Type(?:64)?)?\s*=)', '$1# $2'
    $modified = $modified -replace '(?im)^(\s*)(Checksum(?:64)?(?:Type(?:64)?)?\s*=)', '$1# $2'
  }
  return $modified
}

# Rewrite bare PowerShell variable assignments of the form
#   $url64 = 'https://.../installer.exe'
#   $checksum64 = 'abc...'
# which sit OUTSIDE any hashtable but are later referenced inside one as
#   url64bit = $url64
#   checksum64 = $checksum64
# This is the docker-desktop pattern. The original Rewrite-HashtableUrls only
# matches inline hashtable url keys, so it misses this case entirely.
#
# Strategy:
#   1. For each known URL, find the bare assignment, capture the var name,
#      and rewrite the RHS to the local file path (single-quoted, since the
#      $toolsDir token won't be available at script top - we use a marker
#      that is later expanded to "$toolsDir\files\<name>" double-quoted in
#      the second pass, same mechanism as Rewrite-HashtableUrls).
#   2. Find any hashtable line referencing that variable as a url/url64/url64bit
#      key and rewrite the KEY to the corresponding file/file64 form. The
#      variable reference itself is preserved - now holding a local path.
#   3. Comment out any bare $checksum / $checksum64 lines AND any hashtable
#      lines referencing those variables, so checksum verification is skipped.
function Rewrite-BareVariableUrls {
  param(
    [string]$Content,
    [hashtable]$UrlToLocalPath
  )
  $modified = $Content
  $varKeyMap = @{}   # var-name (lowercased) -> 'file' or 'file64'
  foreach ($url in $UrlToLocalPath.Keys) {
    $localPath = $UrlToLocalPath[$url]
    $escUrl = [regex]::Escape($url)
    # Match: ^<indent>$<varname><sp>=<sp>'<exact-url>'
    $rx = "(?im)^(\s*)\`$(\w+)(\s*=\s*)['""]" + $escUrl + "['""]"
    $modified = [regex]::Replace($modified, $rx, {
      param($m)
      $indent  = $m.Groups[1].Value
      $varName = $m.Groups[2].Value
      $eq      = $m.Groups[3].Value
      # Decide whether this is a 64-bit URL based on the variable name.
      $lower   = $varName.ToLower()
      $isX64   = ($lower -match '64' )
      $script:__last_var_isX64 = $isX64
      $varKeyMap[$lower] = if ($isX64) { 'file64' } else { 'file' }
      # Keep the original variable name to preserve any downstream references;
      # only swap the RHS to a single-quoted local path. Two-step expansion
      # to the $toolsDir token happens at the marker-substitution stage in
      # the caller, identical to Rewrite-HashtableUrls.
      "$indent`$$varName$eq'$localPath'"
    })
  }
  # Now rewrite hashtable lines that reference any of those variables as a
  # url/url64/url64bit key. Capture forms like:
  #     url64bit = $url64
  #     url      = $url
  # and rewrite the key to file/file64 (matching variable type).
  foreach ($lowerVar in $varKeyMap.Keys) {
    $fileKey = $varKeyMap[$lowerVar]
    $escVar  = [regex]::Escape($lowerVar)
    # Case-insensitive match on the var name in the value; preserve the var
    # name's original casing in the replacement by capturing it.
    $rx2 = "(?im)^(\s*)(url(?:64(?:bit)?)?)(\s*=\s*)\`$(" + $escVar + ")\b"
    $modified = [regex]::Replace($modified, $rx2, {
      param($m)
      $indent  = $m.Groups[1].Value
      $origKey = $m.Groups[2].Value
      $eq      = $m.Groups[3].Value
      $refVar  = $m.Groups[4].Value
      # Preserve case style of the original key (lowercase 'url' -> 'file',
      # 'Url' / 'Url64' -> 'File' / 'File64').
      $emit = $fileKey
      if ($origKey -cmatch '^[A-Z]') {
        $emit = $fileKey.Substring(0,1).ToUpper() + $fileKey.Substring(1)
      }
      "$indent$emit$eq`$$refVar"
    })
  }
  # Comment out bare $checksum / $checksum64 assignments (those that match
  # the known checksum convention; we do this even when the value is not
  # one of our known URLs, because they only matter alongside the urls we
  # internalized). Conservative: only comment out lines that look like a
  # hex literal assignment.
  $modified = [regex]::Replace($modified, '(?im)^(\s*)(\$checksum(?:64)?(?:Type(?:64)?)?\s*=\s*[''"][0-9a-fA-F]{8,}[''"])', '$1# $2')
  $modified = [regex]::Replace($modified, '(?im)^(\s*)(\$checksum(?:64)?(?:Type(?:64)?)?\s*=\s*[''"](?:sha\d+|md5)[''"])', '$1# $2')
  # Comment out hashtable references to those vars: e.g. `checksum64 = $checksum64`.
  $modified = [regex]::Replace($modified, '(?im)^(\s*)(checksum(?:64)?(?:Type(?:64)?)?\s*=\s*\$checksum(?:64)?(?:Type(?:64)?)?)', '$1# $2')
  $modified = [regex]::Replace($modified, '(?im)^(\s*)(Checksum(?:64)?(?:Type(?:64)?)?\s*=\s*\$[Cc]hecksum(?:64)?(?:Type(?:64)?)?)', '$1# $2')
  return $modified
}

function Repack-Nupkg {
  param([string]$Source, [string]$DestNupkg)
  # IMPORTANT: NuGet (.nupkg) and OPC require forward-slash separators inside
  # the archive. PowerShell 5.1's Compress-Archive emits backslashes on
  # Windows, producing a ZIP that NuGet rejects with
  # "is not a valid nupkg" / "End of Central Directory record could not be
  # found". Build the archive entry-by-entry using ZipArchive so we control
  # the entry names exactly.
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem

  if (Test-Path $DestNupkg) { Remove-Item $DestNupkg -Force }
  # Stage into a temp file first to keep the original safe during in-place
  # writes (Repack callers may pass a Dest that equals the source).
  $stagedZip = "$DestNupkg.staging.zip"
  if (Test-Path $stagedZip) { Remove-Item $stagedZip -Force }

  $sourceRoot = (Resolve-Path $Source).Path.TrimEnd('\','/')
  $stream = [System.IO.File]::Create($stagedZip)
  try {
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      $files = Get-ChildItem -LiteralPath $sourceRoot -Recurse -File
      foreach ($f in $files) {
        $rel = $f.FullName.Substring($sourceRoot.Length).TrimStart('\','/')
        $entryName = $rel -replace '\\','/'
        $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        try {
          $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
          $entryStream.Write($bytes, 0, $bytes.Length)
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

  Move-Item -Path $stagedZip -Destination $DestNupkg -Force
}

# ---- main ----------------------------------------------------------------

if (-not (Test-Path $NupkgPath)) {
  throw "Input .nupkg not found: $NupkgPath"
}

$pkgFile = Get-Item $NupkgPath
$pkgBase = $pkgFile.BaseName  # e.g. "greenshot.1.3.315"
if (-not $OutputDir) { $OutputDir = $pkgFile.DirectoryName }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$destNupkg = Join-Path $OutputDir "$pkgBase.nupkg"
$sameFile = ($destNupkg -eq $pkgFile.FullName)

# Work area
$pkgWork = Join-Path $WorkDir $pkgBase
if (Test-Path $pkgWork) { Remove-Item -Recurse -Force $pkgWork }
New-Item -ItemType Directory -Force -Path $pkgWork | Out-Null

# Extract
Write-Log INFO "Extracting $($pkgFile.Name)"
$tempCopy = Join-Path $WorkDir "$pkgBase.zip"
Copy-Item $pkgFile.FullName $tempCopy -Force
Expand-Archive -Path $tempCopy -DestinationPath $pkgWork -Force
Remove-Item $tempCopy -Force

$toolsDir = Join-Path $pkgWork 'tools'
if (-not (Test-Path $toolsDir)) {
  Write-Log WARN "No tools\ directory (meta package?), nothing to internalize"
  if (-not $sameFile) {
    Copy-Item $pkgFile.FullName $destNupkg -Force
    Write-Log INFO "Copied as-is to $destNupkg"
  }
  return [pscustomobject]@{ Package=$pkgBase; Status='Meta'; UrlCount=0; Output=$destNupkg }
}

# Find install + data scripts (case-insensitive lookup)
$installPs1 = Get-ChildItem $toolsDir -File -Filter '*.ps1' | Where-Object {
  $_.Name -ieq 'chocolateyInstall.ps1' -or $_.Name -ieq 'ChocolateyInstall.ps1'
} | Select-Object -First 1

$dataPs1 = Get-ChildItem $toolsDir -File -Filter 'data.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $installPs1) {
  Write-Log WARN "No chocolateyInstall.ps1 found, leaving package unchanged"
  if (-not $sameFile) {
    Copy-Item $pkgFile.FullName $destNupkg -Force
  }
  return [pscustomobject]@{ Package=$pkgBase; Status='NoInstallScript'; UrlCount=0; Output=$destNupkg }
}

# Scan for URLs across install + data scripts
$installText = Get-Content $installPs1.FullName -Raw
$dataText    = if ($dataPs1) { Get-Content $dataPs1.FullName -Raw } else { '' }

$urlsInInstall = Find-Urls -Text $installText
$urlsInData    = Find-Urls -Text $dataText
$allUrls = [System.Collections.Generic.HashSet[string]]::new()
foreach ($u in $urlsInInstall) { [void]$allUrls.Add($u) }
foreach ($u in $urlsInData)    { [void]$allUrls.Add($u) }

if ($allUrls.Count -eq 0) {
  Write-Log INFO "No download URLs found (already bundled?), copying as-is"
  if (-not $sameFile) {
    Copy-Item $pkgFile.FullName $destNupkg -Force
  }
  return [pscustomobject]@{ Package=$pkgBase; Status='AlreadyBundled'; UrlCount=0; Output=$destNupkg }
}

Write-Log INFO "Found $($allUrls.Count) URL(s) to internalize"

# Download into tools\files\
$filesDir = Join-Path $toolsDir 'files'
New-Item -ItemType Directory -Force -Path $filesDir | Out-Null

$urlToLocal = @{}        # url -> absolute local path
$urlToLocalToken = @{}   # url -> token to use in script (uses $toolsDir reference)
$downloads = @()
foreach ($url in $allUrls) {
  $name = Get-FileNameFromUrl -Url $url
  # Deduplicate filename clashes by appending an index
  $candidate = $name
  $i = 0
  while ($urlToLocal.Values -contains (Join-Path $filesDir $candidate)) {
    $i++
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $ext  = [System.IO.Path]::GetExtension($name)
    $candidate = "$stem-$i$ext"
  }
  $localPath = Join-Path $filesDir $candidate
  $res = Download-File -Url $url -Dest $localPath
  $downloads += $res
  if ($res.Status -eq 'Failed') {
    Write-Log ERROR "Download failed for $url : $($res.Error)"
    continue
  }
  $urlToLocal[$url] = $localPath
  # Token used inside scripts. We avoid hardcoding the full path; instead use
  # $toolsDir\files\<name> so the script remains valid wherever Chocolatey
  # extracts the package at install time.
  $urlToLocalToken[$url] = "`$toolsDir\files\$candidate"
}

if ($downloads | Where-Object Status -eq 'Failed') {
  $failed = $downloads | Where-Object Status -eq 'Failed' | ForEach-Object { $_.Url }
  throw "Internalize failed for $($pkgBase): $($failed -join ', ')"
}

# Rewrite scripts. We replace url=  with file= referencing $toolsDir\files\<name>.
# Make sure chocolateyInstall.ps1 has a $toolsDir definition; if not, inject one.
if ($installText -notmatch '\$toolsDir\s*=') {
  $installText = "`$toolsDir = Split-Path -Parent `$MyInvocation.MyCommand.Definition`r`n" + $installText
}

# Build a token map where the script-side token is a string literal with the
# resolved path expression. Rewriting expects literal-token replacement so we
# use the absolute local path in single-quoted form, but PowerShell single
# quotes don't interpolate $toolsDir. So instead we do a two-step:
#   - first replace "url = 'http://...'" with placeholder marker
#   - then expand markers to double-quoted file = "$toolsDir\files\..." entries
$mapForRewrite = @{}
foreach ($u in $urlToLocal.Keys) {
  # Use a unique placeholder we know won't appear in the script
  $marker = '__INT_FILE_' + ([Guid]::NewGuid().ToString('N')) + '__'
  $mapForRewrite[$u] = $marker
}
# Run rewrite using markers as the local path value
# First pass: bare $var = '<url>' assignments (docker-desktop pattern).
$installText = Rewrite-BareVariableUrls -Content $installText -UrlToLocalPath $mapForRewrite
# Second pass: hashtable url/url64/url64bit keys (legacy + most community pkgs).
$installText2 = Rewrite-HashtableUrls -Content $installText -UrlToLocalPath $mapForRewrite
# Now swap markers for the live token expression in double-quoted form
foreach ($u in $urlToLocal.Keys) {
  $marker = $mapForRewrite[$u]
  $token  = $urlToLocalToken[$u]
  # Replace 'marker' (single-quoted) with double-quoted "$toolsDir\files\name"
  $installText2 = $installText2.Replace("'$marker'", "`"$token`"")
}
Set-Content -Path $installPs1.FullName -Value $installText2 -Encoding UTF8 -NoNewline

if ($dataPs1) {
  # data.ps1 doesn't have $toolsDir in scope by default. Provide one at top.
  # IMPORTANT: use -AddOnly so original Url/Url64/Checksum keys are preserved.
  # The dotnet-aspnetruntime install scripts read $data.Url under Set-StrictMode
  # before our forwarding block runs - removing those keys throws "property
  # cannot be found". File/File64 are added as siblings; the forwarding block
  # injected below swaps them in at Install-ChocolateyPackage time.
  $dataText2 = "`$toolsDir = Split-Path -Parent `$MyInvocation.MyCommand.Path`r`n" + $dataText
  $dataText2 = Rewrite-HashtableUrls -Content $dataText2 -UrlToLocalPath $mapForRewrite -AddOnly
  foreach ($u in $urlToLocal.Keys) {
    $marker = $mapForRewrite[$u]
    $token  = $urlToLocalToken[$u]
    $dataText2 = $dataText2.Replace("'$marker'", "`"$token`"")
  }
  Set-Content -Path $dataPs1.FullName -Value $dataText2 -Encoding UTF8 -NoNewline

  # The dotnet-aspnetruntime install scripts read $data.Url and pass it via
  # `url = $data.Url`. The Url field now holds a local path, but Install-
  # ChocolateyPackage will still treat it as a URL. Patch the install script
  # to forward $data.File / $data.File64 as the file / file64 parameters.
  # NOTE: $data may be a hashtable (most common) or a PSCustomObject. The
  # check below works for both - hashtable index returns $null for missing
  # keys, and PSCustomObjects auto-bind property access to indexer too.
  $patch = @'

# === Internalized: route $data.File / $data.File64 to file / file64 ===
if ($null -ne $data['File'])   { $arguments['file']    = $data['File'];    $arguments.Remove('url');    $arguments.Remove('checksum');    $arguments.Remove('checksumType') }
if ($null -ne $data['File64']) { $arguments64['file64']= $data['File64'];  $arguments64.Remove('url64'); $arguments64.Remove('checksum64'); $arguments64.Remove('checksumType64') }
# === end internalized ===

'@
  $installText3 = Get-Content $installPs1.FullName -Raw
  if ($installText3 -match 'Install-ChocolateyPackage\s+@arguments\s+@arguments64') {
    $installText3 = $installText3 -replace '(?ms)(\$arguments64\s*=\s*@\{[^}]*\})', "`$1`r`n$patch"
    Set-Content -Path $installPs1.FullName -Value $installText3 -Encoding UTF8 -NoNewline
  }
}

# Special handling for Get-ChocolateyWebFile then direct execute (teams pattern).
# After our url= -> file= rewrite, Get-ChocolateyWebFile no longer makes sense
# (it expects a URL). Replace any "Get-ChocolateyWebFile @<varname>" line with
# a Copy-Item that uses the file= parameter we injected.
$installFinal = Get-Content $installPs1.FullName -Raw
if ($installFinal -match 'Get-ChocolateyWebFile\s+@(\w+)') {
  $argVar = $Matches[1]
  $replacement = @"
# === Internalized: replace Get-ChocolateyWebFile with local copy ===
if (`$$argVar.file -and `$$argVar.FileFullPath) { Copy-Item -Path `$$argVar.file -Destination `$$argVar.FileFullPath -Force }
"@
  $installFinal = $installFinal -replace 'Get-ChocolateyWebFile\s+@\w+', $replacement
  Set-Content -Path $installPs1.FullName -Value $installFinal -Encoding UTF8 -NoNewline
}

# Special handling for Install-DotNetFramework (chocolatey-dotnetfx.extension).
# Rewrite the whole install script to use Install-ChocolateyInstallPackage with
# the local file, since the extension package's function still wants a URL.
if ($installFinal -match 'Install-DotNetFramework\s+@(\w+)') {
  $argVar = $Matches[1]
  $localExe = $urlToLocal.Values | Select-Object -First 1
  $localExeBase = Split-Path -Leaf $localExe
  $rewrite = @"
`$toolsDir = Split-Path -Parent `$MyInvocation.MyCommand.Definition
`$packageArgs = @{
  packageName    = `$env:ChocolateyPackageName
  fileType       = 'exe'
  file           = Join-Path `$toolsDir 'files\$localExeBase'
  silentArgs     = '/q /norestart'
  validExitCodes = @(0, 1641, 3010, 5100)
}
Install-ChocolateyInstallPackage @packageArgs
"@
  Set-Content -Path $installPs1.FullName -Value $rewrite -Encoding UTF8 -NoNewline
}

# Repack
Write-Log INFO "Repacking to $destNupkg"
# If we're overwriting in place, first move original aside.
if ($sameFile) {
  $bak = "$($pkgFile.FullName).orig"
  if (-not (Test-Path $bak)) { Copy-Item $pkgFile.FullName $bak -Force }
}
Repack-Nupkg -Source $pkgWork -DestNupkg $destNupkg

# Cleanup
Remove-Item -Recurse -Force $pkgWork

[pscustomobject]@{
  Package    = $pkgBase
  Status     = 'Internalized'
  UrlCount   = $allUrls.Count
  TotalBytes = ($downloads | Measure-Object Bytes -Sum).Sum
  Output     = $destNupkg
}
