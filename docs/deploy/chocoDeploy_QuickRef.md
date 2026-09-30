########## chocoDeploy Quick Usage

#### Where chocoDeploy fits
`chocoDeploy` is the **deploy side** of the package lifecycle: it aligns
fleet hosts to the `.nupkg`s already on the mirror. The **build side**
(internalize from community, wrapper synthesis, iterate-on-target) is
the sibling [`chocoBuild`](../build/chocoBuild_QuickRef.md) role.
If you are publishing or rebuilding a `.nupkg`, you want chocoBuild;
if you are aligning hosts, you are in the right place.

#### Shared package catalog and campaigns
The common package contract is [playbooks/catalogs/chocolatey_packages.yml](../../playbooks/catalogs/chocolatey_packages.yml).
It records package IDs, aliases, approved versions, acquisition method, source policy, mirror versions, and wrapper verification metadata.
The build and deploy playbooks load it automatically. Role-specific behavior remains in the role catalogs.
Candidate timelines record public feed publication, mirror ingestion, TEST validation, and production promotion dates.

Use [campaigns/template.yml](../../campaigns/template.yml) as the reusable template when a change window has more than one run.
A completed campaign, its raw target list, and its generated inventories belong outside the repo, under `/opt/ansible/incoming/<campaign-id>/`.
That path is `$CHOCO_FLEET_DATA_ROOT/incoming` with the production default of `/opt/ansible/incoming`.
A campaign is an ordered set of phases, and each phase contains one or more explicit playbook runs.
Use this for canaries, waves, remediation retries, one-time removals, and final reporting.

For new work, use the external campaign directory as the run bundle:
`/opt/ansible/incoming/<campaign-id>/`.
The campaign manifest is authoritative. Its run entries point to the generated inventory files.
The old `inventory/Deployment/<date>/` folders were the pre-campaign way of doing this. They moved
to the external campaign store on 2026-09-21. The repo tracks only `inventory/TEST/` and
`inventory/Internalize/`; everything else under `inventory/` is gitignored.

Build inventories from a received CSV before running a campaign:
```bash
python3.12 playbooks/tools/csv_to_inventory.py /opt/ansible/incoming/<campaign-id>/<list>.csv \
  --campaign-id <campaign-id> \
  --name all \
  --ad-export /opt/ansible/incoming/<campaign-id>/ad-protected-objects.json
```

Validate and render a campaign without executing anything:
```bash
python3.12 playbooks/tools/validate_catalog.py \
  --campaign /opt/ansible/incoming/<campaign-id>/<campaign>.yml \
  --ad-export /opt/ansible/incoming/<campaign-id>/ad-protected-objects.json

python3.12 playbooks/tools/render_campaign.py \
  /opt/ansible/incoming/<campaign-id>/<campaign>.yml \
  --ad-export /opt/ansible/incoming/<campaign-id>/ad-protected-objects.json
```

`validate_catalog.py --campaign` and `render_campaign.py` warn if a protected
host is already present in a built inventory, but they do not block and rendered
commands contain no scope variable. The rule is enforced when inventories are
created.

## Protected-OU rule (inventory creation)

Hosts beneath either of these OUs must never be put into generated inventories:

- `OU=Restricted,OU=Services,OU=Lab,OU=CloudSync,OU=Managed,DC=corp,DC=example,DC=com`
- `OU=Restricted,OU=Services,OU=Lab,OU=LocalOnly,OU=Managed,DC=corp,DC=example,DC=com`

The policy is defined in
[playbooks/policies/target_exclusions.yml](../../playbooks/policies/target_exclusions.yml).
Do not duplicate the DNs in command wrappers or future playbooks. Update this
single file only after explicit authorization.

On a Windows administration host with the ActiveDirectory module, create the
protected-object evidence file. `ansible-ctl-01` is joined to
`example.com`, not `corp`, and cannot generate this export itself.
Use `-HostListPath` when you have the received list so the check report records
where every listed host lives in AD and which hosts AD does not know:

```powershell
.\playbooks\tools\export_protected_ad_objects.ps1 -OutputPath .\ad-protected-objects.json -HostListPath .\<list>.csv
```

Copy the JSON to `/opt/ansible/incoming/<campaign-id>/ad-protected-objects.json`.
Then generate inventories from the received CSV:

```bash
python3.12 playbooks/tools/csv_to_inventory.py /opt/ansible/incoming/<campaign-id>/<list>.csv \
  --campaign-id <campaign-id> \
  --name all \
  --ad-export /opt/ansible/incoming/<campaign-id>/ad-protected-objects.json
```

`csv_to_inventory.py` reads the host column automatically (`DeviceName`,
`Hostname`, `Host`, `ComputerName`, `Computer`, `Name`, `Target`, `CN`, or
`FQDN`) or accepts `--column`. Short names get
`.corp.example.com`.

Protected hosts are left out of every generated inventory and printed as
`WARN excluded <host>: protected OU <id> (<DN>)`; they are also written to
`<campaign-id>-<name>-excluded.txt`. The rest of the inventory is written.
Protected hosts are never contacted. Every other host gets DNS and WinRM TCP
5985 probes from the control node; use `--no-probe`, `--timeout`, and
`--workers` only when appropriate.

The tool writes to `$CHOCO_FLEET_DATA_ROOT/incoming/<campaign-id>/` (default
`/opt/ansible`):

- `inv-<campaign-id>-<name>.yml` - all hosts outside protected OUs
- `inv-<campaign-id>-<name>-ready.yml` - only hosts answering WinRM 5985
- `<campaign-id>-<name>-check.json` - per-host AD location, DNS, WinRM, evidence path, and evidence timestamp
- `group_vars/basic_hosts.yml` - WinRM connection vars, created if missing

It refuses to overwrite existing inventories unless `--force`. The AD export is
required; if it is missing or unreadable the tool exits `2` and writes nothing.

Other inventory creation and review paths:

- `gen_inventories.py` applies the same rule for spreadsheet-derived per-app
  inventories: protected hosts are left out with a warning, the rest is written,
  and `--ad-export` is still required.
- `lint_target_scope.py` remains available as a manual check of any list or
  inventory. Exit `1` means protected hosts were found; exit `2` means an
  evidence problem.

For a removal-only campaign, use `choco_update` with explicit empty app and runtime lists:
```yaml
targetSoftware: []
removeSoftware:
  - temporary-test-package
targetRuntimes: []
```
Keep the package in the shared catalog. The campaign is temporary intent for a target cohort, not package retirement.
Use `choco_selective` only when the run also has a non-empty `targetSoftware` replacement or addition.

#### Web builder (optional)
For an interactive lego-brick command assembler, run `./webui/run.sh` from the repo root and open <http://127.0.0.1:5050/>. The builder generates the same commands shown below and copies them to your clipboard. It does not execute ansible. See [webui/README.md](../../webui/README.md).

#### Modes
- `choco_conversion` - convert detected software to Chocolatey management
- `choco_update` - fast Chocolatey-only alignment
- `choco_baseline` - install and align the full approved catalog
- `choco_selective` - install/align ONLY explicitly-named apps on existing nodes
  (install-if-missing + convert-if-vendor + upgrade-if-present). Requires a
  non-empty `targetSoftware`; no full-catalog fallback. Use this to add/update
  one specific app across deployed hosts without baseline's full-catalog risk.
- `report_only` - rebuild the consolidated HTML report from existing JSON files without modifying software

#### Run pattern
### Operator command framing standard (high emphasis)
- Use this multiline framing for ALL production runs and runbooks.
- Keep arg order stable: playbook, inventory, vault file, target limit, then `-e` vars.
- Keep output fully visible in the streaming terminal. Do not truncate with `| tail`.
- This is a review requirement for this repo (not CI-gated).

```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l <target> \
  -e "deployment=<mode>"
```

> **New inventory directory?** Copy a `group_vars/basic_hosts.yml` into it (the
> WinRM connection vars). `group_vars/` loads next to the inventory FILE, not from
> parent dirs. Without it every host falls back to SSH and fails immediately with
> `Using a SSH password instead of a key is not possible ... sshpass`. That is NOT
> a vault/key error; the connection vars just weren't loaded. See the Guide.

### Interactive monitored run (side-log pattern)
Use this when someone needs to watch a long run
live AND keep a colorized log to review afterward. Validated on the solo test
host June 19 2026.

```bash
ANSIBLE_FORCE_COLOR=1 ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l <target> \
  -e "deployment=<mode>" \
  -e '{"targetSoftware":[],"removeSoftware":[],"targetRuntimes":["powershell_core"]}' \
  -e "choco_deploy_reboot=never" \
  -f 40 \
  2>&1 | tee /opt/ansible/LOGS/chocoDeploy/<runlabel>.log
```

Why each piece is there:
- `ANSIBLE_FORCE_COLOR=1` -- Ansible auto-disables ANSI color when stdout is a
  pipe (which `tee` is). This forces color so BOTH the live terminal and the
  saved log keep the green `ok` / yellow `changed` / red `failed` / cyan
  `skipped` highlighting. Without it the run is monochrome the moment you pipe.
- `2>&1` -- fold stderr into stdout so warnings/errors are captured in the same
  stream and land in the log in-order, not just on the console.
- `| tee /opt/ansible/LOGS/chocoDeploy/<runlabel>.log` -- streams to the visible terminal in real time
  (operator requirement: never hide progress behind `| tail`) AND writes the
  full transcript to a file at the same time.
- The file is the "side log": open a SECOND terminal and follow it live without
  touching the run terminal (never type into the terminal running a live fleet
  play -- it can interrupt the run):
  ```bash
  tail -f /opt/ansible/LOGS/chocoDeploy/<runlabel>.log                  # follow raw
  tail -f /opt/ansible/LOGS/chocoDeploy/<runlabel>.log | less -R        # render forced color
  # filter to just the interesting lines:
  tail -f /opt/ansible/LOGS/chocoDeploy/<runlabel>.log \
    | grep --line-buffered -E 'PLAY RECAP|changed:|failed:|fatal:|Removed|Upgraded|Installed'
  ```
- The saved log contains raw ANSI codes. `cat`/`less -R` render them; a plain
  editor shows `^[[0;32m` junk. Strip color out of the saved log when needed:
  ```bash
  sed -r 's/\x1B\[[0-9;]*[mK]//g' /opt/ansible/LOGS/chocoDeploy/<runlabel>.log > /opt/ansible/LOGS/chocoDeploy/<runlabel>.clean.log
  ```

### Running with an assistant (two-terminal protocol)

Why: fleet runs are long; the operator watches live and interrupts with
Ctrl-C. The run streams to a terminal the operator can see; the assistant reads
progress without disturbing that stream.

#### Terminal 1, the visible run

The playbook runs in a terminal the operator can see, using the side-log tee
pattern. If the assistant's tooling can open a persistent visible terminal
(`run_in_terminal` async + `send_to_terminal`), it launches the run there and
reuses that one terminal for follow-ups; otherwise the assistant hands the
operator the exact command and the operator starts it in their own terminal.

```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_conversion" \
  2>&1 | tee /opt/ansible/LOGS/run-$(date -u +%Y%m%dT%H%M%SZ).log
```

#### Terminal 2, the assistant's read path

Read the side log only; never attach to or poll terminal 1. For long runs, follow
it with `watch_run.py` in a background session. It reports UNREACHABLE and FAILED
hosts as they happen (task and error, first problem per host), counts ignored
failures separately, prints progress every `--interval` seconds, flags a stall
after `--stall` seconds of silence, and summarizes PLAY RECAP before exiting:

```bash
python3.12 playbooks/tools/watch_run.py <logfile> --interval 60 --stall 300
```

To let the operator see the same view, tee it next to the run log and follow that
file in a second pane (`tail -f <logfile>.watch`):

```bash
python3.12 playbooks/tools/watch_run.py <logfile> | tee <logfile>.watch
```

Quick one-off checks against the side log:

```bash
grep -nE "fatal|FAILED|UNREACHABLE|rc=[1-9]" <logfile> | tail -20
tail -30 <logfile>
python3.12 playbooks/tools/watch_run.py <logfile> --once   # summary of a finished or partial log
```

Hard rules:
- Never pipe the run's own output into anything truncating: no `| tail`,
  `| head`, or `>/dev/null`. `tee` is the only acceptable pipe.
- Use one shared terminal, reused; do not spawn a new terminal per command
  mid-run.
- Every command must be safe to Ctrl-C mid-run.
- Do not summarize from the visible terminal; read the side log.
- Report findings as they appear, for example
  `fleet-host-06 went UNREACHABLE at task X`, not only at the end.

After the run, parse the per-host JSON reports under
`/opt/ansible/LOGS/chocoDeploy` rather than scraping console text. Use
`fleet_summary.py`.

Interactive steps such as passwords and SSH logins are typed by the operator in
their own terminal; the assistant never asks for a secret in chat.

#### Common runs

## Standard run (substitute mode: choco_conversion, choco_update, choco_baseline, choco_selective, report_only)
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_conversion"
```

## Prep only - bootstrap Chocolatey without alignment
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -e "deployment=choco_update" \
  --tags choco_init
```

## Report only - rebuild the HTML report from existing JSONs (no software changes)
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l WIN11-CLIENT-01 \
  -e "deployment=report_only"
```

## Ad-hoc probe - query a target directly (e.g. confirm choco package versions)
Ad-hoc `ansible` does NOT auto-load `vault/`, so add `-e @vault/corp-ans-secret.yml`
or `ansible_user`/`ansible_password` will resolve to undefined.
```bash
ansible -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -e @vault/corp-ans-secret.yml \
  test-host-01.corp.example.com \
  -m ansible.windows.win_shell \
  -a "choco search python313 --exact --all-versions --limit-output | Select-Object -First 10"
```

#### Targeting

## Specific apps (aliases accepted: 7zip, teams, vscode, putty, etc.)
```bash
-e '{"targetSoftware":["git","7zip","vim"]}'
```

## Azure CLI (opt-in / explicit-target only; aliases: az, azcli)
Azure CLI is `requires_explicit_target` -- it is NOT part of the default fleet
catalog and is only installed when named explicitly. The community `azure-cli`
package pulls the official MSI from `azcliprod.blob.core.windows.net`; the
mirror copy bundles that official Microsoft MSI. Installing does not require
SSO/`az login` -- auth is a runtime action, so it installs fine on lab hosts
with no Azure connectivity.
```bash
# Preferred: choco_selective installs-if-missing AND updates existing/manual
# installs across already-deployed nodes, in one pass, no reboot:
-e "deployment=choco_selective" \
-e '{"targetSoftware":["azure-cli"],"removeSoftware":[],"targetRuntimes":[]}'
```

## App with version override
```bash
-e '{"targetSoftware":["git",{"key":"teams","min_version":"1.0.2508703"}]}'
```

## Removal policy (catalog entries get alias + vendor detection; ad-hoc ids removed by exact choco name)
```bash
-e '{"removeSoftware":["notepad++"]}'
```

## Ad-hoc removal of any choco package
```bash
-e '{"removeSoftware":["notepad++","some-unwanted-package"]}'
```

## Runtimes (off by default)
```bash
-e '{"targetRuntimes":["powershell_core","dotnet_runtime","dotnet_framework"]}'
```
Valid runtime ids: `python`, `powershell_core`, `dotnet_runtime`, `dotnet_framework`.

## Runtimes ONLY (skip the default app catalog)
```bash
-e '{"targetSoftware":[],"removeSoftware":[],"targetRuntimes":["python"]}'
```

## PowerShell Core (single-track)
**Fleet default (June 2026): `floor_required: true`.** Every `targetRuntimes:["powershell_core"]` run
brings the host to >= 7.6.x in any mode -- hosts with no pwsh get one installed; older versions are
upgraded in place. Known WinRM-disconnect-during-install is handled by the role's retry+verify path.
The floor moves as candidates are promoted; `acceptable_versions.runtimes.powershell_core.min_version`
in [defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml) is authoritative.
```bash
# Standard run -- current floor enforced.
-e '{"targetRuntimes":["powershell_core"]}'

# AUDIT FIRST on an inventory that has not been touched.
-e '{"targetRuntimes":["powershell_core"]}' -e "pwsh_audit_only=true"

# Opt OUT of floor enforcement for a single run (rare; nothing happens unless
# choco already owns pwsh and is below floor).
-e '{"targetRuntimes":[{"key":"powershell_core","floor_required":false}]}'

# Per-host pin to a specific version (rare).
-e '{"targetRuntimes":[{"key":"powershell_core","min_version":"7.6.1"}]}'
```

## .NET specific tracks (modern .NET 8/9/10)
```bash
-e '{"targetRuntimes":[{"key":"dotnet_runtime","tracks":["8.0","10.0"]}]}'
```

## .NET single track override
```bash
-e '{"targetRuntimes":[{"key":"dotnet_runtime","track":"8.0","min_version":"8.0.28"}]}'
```

## .NET vendor cleanup (convert vendor Runtime/AspNet/WindowsDesktop to choco)
```bash
-e '{"targetRuntimes":["dotnet_runtime"],"dotnet_cleanup_vendor":true}'

# Audit only - preview without changes.
-e '{"targetRuntimes":["dotnet_runtime"],"dotnet_cleanup_vendor":true,"dotnet_audit_only":true}'
```

### Test-pin workflow (validate a candidate version before raising the fleet floor)
New or fast-moving package versions are staged as a tracked **test pin**
(`choco_test_pins` in `playbooks/roles/chocoDeploy/defaults/main.yml`) instead
of going straight to the production floor in `acceptable_versions`. The pin is
inert data: nothing reads it during a normal run. You validate a candidate by
passing its version explicitly with `-e` against a TEST inventory.

```bash
# 1. Stage the pin. Add/refresh the choco_test_pins entry with candidate_version,
#    rollback_version, current_floor, status: testing, and test_inventory.

# 2. Run the candidate against a TEST inventory only. Never a Deployment inventory.
#    Pass the candidate version inline -- this is what makes the pin take effect.
#    Runtime candidate (channel-based):
ansible-playbook playbooks/chocoDeploy.yml \
  -i inventory/TEST/inv-TEST-duo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_conversion" \
  -e '{"targetRuntimes":[{"key":"dotnet_runtime","channels":{"8.0":{"min_version":"8.0.30"}}}]}' \
  -e "choco_deploy_reboot=never"

#    Application candidate:
  -e '{"targetSoftware":[{"key":"vscode.install","min_version":"1.133.0"}],"removeSoftware":[],"targetRuntimes":[]}'
```

- **Passes?** Promote: raise the matching `min_version` in `acceptable_versions`
  to the candidate version and delete the `choco_test_pins` entry (git history
  keeps the record; put the validated hosts in the commit message). Promotion is
  a deliberate change; validating does not move the floor on its own.
- **Fails?** Set `status: rolled_back` (or delete the entry) and leave
  `acceptable_versions` alone, so the fleet floor never moved. chocoDeploy never
  downgrades: re-running with `rollback_version` reports NoChange on a host that
  already took the candidate, and the test host keeps the candidate.
- Pick the candidate from `choco outdated` on the test host. An upgrade uses
  `state: latest`, so it lands on the feed's newest version, not exactly on the
  candidate; only a fresh install pins to the exact version.
- Never target a fleet/Deployment inventory with a candidate version. Test
  inventories only (`inv-TEST-solo.yml`, `inv-TEST-duo.yml`, `inv-TEST-temp.yml`).
- `inv-TEST-solo.yml` (`test-host-01`) is the permanent authorized test host.
  `inv-TEST-duo.yml` adds a rotating second host of the same hardware class for a
  second confirmation. Confirm any other host is actually cleared before running
  against it.
- Optional: for a multi-package candidate batch you can keep a dated overlay file
  of the same `-e` variables and load it with `-e @<file>`. Those live under
  `playbooks/roles/chocoDeploy/files/test-pins/` and are gitignored local scratch,
  so do not expect them to exist in a fresh clone.

### GOTCHA: conversion skips registry-less below-floor runtimes (validated 2026-07-20)
Routine fleet remediation is `choco_conversion`. It aligns a .NET track when the
track is DETECTED -- present in the Chocolatey inventory OR found by the vendor
scan, which reads the **uninstall registry**. This covers the normal case: a
vendor .NET install with a Programs-and-Features entry (what the compliance
scanner reports) is detected and remediated by conversion.

EDGE CASE: a shared runtime that exists on disk (shows in `dotnet --list-runtimes`)
but has **no uninstall-registry entry** is invisible -- conversion skips it and
still reports `errors=0`, leaving it below floor. `dotnet_cleanup_vendor:true`
does NOT help (its discovery is registry-based too). Seen once on the solo host
with a registry-less AspNetCore 9.0.14 leftover.

If you actually hit a registry-less below-floor runtime on specific hosts, handle
those hosts as a SCOPED exception (limit the inventory to just them); do NOT
baseline the whole fleet. Forcing an undetected track is the one thing only
`choco_baseline` does (it aligns every configured channel unconditionally, which
also installs channels a host may not have) -- so if used, scope it tightly:
```bash
# Scoped remediation of a registry-less track on NAMED hosts only.
-l 'the-specific-host*' \
-e "deployment=choco_baseline" \
-e '{"targetSoftware":[],"removeSoftware":[],"targetRuntimes":["dotnet_runtime"]}'
```

## .NET sweep (retire EOL / out-of-policy tracks)
**DEFAULT = OFF (June 16 2026).** The catalog ships `min_supported_track: ""` so routine
runs NEVER remove .NET; detected 8.0/9.0/10.0 tracks upgrade in-channel and EOL .NET 6/7
are left in place. Retiring EOL .NET is a deliberate, opt-in action per run (below), and
should be preceded by a per-host dependency scan (a net6 app pinned to `net6.0` will fail
to start if its runtime is removed). A June 2026 fleet probe found .NET 6 on 36/123 hosts.
```bash
# OPT IN: retire any .NET below this track for this run (e.g. 8.0 catches .NET 6 and 7).
-e '{"targetRuntimes":[{"key":"dotnet_runtime","min_supported_track":"8.0"}]}'

# Exclusive mode - remove tracks not in configured channels.
-e '{"targetRuntimes":[{"key":"dotnet_runtime","exclusive":true}],"dotnet_audit_only":true}'

# Mixed-fleet onboarding - installs floor where missing, sweeps below-floor.
-e "deployment=choco_update" \
-e '{"targetRuntimes":[{"key":"dotnet_runtime","floor_required":true}]}'
```
To make the sweep the DEFAULT again fleet-wide, set `min_supported_track` back to a track
(e.g. `"8.0"`) in `defaults/main.yml` under `acceptable_versions.runtimes.dotnet_runtime`.

## .NET Framework 4.x (in-box; upgraded only, reboot usually required)
```bash
-e '{"targetRuntimes":["dotnet_framework"]}'
```

## Python (side-by-side tracks)
**Fleet default (June 2026): `floor_required: true`.** Every `targetRuntimes:["python"]` run
enforces the 3.12 floor: hosts on 3.10/3.11 have those removed and 3.12 installed; hosts
on 3.12/3.13/3.14 are upgraded in-channel; hosts with no python get 3.12 installed.
The sweep runs even in `choco_update` mode.
**Vendor-installed Python** (8-10 component MSIs per track from python.org) is removed
by the same sweep automatically -- pythonSweep iterates `msiexec /x` on each component
with a registry-key fallback for 1603s. No separate playbook needed.
```bash
# Standard run - aligns all configured tracks AND enforces the 3.12 floor.
-e '{"targetRuntimes":["python"]}'

# AUDIT FIRST - preview floor enforcement without changes (recommended before
# the first run on any inventory that has not been touched).
-e '{"targetRuntimes":["python"]}' -e "python_audit_only=true"

# Opt OUT of floor enforcement for a single run (rare; below-floor installs
# are left alone, no new install on hosts with no python).
-e '{"targetRuntimes":[{"key":"python","floor_required":false}]}'

# Pin specific tracks.
-e '{"targetRuntimes":[{"key":"python","tracks":["3.13"]}]}'
-e '{"targetRuntimes":[{"key":"python","tracks":["3.12","3.13"]}]}'

# Single-track override of package + version (rare).
-e '{"targetRuntimes":[{"key":"python","track":"3.13","min_version":"3.13.13","package_name":"python313"}]}'

# Exclusive mode - also remove tracks not in configured channels (3.15+ etc.).
-e '{"targetRuntimes":[{"key":"python","exclusive":true}],"python_audit_only":true}'

# Override the floor track (e.g. raise to 3.13 to retire 3.12 fleetwide).
-e '{"targetRuntimes":[{"key":"python","min_supported_track":"3.13"}]}'

# Vendor cleanup / alias cleanup.
-e '{"targetRuntimes":["python"],"python_cleanup_vendor":true}'
-e '{"targetRuntimes":["python"],"python_cleanup_aliases":true}'
```

#### Combined examples

## Full conversion with all runtimes and removal policy
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_conversion" \
  -e '{"targetRuntimes":["powershell_core","python","dotnet_runtime","dotnet_framework"]}' \
  -e '{"removeSoftware":["notepad++"]}'
```

## Targeted apps + specific .NET tracks
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -l 'test-host-01*' \
  -e "deployment=choco_conversion" \
  -e '{"targetSoftware":["git","7zip","vscode"]}' \
  -e '{"targetRuntimes":[{"key":"dotnet_runtime","tracks":["8.0","10.0"]}]}'
```

## Fleet run with higher parallelism
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -e "deployment=choco_update" \
  -f 50
```

#### Reboot policy
- Default: `never` - no reboot after run
- `always` - reboot every host after a successful run
- `if_needed` - reboot only when a pending reboot was detected
```bash
-e "choco_deploy_reboot=if_needed"
```

#### Fleet summary report

## Summarize the last 24 hours of runs (recommended)
```bash
python3.12 playbooks/roles/chocoDeploy/files/fleet_summary.py \
  --last-hours 24 \
  --short-names \
  --archive
```

## Summarize a specific time window
```bash
python3.12 playbooks/roles/chocoDeploy/files/fleet_summary.py \
  --since 20260318T010000Z \
  --until 20260318T070000Z \
  --short-names \
  --archive
```

## Pull the fleet report to a local workstation
```powershell
scp <you>@ansible-ctl-01.example.com:/opt/ansible/LOGS/chocoDeploy/reports/* C:\tools\chocolog\
```
`--archive` moves the consumed per-host JSONs into
`<json-dir>/archive/<UTC>_chocoDeploy_run.zip` (they leave the JSON directory, so a
later summary of the same window will not find them) and deletes archive zips older
than `--retain-days` (default 90). Leave it off when the JSONs are still needed as
evidence.
`--today` also available but uses UTC calendar day -- prefer `--last-hours 24` for daily summaries.

#### Force-replace stuck vendor installs
When a vendor uninstaller leaves the registry entry behind, use the per-app
force flag to nuke the orphan and reinstall clean:

```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i /opt/ansible/incoming/<campaign-id>/inv-greenshot.yml \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e '{"deployment":"choco_conversion","targetSoftware":["greenshot"],"removeSoftware":["notepadplusplus"],"targetRuntimes":[]}' \
  -e "greenshot_force_replace_orphan=true"
```

Flag pattern: `<app_id_normalized>_force_replace_orphan=true` (dots/dashes become underscores).
Currently supported: `docker_desktop`, `greenshot`, `pycharm`, `winscp_install`.

#### Notes
- Teams is explicit-only - include it in `targetSoftware` to manage it
- `.NET` auto-detects present tracks when no `track`/`tracks` specified
- Per-run JSON reports written to `C:\tools\chocolog` on targets and `/opt/ansible/LOGS/chocoDeploy/` on the control node
- A consolidated daily HTML report is written to `C:\tools\chocolog\<date>_chocoDeploy.html` on each target, combining all runs from that UTC date
- The HTML report includes an embedded JSON block for downstream Ansible parsing
- Use `deployment=report_only` to rebuild the HTML report from existing JSONs without changing software
- Reboot is logged to the Windows Application event log (source: `chocoDeploy`, EventId: 1000) before execution
- Old per-host logs on targets are compressed into `C:\tools\chocolog\archive\` after 90 days (configurable via `choco_deploy_local_report_retain_days`)
- Approved versions in [defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml) under `acceptable_versions`
- Mirror `.nupkg`s on `C:\tools\chocoRepo\` are produced by [`chocoBuild`](../build/chocoBuild_QuickRef.md). Bump a version here AND in [chocoBuild/files/internalize-spec.yml](../../playbooks/roles/chocoBuild/files/internalize-spec.yml) together.
- See [chocoDeploy_Guide.md](chocoDeploy_Guide.md) for full architecture and policy details
