# Install-script families (chocoBuild internalize taxonomy)

Community Chocolatey packages express their installer-fetch logic in
`tools/chocolateyInstall.ps1`. We've classified the patterns seen in our
current catalog (17 packages) into 5 families. The internalizer
([`files/internalize-package.ps1`](../../playbooks/roles/chocoBuild/files/internalize-package.ps1))
detects the family at scan time and rewrites accordingly. **You do not
choose the family in advance** - the script detects it from the install
script's shape.

When adding a brand-new app, you can preview which family it falls into
by inspecting the community package directly. The scratch package path below is
under `$CHOCO_FLEET_DATA_ROOT/LOGS` with the production default of `/opt/ansible`:

```bash
curl -s https://community.chocolatey.org/api/v2/package/<id>/<version> -o /opt/ansible/LOGS/chocoBuild/<id>-<version>.nupkg
unzip -p /opt/ansible/LOGS/chocoBuild/<id>-<version>.nupkg tools/chocolateyInstall.ps1
```

Then match against the patterns below. Family 1/1b/2 are safe for both
internalize AND wrapper-synthesis (clone-version-bump). Family 3/4
require manual review for wrapper-synthesis because their install
scripts were rewritten and may have version-specific silent-install
contract assumptions baked in.

## Family 1 - Inline `url`/`url64` in hashtable (~70% of packages)

The hashtable passed to `Install-ChocolateyPackage` has a `url(64)?(bit)?`
key whose value is a string literal URL.

```powershell
$packageArgs = @{
  packageName    = 'foo'
  fileType       = 'EXE'
  url64bit       = 'https://vendor.example/foo-1.2.3-x64.exe'
  checksum64     = 'abc123...'
  checksumType64 = 'sha256'
  silentArgs     = '/S'
}
Install-ChocolateyPackage @packageArgs
```

**What the internalizer does:** Downloads each URL into
`tools/files/<basename>`. Rewrites `url=`/`url64=`/`url64bit=` lines to
`file=`/`file64=` referencing the local path. Comments out adjacent
`checksum*` lines (no checksum needed for a local file we just placed).

**Catalog members:** `7zip.install`, `git.install`, `greenshot`,
`pycharm`, `putty.install`, `vim`, `winscp.install`, `python312`,
`python313`, `python314`, `powershell-core`.

## Family 1b - Bare `$var = 'url'` then hashtable references it (docker-desktop pattern)

A variation of Family 1 where the URL is assigned to a bare PowerShell
variable **outside** any hashtable, then referenced from inside.

```powershell
$url64 = 'https://vendor.example/foo-1.2.3-x64.exe'
$checksum64 = 'abc123...'

$packageArgs = @{
  url64bit       = $url64
  checksum64     = $checksum64
  ...
}
Install-ChocolateyPackage @packageArgs
```

**What the internalizer does:** Same idea as Family 1, but matches the
bare assignment first (`$url64 = '...'` becomes `$url64 = '<local-path>'`)
and then converts the hashtable `url64bit = $url64` to `file64 = $url64`.
Variable references preserved so the value flows correctly at runtime.

**Catalog members:** `docker-desktop`.

**History:** This pattern was missed by the original internalizer (the
Family 1 regex only matched hashtable lines). Caught and fixed June 9
2026 after docker-desktop installs silently no-op'd against a phantom
metadata state. See `_install_choco_orphan` + `force_replace_orphan`
logic in chocoDeploy for the fleet-side defense.

## Family 2 - Sibling `data.ps1` with URLs (dotnet runtimes)

The install script reads URLs from a separate dot-sourced `tools/data.ps1`
file:

```powershell
# tools/chocolateyInstall.ps1
. (Join-Path $toolsDir 'data.ps1')

Install-ChocolateyPackage @arguments @arguments64
```

```powershell
# tools/data.ps1
$arguments64 = @{
  Url64  = 'https://vendor.example/foo-1.2.3-x64.exe'
  Checksum64 = '...'
  ...
}
```

**What the internalizer does:** **Additive** rewrite of `data.ps1` -
keeps original `Url/Url64/Checksum*` keys (needed for `Set-StrictMode`
in install.ps1), adds parallel `File/File64` keys pointing to local
paths. Injects a runtime forwarding block into install.ps1 that swaps
`url -> file` in the hashtable just before
`Install-ChocolateyPackage` runs.

**Catalog members:** `dotnet-8.0-aspnetruntime`,
`dotnet-9.0-aspnetruntime`, `dotnet-10.0-aspnetruntime`.

**Wrapper-synthesis note:** For these, you'd swap the binary in
`tools/files/` AND update `data.ps1`'s `Url64` and `Checksum64` to the
new vendor values (the keys are still consulted under StrictMode even
though we forward to `File64` at call time).

## Family 3 - `Get-ChocolateyWebFile` + direct execute (teams)

The install script fetches the binary via `Get-ChocolateyWebFile` into a
specified path, then runs it directly:

```powershell
$args = @{
  PackageName   = 'foo'
  FileFullPath  = "$env:TEMP\foo.exe"
  Url           = 'https://vendor.example/foo.exe'
  Checksum      = '...'
}
Get-ChocolateyWebFile @args
Start-Process $args.FileFullPath -ArgumentList '/quiet'
```

**What the internalizer does:** Replaces the `Get-ChocolateyWebFile`
call with `Copy-Item -Path <local-binary> -Destination $args.FileFullPath`.
The rest of the install script (the direct execute) runs unchanged.

**Catalog members:** `microsoft-teams-new-bootstrapper`.

**Wrapper-synthesis caveat:** The vendor's silent-install argument
contract may change between versions. Validate the new build's
`--quiet` / `/quiet` flags still work before producing a wrapper.

## Family 4 - `Install-DotNetFramework` (netfx)

Packages from the `chocolatey-dotnetfx.extension` family call a custom
helper instead of `Install-ChocolateyPackage`:

```powershell
$args = @{ ... }
Install-DotNetFramework @args
```

**What the internalizer does:** Replaces the *entire* install script
with a stock `Install-ChocolateyInstallPackage` block pointing at the
local file. Loses any custom hooks the upstream extension provided.

**Catalog members:** `netfx-4.8.1`.

**Wrapper-synthesis caveat:** Same as Family 3 - validate silent-install
args + that the new .NET Framework build accepts them.

## Family 5 - Meta package OR already-bundled

Either there is no `tools/` directory (meta package, just declares
dependencies), or the install script does not reference any URLs (vendor
binary already inside the `.nupkg`).

**What the internalizer does:** Copies the `.nupkg` as-is. Marks the
result `Meta` or `AlreadyBundled` in the per-package report.

**Catalog members:** `git` (meta, depends on `git.install`).

## Distribution across our current catalog

| Family | Count | Members |
|---:|:---:|---|
| 1 | 11 | 7zip.install, git.install, greenshot, pycharm, putty.install, vim, winscp.install, python312, python313, python314, powershell-core |
| 1b | 1 | docker-desktop |
| 2 | 3 | dotnet-8.0-aspnetruntime, dotnet-9.0-aspnetruntime, dotnet-10.0-aspnetruntime |
| 3 | 1 | microsoft-teams-new-bootstrapper |
| 4 | 1 | netfx-4.8.1 |
| 5 | 1 | git (meta) |

## What's NOT supported

URLs constructed at runtime from concatenated variables, template
strings, or auto-update logic are NOT detected by the regex scan.
Symptom: `Found 0 URL(s) to internalize`. Such packages would need
either a new family handler added to `internalize-package.ps1`, or a
package-specific override script. None of our current catalog falls
into this category - if a new app does, plan for ~2 hours of regex
work to extend the internalizer.

## How to verify after internalize

Use the iterate-extract action to unpack the internalized `.nupkg` and
inspect the rewritten install script:

```bash
# Copy nupkg to a test host first (out-of-band)
# Then:
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags extract \
  -e "iter_package=<id> iter_version=<ver>"
```

The extract action prints the install script. Look for:
- No `https://` URLs remaining
- `file`/`file64` references to `$toolsDir\files\<name>` (Family 1/1b/2)
- OR `Copy-Item` from `$toolsDir\files\<name>` (Family 3)
- OR a complete stock `Install-ChocolateyInstallPackage` block (Family 4)
- Filenames in `tools/files/` should be **URL-decoded** (no `%20` etc).
  Bug fixed June 9 2026 in `Get-FileNameFromUrl`.
