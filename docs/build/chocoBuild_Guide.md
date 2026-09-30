########## chocoBuild Role Guide
# For a shorter operator run guide, see [chocoBuild_QuickRef.md](chocoBuild_QuickRef.md).

#### Purpose
# `chocoBuild` produces trusted, self-contained `.nupkg` files for the
# internal Chocolatey mirror used by [`chocoDeploy`](../deploy/).
# This role focuses on the *build* side of the package lifecycle.
# Fleet alignment, drift detection, and install execution belong to
# [`chocoDeploy`](../deploy/).
# This guide is aimed at an administrator who needs to know how to
# extend the package catalog, where the trust hashes come from, and
# how to develop a package iteratively before publishing it.

#### What the role manages
- Community-feed internalization (download `.nupkg` + bundle vendor binaries inline)
- Wrapper synthesis (clone an internalized base + swap in a SHA-verified vendor binary)
- Iterate-on-target loop for developing a package on a real Windows host
- (Future) First-party package authoring from a vendor URL + template
- (Future) Install-script family classifier for previewing community packages

#### Why a separate role from chocoDeploy
# chocoBuild and chocoDeploy have different audiences and different
# failure modes. Keeping them split lets each evolve without disturbing
# the other. The two roles cooperate through a single source of truth:
# the `.nupkg` files on the mirror's `C:\tools\chocoRepo\` tree.

| Concern    | chocoBuild | chocoDeploy |
|---|---|---|
| Audience   | Package author / fleet engineer | Fleet operator |
| Cadence    | Per package version (rare) | Per maintenance window (recurring) |
| Inputs     | URLs / community ids / vendor binaries | `.nupkg` files in a trusted source |
| Outputs    | `.nupkg` on the mirror | Aligned application state on Windows hosts |
| Test target| Mirror host + optional Windows test host | Windows fleet hosts |
| Failure mode | regex / rewriter / signing bugs | host-state weirdness, drift detection |

# chocoBuild does NOT duplicate chocoDeploy's install logic. When
# chocoBuild needs to validate that a built `.nupkg` installs correctly
# (iterate-install action), it delegates to chocoDeploy with narrow
# scope. Single source of install truth.

### Shared package catalog
The common package contract is [playbooks/catalogs/chocolatey_packages.yml](../../playbooks/catalogs/chocolatey_packages.yml).
Both the build and deploy playbooks load this catalog.
It records package identity, aliases, approved deployment version, version policy, acquisition method, source policy, mirror versions, and wrapper verification metadata.

Candidate and promoted versions can also carry a `version_timeline` with
`public_feed_created`, `public_feed_updated`, `candidate_staged`,
`mirror_ingested`, `test_installed`, `tested_on`, `test_host`, and
`promoted_on` fields. These dates support monthly compliance explanations by
showing whether time was spent waiting for a public release, ingesting the
package, testing it, or approving the production floor.

The catalog is not a replacement for the role-specific files:
- `chocoBuild/files/internalize-spec.yml` remains the executable community-feed internalization input.
- `chocoBuild/files/wrapper-spec.yml` remains the executable wrapper build input with vendor URLs and hashes.
- `chocoDeploy/defaults/main.yml` remains the executable deployment policy and application behavior catalog.

The shared catalog is the contract used to compare those role-specific inputs and expose drift.
Run the validator before a build or deployment change:
```bash
python3.12 playbooks/tools/validate_catalog.py
```
Warnings identify staged mirror versions that do not yet cover the approved deployment floor.
They must be resolved or consciously accepted before relying on an internal mirror for that package.

### Campaigns and multi-run change windows
A package build is not a campaign. A campaign is the operational change window that may consume one or more built packages across multiple inventories and playbook runs.
Use [campaigns/template.yml](../../campaigns/template.yml) as the reusable template, then copy the completed manifest, target inventories, protected-OU export, and inventory-check evidence to `/opt/ansible/incoming/<campaign-id>/`.
That path is `$CHOCO_FLEET_DATA_ROOT/incoming` with the production default of `/opt/ansible/incoming`.
Keep real target lists, dated inventories, and one-time campaign manifests outside this repository.
One-time removal belongs in the campaign manifest and does not delete the package from this catalog or retire its source metadata.
The campaign is the control plane for the change window. The inventory files are run-specific child artifacts, not a competing deployment model.

### Supply-chain trust model (June 2026)
# Recent npm / PyPI / community-package compromises have made upstream
# feeds an active threat vector. chocoBuild's defense is a three-layer
# trust chain CAPTURED ENTIRELY IN THE SPEC FILES. No per-host trust
# decisions are made at deploy time -- clients trust only the mirror,
# and the mirror's content is verifiable against hashes that live in
# this repository.

# 1. Base `.nupkg` integrity
#    - `wrapper-spec.yml` entries take an optional `base_nupkg_sha256` pin.
#    - When present, `build_wrapper_nupkg.ps1` hashes the cached base
#      package before extraction and refuses to clone an unverified base.
#    - Catches a poisoned mirror cache or a tampered community pull.

# 2. Installer binary integrity
#    - Each wrapper entry carries either
#      `checksums_url` + `checksums_match` (parse the vendor's published
#      checksums file) OR `expected_sha256` (a pinned hash).
#    - The downloaded binary is verified before being packed.

# 3. Local repack
#    - The produced `.nupkg` is built locally on the mirror.
#    - Clients never pull from a third party at install time.

# When all three are populated for a wrapper entry, the trust path from
# vendor URL -> installed binary on the fleet host is hash-verifiable
# at every hop, with all the verification material captured in version
# control here.

### Action vocabulary
# The role's dispatcher in `tasks/main.yml` takes a `chocoBuild_action`
# variable, but most callers use the top-level playbook with `--tags`
# rather than calling the dispatcher directly.

| Action | Status | Purpose |
|---|---|---|
| `source_community`  | implemented | Download from community feed + bundle vendor binaries |
| `source_wrapper`    | implemented | Clone base + swap binary + verify SHA256 + repack (spec-driven) |
| `iterate_extract`   | implemented | Unzip a staged `.nupkg` on a test host into a workdir |
| `iterate_repack`    | implemented | Repack a workdir back into `.nupkg` |
| `iterate_install`   | implemented | Run choco install/upgrade against the local stage (delegates to chocoDeploy) |
| `source_firstparty` | placeholder | Download vendor binary + verify SHA256 + render install.ps1 (future) |
| `inspect_classify`  | placeholder | Download + classify install-script family (future) |

### Key files
- top-level playbook: [playbooks/chocoBuild.yml](../../playbooks/chocoBuild.yml)
- iterate playbook: [playbooks/chocoBuild-iterate.yml](../../playbooks/chocoBuild-iterate.yml)
- role defaults: [playbooks/roles/chocoBuild/defaults/main.yml](../../playbooks/roles/chocoBuild/defaults/main.yml)
- role dispatcher: [playbooks/roles/chocoBuild/tasks/main.yml](../../playbooks/roles/chocoBuild/tasks/main.yml)
- community internalize: [playbooks/roles/chocoBuild/tasks/source/community.yml](../../playbooks/roles/chocoBuild/tasks/source/community.yml)
- wrapper synthesis: [playbooks/roles/chocoBuild/tasks/source/wrapper.yml](../../playbooks/roles/chocoBuild/tasks/source/wrapper.yml)
- iterate tasks: [playbooks/roles/chocoBuild/tasks/iterate](../../playbooks/roles/chocoBuild/tasks/iterate)
- internalize spec (community): [playbooks/roles/chocoBuild/files/internalize-spec.yml](../../playbooks/roles/chocoBuild/files/internalize-spec.yml)
- wrapper spec (trust hashes): [playbooks/roles/chocoBuild/files/wrapper-spec.yml](../../playbooks/roles/chocoBuild/files/wrapper-spec.yml)
- internalize workhorse (rewrites install script): [playbooks/roles/chocoBuild/files/internalize-package.ps1](../../playbooks/roles/chocoBuild/files/internalize-package.ps1)
- wrapper helper (package-agnostic build script): [playbooks/roles/chocoBuild/files/build_wrapper_nupkg.ps1](../../playbooks/roles/chocoBuild/files/build_wrapper_nupkg.ps1)
- standalone repacker: [playbooks/roles/chocoBuild/files/repack_nupkg.ps1](../../playbooks/roles/chocoBuild/files/repack_nupkg.ps1)
- install-script family taxonomy: [INTERNALIZE_FAMILIES.md](INTERNALIZE_FAMILIES.md)

#### Before you run
- use the same Ansible control node as chocoDeploy
- confirm admin rights on the mirror host (mirror inventory)
- confirm admin rights on the test host (iterate inventory) when using `chocoBuild-iterate.yml`
- confirm WinRM connectivity to both
- the mirror host needs Chocolatey installed and network access to the community feed plus all vendor URLs
- ~3 GB free under `C:\tools\chocoRepo\` for the current catalog; wrapper `.nupkg`s grow this further (Docker Desktop is ~630 MB each)
- vault material is loaded the same way as chocoDeploy -- see chocoDeploy_Guide.md "Vault loading" section

#### Mirror host layout
```
C:\tools\chocoRepo\
  <package-id>\
    <package-id>.<version>.nupkg            <- bundled, ready to serve
    <package-id>.<version>.nupkg.orig       <- original community stub (kept for diff)
    .internalized\
      <version>.done                         <- sentinel; re-runs skip this version
  internalize-package.ps1                    <- uploaded by community task
  build_wrapper_nupkg.ps1                    <- uploaded by wrapper task
```

#### Basic run pattern
## Run from the repo root
```bash
ansible-playbook playbooks/chocoBuild.yml \
  -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags <action>
```

# The `--tags` flag selects which action to run. Nothing runs without
# a tag -- every task in chocoBuild.yml is `tags: [never, <action>]`
# so the playbook is a no-op if invoked without a tag.

### Available tags
- `--tags community`  internalize from the Chocolatey community feed (uses [internalize-spec.yml](../../playbooks/roles/chocoBuild/files/internalize-spec.yml))
- `--tags wrapper`    build wrapper `.nupkg`s with hash-verified vendor binaries (uses [wrapper-spec.yml](../../playbooks/roles/chocoBuild/files/wrapper-spec.yml))

#### Common runs

## Refresh the entire internalized mirror from the community feed
# Idempotent. Skips packages that already have a sentinel in
# `.internalized\<version>.done` unless `choco_internalize_force=true`.
```bash
ansible-playbook playbooks/chocoBuild.yml \
  -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags community
```

## Force re-download AND re-bundle every package in the spec
# Use after editing `internalize-package.ps1` (the script-rewriting
# workhorse) so the new rewriter logic is applied to every `.nupkg`.
```bash
ansible-playbook playbooks/chocoBuild.yml \
  -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags community \
  -e "choco_internalize_force=true"
```

## Build all wrapper packages from wrapper-spec.yml
# Sentinel-gated; skips entries already built.
```bash
ansible-playbook playbooks/chocoBuild.yml \
  -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags wrapper
```

## Force-rebuild a single wrapper entry
# Useful after editing wrapper-spec.yml or correcting a captured hash.
```bash
ansible-playbook playbooks/chocoBuild.yml \
  -i inventory/Internalize/inv-internalize.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags wrapper \
  -e "wrapper_only=docker-desktop wrapper_force=true"
```

#### Iterate-on-target workflow
# The iterate playbook lets you develop a package directly on a Windows
# test host without round-tripping through the mirror. Each invocation
# selects one phase via `--tags`:
- `--tags extract`  unzip a staged `.nupkg` into `C:\tools\chocoRepo-iterate\<id>\<version>\`
- `--tags repack`   re-zip the workdir back into a `.nupkg`
- `--tags install`  run choco install/upgrade against the local stage (delegates to chocoDeploy)
- `--tags iterate-all`  do all three in sequence (rare; usually run separately)

# Why iterate on the test host and not on the mirror?
# Recopying a 600 MB `.nupkg` from the mirror to a test host over WinRM
# takes ~1.5 hours per direction. Iterating directly on the test host
# is seconds. The mirror is the *published* location; the test host is
# the *development* location.

## Typical iterate loop
```bash
# 1. extract
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags extract \
  -e "iter_package=docker-desktop iter_version=4.76.1"

# 2. edit files in C:\tools\chocoRepo-iterate\docker-desktop\4.76.1\
#    via ad-hoc ansible win_shell, RDP, WinRM, or any remote tool

# 3. repack
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags repack \
  -e "iter_package=docker-desktop iter_version=4.76.1"

# 4. install (delegates to chocoDeploy with narrow scope)
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags install \
  -e "iter_package=docker-desktop iter_version=4.76.1"
```

#### Adding a new package
### Community-feed package (the normal case)
1. Add `{ id: '<choco-id>', version: '<exact-version>' }` to [internalize-spec.yml](../../playbooks/roles/chocoBuild/files/internalize-spec.yml).
2. Bump the matching entry in [chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml) `acceptable_versions` so the fleet role knows about it.
3. Run `--tags community` against the mirror.
4. Validate the bundled `.nupkg` installs end-to-end via the iterate workflow on a TEST host.

### Wrapper package (no community release available)
1. Internalize an earlier BASE version via the community workflow.
2. Capture the BASE `.nupkg`'s SHA256 on the mirror:
   ```powershell
   (Get-FileHash -Path 'C:\tools\chocoRepo\<id>\<id>.<base>.nupkg' -Algorithm SHA256).Hash.ToLower()
   ```
3. Locate the vendor's official download URL and either its published
   checksums file or a pinned SHA256 for the binary.
4. Add an entry to [wrapper-spec.yml](../../playbooks/roles/chocoBuild/files/wrapper-spec.yml) with all
   seven fields populated (`base_nupkg_sha256` is optional but strongly
   recommended -- it's the supply-chain guard for the cloned base).
5. Run `--tags wrapper`.
6. Validate via iterate-install on a TEST host.

#### Sentinels and force flags
- Each `.nupkg` build writes `<repo>\<id>\.internalized\<version>.done`
  on success. Subsequent runs skip that entry unless forced.
- `-e "choco_internalize_force=true"` ignores community sentinels.
- `-e "wrapper_force=true"` ignores wrapper sentinels.
- `-e "wrapper_only=<id>"` limits a wrapper run to a single spec entry.

#### Install-script families
# Not every community package has the same install-script shape.
# `internalize-package.ps1` recognizes and rewrites several families;
# see [INTERNALIZE_FAMILIES.md](INTERNALIZE_FAMILIES.md) for the full
# taxonomy. When adding a new package, classify which family it falls
# into before adding it to the spec -- if it does not fit one of the
# supported patterns, the internalizer will leave it as-is (and a
# wrapper or first-party authoring path may be required).

#### The NuGet repack gotcha
# A `.nupkg` is just a `.zip`, BUT NuGet/OPC requires forward-slash
# entry names inside the archive. PowerShell 5.1's `Compress-Archive`
# emits backslashes on Windows and produces a zip NuGet rejects with
# *"is not a valid nupkg" / "End of Central Directory record could not
# be found"*. All chocoBuild repack code uses
# `System.IO.Compression.ZipArchive` directly with `\\` -> `/`
# substitution. **Never use `Compress-Archive` on `.nupkg` contents.**

#### Inventories
- Mirror: [inventory/Internalize/inv-internalize.yml](../../inventory/Internalize/inv-internalize.yml)
- Iterate test host (single host, fast loop): [inventory/TEST/inv-TEST-solo.yml](../../inventory/TEST/inv-TEST-solo.yml)
- TEST host: [inventory/TEST/inv-TEST-solo.yml](../../inventory/TEST/inv-TEST-solo.yml)

#### Notes
- The `wrapper` action is intentionally non-destructive towards the BASE `.nupkg` -- the staging dir is a temp copy; the original is left untouched on the mirror.
- A wrapper build that fails on the SHA256 check exits non-zero and emits `{"Status":"Failed","Error":...}`. The cached corrupt download is removed automatically.
- `iterate_install` calls into chocoDeploy with `choco_auto_discover_internalized_apps=false` and a single-element `targetSoftware` so it tests only the package under iteration.
- See [chocoDeploy_Guide.md](../deploy/chocoDeploy_Guide.md) for the consuming side: how fleet hosts pull from the mirror and align.
