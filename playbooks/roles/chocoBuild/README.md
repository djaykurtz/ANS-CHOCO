# chocoBuild role

The `chocoBuild` role produces trusted, self-contained `.nupkg` files
for the Chocolatey mirror. It is the **build half** of the chocoDeploy
pipeline; the **deploy half** lives in [`chocoDeploy`](../chocoDeploy/).

```
┌──────────────────────────────────────────────────────────────────────┐
│                         chocoBuild                                   │
│                                                                      │
│   community feed  ──┐                                                │
│   vendor URL     ──┼──> [tasks/source/*]  ──> .nupkg on mirror       │
│   prior version  ──┘            │                                    │
│                                 │                                    │
│   .nupkg already on a TEST host ┴─> [tasks/iterate/*]                │
│                                     extract → edit → repack → install│
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
                          mirror @ \\mirror-01\c$\tools\chocoRepo\
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                         chocoDeploy                                  │
│                                                                      │
│   .nupkg from mirror  ──> drift detect ──> install/upgrade ──> report│
└──────────────────────────────────────────────────────────────────────┘
```

## When to use this role

| You want to... | Use |
|---|---|
| Mirror approved community packages locally | [`chocoBuild.yml --tags community`](../../chocoBuild.yml) |
| Build wrapper `.nupkg`s with verified vendor binaries (spec-driven) | [`chocoBuild.yml --tags wrapper`](../../chocoBuild.yml) |
| Author a package from scratch using a vendor URL | TBD (`tasks/source/firstparty.yml`, Phase 6) |
| Iterate on a `.nupkg` already staged on a TEST host | [`chocoBuild-iterate.yml`](../../chocoBuild-iterate.yml) |
| Classify a community package's install-script family before adding it | TBD (`tasks/inspect/classify-family.yml`, future) |
| Install / upgrade / uninstall packages on fleet hosts | NOT chocoBuild - use [`chocoDeploy`](../chocoDeploy/) |

## Supply-chain trust model

With recent npm / PyPI / community-package compromises in mind, the
role defends the install chain in three layers, all captured in
spec files (no per-host trust decisions at deploy time):

1. **Base `.nupkg` integrity** -- [`wrapper-spec.yml`](files/wrapper-spec.yml)
   entries take an optional `base_nupkg_sha256` pin. When set, the
   helper hashes the cached base package before extracting it and
   refuses to clone an unverified base. Catches a poisoned mirror
   cache or a tampered community pull.
2. **Installer binary integrity** -- each wrapper entry carries either
   `checksums_url`+`checksums_match` (parse the vendor's official
   checksums file) or `expected_sha256` (pinned hash). The downloaded
   binary is verified before being packed.
3. **Local repack** -- the produced `.nupkg` is built by us on the
   mirror, never pulled from a third party at deploy time. Clients
   trust only the mirror (and the SHA records they can audit in this
   repo).

Adding a new wrapper = edit [`files/wrapper-spec.yml`](files/wrapper-spec.yml).
No code change required.

## Action vocabulary

The role's `tasks/main.yml` dispatcher takes `chocoBuild_action`:

| Action | Status | Purpose |
|---|---|---|
| `iterate_extract` | implemented | Unzip a staged `.nupkg` on a test host into a workdir |
| `iterate_repack` | implemented | Repack a workdir back into `.nupkg` (NuGet-valid forward-slash entry names) |
| `iterate_install` | implemented | Run choco install/upgrade against the local stage by delegating to chocoDeploy |
| `source_community` | implemented | Download from community feed + bundle vendor binaries |
| `source_wrapper` | implemented | Clone prior version + swap binary + verify SHA256 + repack (spec-driven via `wrapper-spec.yml`) |
| `source_firstparty` | placeholder | Download vendor binary + verify SHA256 + render install.ps1 |
| `inspect_classify` | placeholder | Download + classify install-script family |

Most callers invoke a specific action via a top-level playbook (e.g.
`chocoBuild-iterate.yml`) rather than calling the dispatcher directly.

## Iterate-on-target workflow

The single most useful piece of this role for day-to-day development:

```bash
# 1. Extract: unzip the .nupkg on the test host into a workdir
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags extract \
  -e "iter_package=docker-desktop iter_version=4.76.1"

# 2. Edit on the test host
#    Files at C:\tools\chocoRepo-iterate\<id>\<version>\
#    Use ad-hoc ansible win_shell, RDP, or any remote-edit you like

# 3. Repack
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags repack \
  -e "iter_package=docker-desktop iter_version=4.76.1"

# 4. Install (delegates to chocoDeploy)
ansible-playbook playbooks/chocoBuild-iterate.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --tags install \
  -e "iter_package=docker-desktop iter_version=4.76.1"
```

Why iterate-on-target instead of iterate-on-mirror? Recopying large
nupkgs over WinRM adds avoidable transfer work to each edit/test cycle.
Iterating directly on the test host keeps that work local. The mirror
is the **published** location; the test host is the **dev** location.

## Why split from chocoDeploy

The two roles have different audiences and lifecycles:

| Concern | chocoBuild | chocoDeploy |
|---|---|---|
| Audience | Package author / fleet engineer | Fleet operator |
| Cadence | Per package version (rare) | Per maintenance window (recurring) |
| Inputs | URLs / community ids / vendor binaries | `.nupkg` files in a trusted source |
| Outputs | `.nupkg` on the mirror | Aligned application state on Windows hosts |
| Test target | Mirror (mirror-01) + optional test host | Windows fleet hosts |
| Failure mode | regex / rewriter / signing bugs | host-state weirdness, drift detection |

Crucially, **chocoBuild does not duplicate chocoDeploy's install logic**.
When chocoBuild needs to validate that a built `.nupkg` installs
correctly (e.g. the iterate-install action), it includes chocoDeploy as
a sub-role with narrow scope. Single source of install truth.

## Key files

- [`defaults/main.yml`](defaults/main.yml) - mirror root, iterate root, install delegation knobs
- [`tasks/main.yml`](tasks/main.yml) - dispatcher; routes `chocoBuild_action` to a sub-task
- [`tasks/source/community.yml`](tasks/source/community.yml) - community-feed internalize pipeline
- [`tasks/source/wrapper.yml`](tasks/source/wrapper.yml) - spec-driven wrapper synthesis (clone base + swap verified binary)
- [`tasks/iterate/`](tasks/iterate/) - extract/repack/install actions
- [`files/internalize-package.ps1`](files/internalize-package.ps1) - the install-script-rewriting workhorse (see [INTERNALIZE_FAMILIES.md](../../../docs/build/INTERNALIZE_FAMILIES.md) for the patterns it handles)
- [`files/repack_nupkg.ps1`](files/repack_nupkg.ps1) - standalone ZipArchive forward-slash repacker
- [`files/build_wrapper_nupkg.ps1`](files/build_wrapper_nupkg.ps1) - package-agnostic wrapper builder (driven by wrapper-spec.yml; verifies base + binary SHA256)
- [`files/internalize-spec.yml`](files/internalize-spec.yml) - catalog of `{id, version}` pairs to mirror
- [`files/wrapper-spec.yml`](files/wrapper-spec.yml) - catalog of wrapper builds (base/new versions, vendor URLs, trust hashes)

## The NuGet repack gotcha (worth knowing)

A `.nupkg` is just a `.zip`, BUT NuGet/OPC requires forward-slash entry
names inside the archive. PowerShell 5.1's `Compress-Archive` emits
backslashes on Windows and produces a zip NuGet rejects with
*"is not a valid nupkg" / "End of Central Directory record could not be
found"*. The role's `Repack-Nupkg` function and standalone
`repack_nupkg.ps1` both enforce forward slashes via
`System.IO.Compression.ZipArchive`. **Never use `Compress-Archive` on
nupkg contents.**

## Status / roadmap

Planned: the first-party trust mode, repack/verify/sign operations, and the
package-family classifier are stubs today (they fail with a clear message).
