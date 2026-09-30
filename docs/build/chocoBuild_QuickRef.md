########## chocoBuild Quick Usage

#### What this is for
chocoBuild is the **build side** of the package lifecycle. It produces
trusted `.nupkg` files on the mirror that [chocoDeploy](../deploy/chocoDeploy_QuickRef.md)
then aligns onto the fleet. If you are aligning hosts, you want chocoDeploy.
If you are publishing a new package version to the mirror, you want chocoBuild.

#### Shared package catalog
The shared package contract is [playbooks/catalogs/chocolatey_packages.yml](../../playbooks/catalogs/chocolatey_packages.yml).
Use it to review the package ID, approved deployment version, acquisition method, source policy, mirror versions, and wrapper verification metadata.

The executable build inputs remain role-specific:
- [internalize-spec.yml](../../playbooks/roles/chocoBuild/files/internalize-spec.yml) drives community-feed internalization.
- [wrapper-spec.yml](../../playbooks/roles/chocoBuild/files/wrapper-spec.yml) drives wrapper synthesis and hash verification.
- [chocoDeploy defaults](../../playbooks/roles/chocoDeploy/defaults/main.yml) drives deployment policy.

Validate catalog coverage before building or deploying:
```bash
python3.12 playbooks/tools/validate_catalog.py
```
Errors mean a catalog `approved_version` differs from the chocoDeploy floor in `acceptable_versions` (promote both together), or a managed app is missing from the catalog. Warnings mean the approved deployment floor is newer than the currently staged mirror data, or that the role-specific specs differ from the shared catalog.

#### Campaigns and one-time removals
Use [campaigns/template.yml](../../campaigns/template.yml) as the reusable template for a change window with multiple phases or runs.
Copy the completed campaign manifest, raw target list, generated inventories,
protected-OU export, and inventory-check evidence to
`/opt/ansible/incoming/<campaign-id>/`. That is the default
`$CHOCO_FLEET_DATA_ROOT/incoming` path; override only by setting `CHOCO_FLEET_DATA_ROOT`
for the run.
Do not commit real fleet hostnames or one-time campaign manifests.
The campaign separates the overall window from individual playbook invocations, so canaries, waves, retries, one-time removals, and final reporting remain traceable.
Render commands without executing them:
```bash
python3.12 playbooks/tools/validate_catalog.py \
  --campaign /opt/ansible/incoming/<campaign-id>/<campaign>.yml \
  --ad-export /opt/ansible/incoming/<campaign-id>/ad-protected-objects.json
python3.12 playbooks/tools/render_campaign.py \
  /opt/ansible/incoming/<campaign-id>/<campaign>.yml \
  --ad-export /opt/ansible/incoming/<campaign-id>/ad-protected-objects.json
```
One-time removal is campaign intent. Keep the package in the shared catalog so it can still be built, mirrored, or installed later.

#### Two playbooks
- [`playbooks/chocoBuild.yml`](../../playbooks/chocoBuild.yml) - mirror-host build operations, selects action via `--tags`
- [`playbooks/chocoBuild-iterate.yml`](../../playbooks/chocoBuild-iterate.yml) - test-host extract/repack/install loop

#### Tags on chocoBuild.yml
- `--tags community`  internalize packages from the Chocolatey community feed (spec: [internalize-spec.yml](../../playbooks/roles/chocoBuild/files/internalize-spec.yml))
- `--tags wrapper`    build wrapper `.nupkg`s with hash-verified vendor binaries (spec: [wrapper-spec.yml](../../playbooks/roles/chocoBuild/files/wrapper-spec.yml))

Nothing runs without a tag. Every task is `tags: [never, <action>]`.

#### Tags on chocoBuild-iterate.yml
- `--tags extract`     unzip the `.nupkg` on the test host
- `--tags repack`      re-zip the workdir back into a `.nupkg`
- `--tags install`     test-install via chocoDeploy (narrow scope)
- `--tags iterate-all` extract + repack + install (rare; usually run separately)

#### Common runs

## Refresh the entire mirror from the community feed (idempotent)
```bash
ansible-playbook playbooks/chocoBuild.yml \
  -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags community
```

## Force re-download AND re-bundle every package
# Use after editing the internalize-package.ps1 rewriter so every nupkg picks up new logic.
```bash
ansible-playbook playbooks/chocoBuild.yml \
  -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags community \
  -e "choco_internalize_force=true"
```

## Build all wrapper packages (sentinel-gated; skips already-built entries)
```bash
ansible-playbook playbooks/chocoBuild.yml \
  -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags wrapper
```

## Force-rebuild a single wrapper entry
```bash
ansible-playbook playbooks/chocoBuild.yml \
  -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags wrapper \
  -e "wrapper_only=docker-desktop wrapper_force=true"
```

## Capture a SHA256 to pin in wrapper-spec.yml (base_nupkg_sha256)
```bash
ansible -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  -e @vault/corp-ans-secret.yml \
  basic_hosts -m ansible.windows.win_shell \
  -a "(Get-FileHash -Path 'C:\tools\chocoRepo\<id>\<id>.<base>.nupkg' -Algorithm SHA256).Hash.ToLower()"
```

#### Iterate-on-target loop

## Extract -> edit -> repack -> install (per phase)
```bash
# 1. Extract: unzips C:\tools\dockerfiles\<id>.<version>.nupkg
#    into C:\tools\chocoRepo-iterate\<id>\<version>\
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags extract \
  -e "iter_package=docker-desktop iter_version=4.76.1"

# 2. Edit on the test host (ad-hoc win_shell, RDP, whatever).
#    Common fix pattern (URL-encoded filenames):
ansible -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -e @vault/corp-ans-secret.yml \
  test-host-01.corp.example.com \
  -m ansible.windows.win_shell \
  -a "Get-ChildItem 'C:\tools\chocoRepo-iterate\docker-desktop\4.76.1\tools\files' -Filter '*%20*'"

# 3. Repack
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags repack \
  -e "iter_package=docker-desktop iter_version=4.76.1"

# 4. Install (delegates to chocoDeploy with narrow scope)
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags install \
  -e "iter_package=docker-desktop iter_version=4.76.1"
```

#### Adding a new package

## Community-feed package (the normal case)
1. Add `{ id: '<choco-id>', version: '<exact-version>' }` to [internalize-spec.yml](../../playbooks/roles/chocoBuild/files/internalize-spec.yml).
2. Run `--tags community`.
3. Validate via iterate-install on a TEST host.
4. Make it deployable in [chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml):
   - **Brand-new package:** add the `choco_managed_apps` entry and its `acceptable_versions` floor,
     then mirror it into [webui/catalog.json](../../webui/catalog.json) so the builder offers it.
   - **New version of an existing package:** stage it as a `choco_test_pins` candidate and follow the
     test-pin workflow in [chocoDeploy_QuickRef.md](../deploy/chocoDeploy_QuickRef.md). Do not edit the
     `acceptable_versions` floor until the candidate is validated; promotion is the last step, not the first.

## Wrapper package (vendor binary swap)
1. Internalize a BASE version via the community workflow.
2. Capture the cached BASE `.nupkg` SHA256 (see command above).
3. Add an entry to [wrapper-spec.yml](../../playbooks/roles/chocoBuild/files/wrapper-spec.yml):
   ```yaml
   - id: <choco-id>
     base_version: '<existing-internalized>'
     base_nupkg_sha256: '<sha256-of-base-on-mirror>'   # supply-chain guard
     new_version: '<version-to-stamp>'
     installer_url: '<official-vendor-direct-url>'
     installer_glob: '*<filename-pattern>*'
     checksums_url:  '<vendor-checksums.txt>'          # OR
     checksums_match: '<filename-in-checksums>'        # OR
     expected_sha256: '<pinned-hash>'                  # if no vendor checksums
   ```
4. Run `--tags wrapper`.
5. Validate via iterate-install on a TEST host.

#### Nexus repository (example package-source configuration)
Nexus can replace an SMB mirror after package integrity and lab install checks.

| Item | Value |
| --- | --- |
| Chocolatey (NuGet) repo | `http://192.0.2.20:8081/repository/chocolatey-development/` (anonymous read) |
| Installer binaries (raw) | `http://192.0.2.20:8081/repository/chocolatey-installers/` |
| Push credential | `vault/.nexus_api_key`, seeded from Key Vault with `misc/Nexus-ApiKey-Seed.ps1` |
| Required connectivity | Your control node and authorized lab target must reach the configured repository |

Ingest a community package (download, optional installer swap, push, manifest row):
```bash
python3.12 playbooks/roles/chocoBuild/files/nexus_ingest.py --id <choco-id> --version <version> --dry-run
python3.12 playbooks/roles/chocoBuild/files/nexus_ingest.py --id <choco-id> --version <version>
```
`--installer <file>` swaps in a different vendor binary before the push. The tool
also appends a run snapshot to the externally owned Nexus manifest
(`manifests/runs/<runid>/packages.nexus.csv`), which is kept by a separate tool
owned by another engineer; see [FUTURE_BUILDS.md](../FUTURE_BUILDS.md).

Install from Nexus on a run by naming it as the trusted source (this also registers
the source on each targeted host):
```bash
-e '{"trusted_choco_source":{"name":"nexus","url":"http://192.0.2.20:8081/repository/chocolatey-development/","priority":1}}'
```

Nexus content is not tracked by `internalize-spec.yml` or the catalog's
`mirror_versions`, and `validate_catalog.py` does not check it. List what it holds:
```bash
curl -s 'http://192.0.2.20:8081/service/rest/v1/search?repository=chocolatey-development&name=<choco-id>'
```
Confirm the approved floors are present before pointing any run at a new source.
No live repository inventory is included here.

#### Supply-chain trust hashes
Wrapper entries carry up to two hash pins -- both recommended:
- `base_nupkg_sha256`  verifies the cached community `.nupkg` before extraction (catches mirror tamper or poisoned community pull)
- `checksums_url`+`checksums_match` OR `expected_sha256`  verifies the downloaded vendor binary

When all three layers are populated, the chain from vendor URL to fleet-host install is hash-verifiable at every hop and all the verification material lives in this repo.

#### Sentinels + force flags
- `<repo>\<id>\.internalized\<version>.done` -- written on successful build, gates re-runs
- `-e "choco_internalize_force=true"` -- ignore community sentinels
- `-e "wrapper_force=true"` -- ignore wrapper sentinels
- `-e "wrapper_only=<id>"` -- limit wrapper run to a single spec entry

#### Mirror layout
```
C:\tools\chocoRepo\
  <package-id>\
    <package-id>.<version>.nupkg            <- bundled, ready to serve
    <package-id>.<version>.nupkg.orig       <- original community stub (kept for diff)
    .internalized\
      <version>.done                         <- sentinel
```

#### Inventories
- Mirror: [inventory/Internalize/inv-internalize.yml](../../inventory/Internalize/inv-internalize.yml)
- Test host (fast loop): [inventory/TEST/inv-TEST-solo.yml](../../inventory/TEST/inv-TEST-solo.yml)

#### Vault loading (same pattern as chocoDeploy)
- Playbooks: vault is auto-loaded via `vars_files:` in the play.
- Ad-hoc `ansible` invocations: add `-e @vault/corp-ans-secret.yml` or `ansible_user` resolves to undefined.

#### Notes
- A wrapper build that fails the SHA256 check exits non-zero with `{"Status":"Failed","Error":...}`. The corrupt download is removed automatically.
- `iterate_install` passes `choco_auto_discover_internalized_apps=false` and a single-element `targetSoftware` so it tests only the package under iteration.
- Never use `Compress-Archive` on `.nupkg` contents -- it emits backslash entry names that NuGet rejects. Use `System.IO.Compression.ZipArchive` with `\\` -> `/`. All chocoBuild repack code already does this.
- See [chocoBuild_Guide.md](chocoBuild_Guide.md) for the architecture overview, the supply-chain trust model in depth, and the install-script family taxonomy in [INTERNALIZE_FAMILIES.md](INTERNALIZE_FAMILIES.md).
- See [chocoDeploy_QuickRef.md](../deploy/chocoDeploy_QuickRef.md) for how the produced `.nupkg`s get aligned onto fleet hosts.
