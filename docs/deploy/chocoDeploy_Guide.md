########## chocoDeploy Role Guide
# For a shorter operator run guide, see [chocoDeploy_QuickRef.md](chocoDeploy_QuickRef.md).

#### Purpose
# `chocoDeploy` aligns approved Windows software through Chocolatey and also aligns `Python`, `.NET`, and `PowerShell` runtime policy.
# This guide is aimed at an administrator who needs to know what the role does, how to run it, and where to change policy.

#### What the role manages
- managed applications through Chocolatey
- runtime alignment for `Python`, `.NET`, and `PowerShell Core`
- trusted Chocolatey source configuration
- per-host reporting (JSON + consolidated HTML)

### App targeting model
# By default, the managed app catalog is the target set except for apps marked explicit-only.
# If `targetSoftware` is provided, only those managed app ids are targeted for app alignment.
# Friendly aliases are accepted and resolved to the canonical Chocolatey package used by the role.
# Each target may optionally override the minimum approved version for that run or inventory grouping.

### Runtime targeting model
# Runtime alignment is opt-in.
# If `targetRuntimes` is empty, no runtime alignment is attempted.
# If `targetRuntimes` is provided, only those runtime ids are targeted.

### Managed application set
# Current managed apps include `Docker Desktop`, `7-Zip`, `Git`, `Greenshot`, `Microsoft Teams` bootstrapper, `PyCharm`, `PuTTY`, `Vim`, `VS Code`, and `WinSCP`.

### Key files
- playbook entry: [playbooks/chocoDeploy.yml](../../playbooks/chocoDeploy.yml)
- role defaults and policy: [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml)
- role workflow: [playbooks/roles/chocoDeploy/tasks/main.yml](../../playbooks/roles/chocoDeploy/tasks/main.yml)
- app task files: [playbooks/roles/chocoDeploy/tasks/apps](../../playbooks/roles/chocoDeploy/tasks/apps)
- ops engine: [playbooks/roles/chocoDeploy/tasks/ops](../../playbooks/roles/chocoDeploy/tasks/ops)
- report engine: [playbooks/roles/chocoDeploy/tasks/ops/report.yml](../../playbooks/roles/chocoDeploy/tasks/ops/report.yml)
- HTML report template: [playbooks/roles/chocoDeploy/templates/report.html.j2](../../playbooks/roles/chocoDeploy/templates/report.html.j2)
- runtime alignment: [playbooks/roles/chocoDeploy/tasks/infra](../../playbooks/roles/chocoDeploy/tasks/infra)
- `.NET` track resolver: [playbooks/roles/chocoDeploy/tasks/infra/dotnetResolve.yml](../../playbooks/roles/chocoDeploy/tasks/infra/dotnetResolve.yml)
- fleet summary script: [playbooks/roles/chocoDeploy/files/fleet_summary.py](../../playbooks/roles/chocoDeploy/files/fleet_summary.py)
- web builder (local-only command assembler): [webui/](../../webui/), [webui/README.md](../../webui/README.md). Launch with `./webui/run.sh` and open <http://127.0.0.1:5050/>. The builder assembles `ansible-playbook` commands lego-brick style and lets you copy them into a terminal; it does not run ansible itself.

#### Before you run
- use the normal Ansible control node or container for your team
- confirm admin rights on the Windows targets
- confirm WinRM connectivity
- choose the correct inventory
- make sure any needed vault material is available
- on the Ansible node, the stored key vault / vault material should be available so the role can use the `svc-ansible` account for local administrator access on target systems
- if you use a vault password file on the Ansible node, a common layout is `vault/.vault_key.txt` at the repo root rather than under `inventory/`

#### Vault loading: playbook vs ad-hoc
The `vault/` directory is intentionally **outside** Ansible's auto-loaded paths (`group_vars/`, `host_vars/`). This keeps secrets centralized, auditable, and portable across control nodes (no symlinks or host-specific layout assumptions).

- **Playbooks** (`ansible-playbook ...`) load vault material via an explicit `vars_files:` entry in the play. `chocoDeploy.yml` already does this:
  ```yaml
  vars_files:
    - "{{ playbook_dir }}/../vault/corp-ans-secret.yml"
  ```
  No extra flags needed beyond `--vault-password-file`.

- **Ad-hoc commands** (`ansible ... -m ...`) do NOT auto-load `vault/` files. You must add `-e @vault/<file>.yml` to inject them, e.g. when probing a target directly:
  ```bash
  ansible -i inventory/TEST/inv-TEST-solo.yml \
    --vault-password-file=vault/.vault_key.txt \
    -e @vault/corp-ans-secret.yml \
    test-host-01.corp.example.com \
    -m ansible.windows.win_shell \
    -a "choco list --local-only --limit-output python313"
  ```
  Without `-e @vault/corp-ans-secret.yml` you will see `'sys_adm' is undefined` because `ansible_user` resolves through the vault.

#### Connection vars: every inventory directory needs its own group_vars
Ansible resolves `group_vars/` relative to the **inventory file's own directory**, not parent directories. The WinRM connection settings for the fleet live in a per-directory `group_vars/basic_hosts.yml`:
```yaml
ansible_user: "{{ sys_adm }}"
ansible_password: "{{ sys_adm_pass }}"
ansible_connection: winrm
ansible_winrm_scheme: http
ansible_port: 5985
ansible_winrm_transport: ntlm
```
Every inventory directory carries its own copy: `inventory/TEST/group_vars/`, `inventory/Internalize/group_vars/`, and each external campaign bundle's `group_vars/`. When you create a NEW inventory directory or campaign bundle, copy this file in from a sibling dir. group_vars resolves relative to the inventory FILE's directory, not a parent.

**Symptom if it is missing:** with no `ansible_connection: winrm` loaded, Ansible defaults to SSH and every host fails on the very first task with:
```
Using a SSH password instead of a key is not possible because Host Key checking
is enabled and sshpass does not support this.
```
This is a **connection-vars** problem, not a vault/key problem. The `--vault-password-file` call is correct. The per-directory `group_vars/basic_hosts.yml` simply was not present next to the inventory, so `ansible_connection` never got set. Fix: create `group_vars/basic_hosts.yml` in the new inventory's directory and re-run.

#### Basic run pattern
## Run from the repo root
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory-file> \
  --vault-password-file=vault/.vault_key.txt \
  -l <host-or-group> \
  -e "deployment=<mode>"
```

# The command chooses targets and mode. Approved versions still come from `acceptable_versions` in [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml).
# The `-e "deployment=<mode>"` flag is the normal way to switch between `choco_conversion`, `choco_update`, `choco_baseline`, `choco_selective`, and `report_only`.

### Example inventories
- [inventory/TEST/inv-TEST-solo.yml](../../inventory/TEST/inv-TEST-solo.yml)

#### Common runs
## Routine conversion run
# Detect existing managed software, convert non-Chocolatey installs where needed, and avoid adding missing apps.
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_conversion"
```

## Target only selected apps
# Use `targetSoftware` when you only want a subset of the managed app catalog.
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_baseline" \
  -e '{"targetSoftware":["git","7zip",{"key":"teams","min_version":"1.0.2508703"}]}'
```

## Full baseline run
# Install the full approved catalog.
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_baseline"
```

## Fast Chocolatey-only run
# Only align software that Chocolatey already reports.
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_update"
```

## Single system run
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l WIN11-CLIENT-01 \
  -e "deployment=choco_conversion"
```

## Prep only - bootstrap Chocolatey without running alignment
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -e "deployment=choco_update" \
  --tags choco_init
```

#### Deployment modes
### `choco_conversion`
# Convert detected target software to approved Chocolatey ownership without adding net-new applications.
- checks Chocolatey and the trusted source
- gathers Chocolatey inventory
- gathers installed-program inventory from uninstall registry locations
- targets only managed apps already detected on the host
- removes vendor/MSI installs when matched
- installs or upgrades the approved Chocolatey package
- aligns runtime policy

# Expected result: software already on the host is normalized to approved Chocolatey management.
# Targeted runtimes are only aligned when they are already present on the host.

### `choco_update`
# Fastest pass. Only Chocolatey-visible managed apps are checked.
- checks Chocolatey and the trusted source
- gathers Chocolatey inventory
- upgrades out-of-alignment Chocolatey-visible apps
- aligns runtime policy

# Expected result: quick recurring compliance pass with no uninstall-registry discovery.
# Targeted runtimes are only aligned when Chocolatey already owns them.

### `choco_baseline`
# Enforce the full approved catalog.
- runs every managed app task
- installs missing approved software
- converts non-Chocolatey installs where found
- upgrades existing managed software
- aligns runtime policy

# Expected result: a host is pushed to the full approved application baseline.
# Targeted runtimes are installed or aligned when they are explicitly requested.

### `choco_selective`
# Install and/or align ONLY the explicitly-named target apps on existing nodes.
# The safe answer to "add or update one specific app across already-deployed
# hosts" without choco_baseline's full-catalog risk.
- REQUIRES a non-empty `targetSoftware` list; `null`/`[]` is a hard error
  (asserted in tasks/main.yml). There is NO full-catalog fallback, so it can
  never accidentally push the whole catalog the way a filter-less baseline can.
- processes exactly the named apps and nothing else
- per named app, install-one decides the action from on-host state:
  - app absent (clean host)      -> installs net-new
  - vendor / manual install      -> converts to Chocolatey ownership
  - Chocolatey-owned install     -> upgrades to the approved version
- runtimes / removals are only touched if separately requested

# Expected result: the named apps end up installed and choco-owned at the
# approved version on every targeted node, in a single pass, whether they were
# missing, vendor-installed, or already choco-managed. This is the approved
# pattern for mid-cycle additions (e.g. azure-cli) instead of a targeted
# choco_baseline. Validated on test-host-01 (9/9 battery July 2026): guards reject
# null/[]/unknown; net-new install; idempotent re-run; alias resolution;
# no collateral to other catalog apps; vendor->convert.
#
# Example:
#   -e "deployment=choco_selective" \
#   -e '{"targetSoftware":["azure-cli"],"removeSoftware":[],"targetRuntimes":[]}'

### `report_only`
# Rebuild the consolidated HTML report from existing per-run JSON files without modifying any software.
- skips all software alignment, removal, and runtime tasks
- reads per-run JSON files from `C:\tools\chocolog` for the current UTC date
- re-renders the consolidated daily HTML report
- does not write new JSON files or control-node copies

# Expected result: the daily HTML report is regenerated from whatever runs have already been recorded.
# Use this to rebuild a report after deleting the HTML, or to re-render after a template update.

#### Reporting
### Report architecture
# Each deployment run produces a per-run JSON file on both the target host and the control node.
# The JSON contains full structured data: events, errors, diagnostics, and the ansible command used.
# At the end of each run, all JSON files for the current UTC date are read from the target and consolidated into a single HTML report.

### Report files on target hosts (`C:\tools\chocolog`)
- `<timestamp>_chocoDeploy.json` - per-run structured data (one per run, used by nxlog for ingestion)
- `<date>_chocoDeploy.html` - consolidated daily HTML report (re-rendered after each run)
- `<timestamp>_chocoDeploy_errors.txt` - detailed error log (only created when error count exceeds 3)

### Report files on control node (`/opt/ansible/LOGS/chocoDeploy/`)
- `<timestamp>_<hostname>_chocoDeploy.json` - per-run structured data copy

### Consolidated HTML report
# The HTML report uses a dark theme and presents all runs from a single day in one flat page.
# Each section (Converted, Installed, Upgraded, Compliant, Removed, Errors) has a `Session` column showing which pass (1st, 2nd, 3rd, etc.) produced each row.
# A `Session(s)` table lists each pass with its timestamp and deployment mode.
# A `Diagnostics` table shows targeting details per pass.
# An `Ansible Commands` section shows the exact command used for each pass.
# An embedded `<script type="application/json" id="chocoDeploy-data">` block contains the full structured JSON for downstream Ansible consumption.

### Multi-run consolidation
# During a maintenance window with multiple runs (e.g. removal pass, upgrade pass, new install pass), each run appends a new JSON file.
# The HTML is re-rendered after each run to include all passes from that day.
# This keeps individual playbook runs fast while producing a single consolidated report for the window.

### Report retention
# Files older than `choco_deploy_local_report_retain_days` (default 90) are compressed into `C:\tools\chocolog\archive\` and the originals removed.
# On the control node, `fleet_summary.py --archive` performs equivalent cleanup.

#### Target software input
### Default behavior
# If `targetSoftware` is unset (null), the role targets the default managed app set in `choco_managed_apps`.
# Apps marked explicit-only are excluded from that default set.

### Skip apps entirely
# If `targetSoftware` is set to an empty list (`[]`), the role skips the app alignment pass completely.
# Use this for runtime-only runs (paired with `targetRuntimes`).

### Filtered behavior
# If `targetSoftware` is set to a non-empty list, the role filters app alignment to only those managed app ids.
# The input may use canonical ids such as `7zip.install` or operator-friendly aliases such as `7zip`.
# This is appropriate in inventory group vars when a system grouping should only receive a defined subset.

## Example
```yaml
targetSoftware:
  - git
  - 7zip
  - key: teams
    min_version: "1.0.2508703"
```

# Unknown app ids fail early so operators get a clear error before any install work begins.
# The role currently accepts aliases such as `7zip`, `putty`, `winscp`, and `teams` and resolves them to the canonical package ids used internally.
# `teams` is explicit-only, so it is skipped by the default workload unless you request it in `targetSoftware`.

#### Remove software input
### Default behavior
# If `removeSoftware` is unset (null), the full removal catalog is processed.

### Skip removal entirely
# If `removeSoftware` is set to an empty list (`[]`), the removal pass is skipped completely.

### Enabled behavior
# If `removeSoftware` is set to a non-empty list, only those entries are removed whenever discovered.
# Chocolatey-managed installs are removed by package id, and vendor installs are removed from uninstall-registry matches.

### Catalog entries
# Entries that match the removal catalog (e.g. `notepad++`) get full alias resolution and registry-pattern-based vendor detection.

### Ad-hoc entries
# Any Chocolatey package id can be passed even if it is not in the catalog. Ad-hoc ids are removed by exact Chocolatey package name without vendor registry scanning.
# This is useful for one-off cleanups or reversing a mistaken deployment.

## Example
```yaml
removeSoftware:
  - notepad++
```

## Example ad-hoc removal
```yaml
removeSoftware:
  - notepad++
  - some-unwanted-package
  - another-mistake
```

### Removal exclusion
# Apps targeted for removal are automatically excluded from conversion, update, and baseline processing.
# The role will not waste time aligning software it is about to uninstall.

# The initial blacklist catalog is intentionally small and currently includes `notepad++` aliases for Notepad++ removal.

#### Campaigns and one-time actions
### Shared package catalog
The common package contract lives in [playbooks/catalogs/chocolatey_packages.yml](../../playbooks/catalogs/chocolatey_packages.yml).
It records package identity, approved deployment version, acquisition method, source policy, mirror versions, and wrapper verification metadata.
`chocoBuild` and `chocoDeploy` can consume the same package identity without making either role depend on the other role's defaults.
For candidate and promoted versions, `version_timeline` records public feed dates, repository staging, mirror ingestion, TEST installation, validation host, and production promotion.
Use those dates when explaining a monthly compliance result or an apparent gap between a public release and fleet remediation.

Role-specific behavior remains in the role catalogs. `chocoDeploy` continues to own aliases, detection, conversion, removal, and pre-remove scripts.
`chocoBuild` continues to own internalization and wrapper execution.

### Campaign structure
Use [campaigns/template.yml](../../campaigns/template.yml) as the reusable manifest template for a maintenance window or multi-run change.
Copy the completed manifest, raw target lists, generated inventories,
protected-OU export, and inventory-check evidence to the external operational workspace under
`/opt/ansible/incoming/<campaign-id>/`. That path is
`$CHOCO_FLEET_DATA_ROOT/incoming` with the production default of
`/opt/ansible/incoming`.
Do not add real fleet hostnames or one-time campaign manifests to this repository.
A campaign contains ordered phases. Each phase contains one or more runs. A run is one playbook invocation against one inventory or limit.
This makes a patch night, canary, wave, remediation pass, and final report distinguishable without treating the entire night as one run.

### Campaigns versus dated Deployment folders
The campaign is the source of truth. The external campaign directory is the physical bundle:
```text
/opt/ansible/incoming/<campaign-id>/
  campaign-<id>.yml       # campaign, phase, wave, and run order
  source.csv              # optional compliance or survey input
  ad-protected-objects.json
  <campaign-id>-<name>-check.json
  <campaign-id>-<name>-excluded.txt
  inv-<run>.yml           # inventory for one run
  inv-<run>-ready.yml     # ready subset from WinRM 5985 probe
  group_vars/             # connection vars for those inventories
  reports/                # optional campaign-specific analysis
```

The older `inventory/Deployment/<date>/` folders combined several of these artifacts in a dated
repository directory. That was how campaigns were run before this model existed; it is not a
pattern to preserve. Those folders were moved to the external campaign store on 2026-09-21 and
are no longer tracked here.
The repository now tracks only standing inventories (`inventory/TEST/`, `inventory/Internalize/`);
`.gitignore` allowlists those two and ignores everything else under `inventory/`.
Create the external campaign directory instead, and let each campaign run reference its own inventory file.

The mapping is direct:
- campaign = the overall maintenance window
- phase = a logical stage such as readiness, canary, wave, remediation, or report
- run = one actual `ansible-playbook` invocation
- inventory = the target set for that run
- report = the evidence produced by that run

Build generated inventories from received CSV files before rendering a campaign:
```bash
python3.12 playbooks/tools/csv_to_inventory.py /opt/ansible/incoming/<campaign-id>/<list>.csv \
  --campaign-id <campaign-id> \
  --name all \
  --ad-export /opt/ansible/incoming/<campaign-id>/ad-protected-objects.json
```

Protected-OU hosts are excluded from generated inventories and recorded in
`<campaign-id>-<name>-excluded.txt`; the remaining hosts are written to the
all-host inventory, and hosts answering WinRM 5985 are also written to the
`-ready` inventory.

Validate and render commands without executing them:
```bash
python3.12 playbooks/tools/validate_catalog.py \
  --campaign /opt/ansible/incoming/<campaign-id>/<campaign>.yml \
  --ad-export /opt/ansible/incoming/<campaign-id>/ad-protected-objects.json

python3.12 playbooks/tools/render_campaign.py \
  /opt/ansible/incoming/<campaign-id>/<campaign>.yml \
  --ad-export /opt/ansible/incoming/<campaign-id>/ad-protected-objects.json
```

These commands warn about protected hosts already present in built inventories,
but they do not block. The campaign manifest should reference absolute inventory
paths in that same external workspace.
This keeps the repository reusable and keeps real target lists out of source control.

### Bundled versus separate actions
Bundle add and remove actions in one `choco_selective` run only when they affect the same hosts, share approval and reboot policy, and represent one safe replacement operation.
Use separate phases when removal needs its own approval, verification, remediation, or reporting, or when the old package and replacement have different target populations.

For a removal-only run, use `choco_update` with an explicit empty `targetSoftware` list:
```yaml
targetSoftware: []
removeSoftware:
  - temporary-test-package
targetRuntimes: []
```
Do not use `choco_selective` for removal-only work because it requires a non-empty `targetSoftware` list.

The package remains in the shared catalog after a one-time removal. A campaign expresses temporary intent for a target cohort; it does not retire the package or remove its source metadata.

#### Target runtime input
### Default behavior
# If `targetRuntimes` is empty, no runtime alignment runs.

### Filtered behavior
# If `targetRuntimes` is set, only those runtime ids are in scope.
# This keeps runtime work separate from the normal managed app catalog.

## Example
```yaml
targetRuntimes:
  - powershell_core
  - key: dotnet_runtime
    family: "aspnetruntime"
    track: "8.0"
    min_version: "8.0.28"
```

# Unknown runtime ids fail early before install work starts.

#### Reporting
### Per-host reports
# Each host gets a readable summary in the Ansible output, per-run JSON reports on the target host, and a per-run JSON copy on the control node.

### Report locations
- control node: `/opt/ansible/LOGS/chocoDeploy/`
- target host: `C:\tools\chocolog`

### Report fields
- `report_time`
- `system`
- `deployment`
- `inventory_source`
- `target_software`
- `remove_software`
- `target_runtimes`
- `ansible_command`
- `action`
- `software`
- `previous_version`
- `new_version`
- `source`
- `notes`

# Local target-host filenames use UTC timestamps in the form `YYYYMMDDTHHMMSSZ_chocoDeploy.json`.
# A consolidated daily HTML report is written as `YYYYMMDD_chocoDeploy.html`.

# The human-readable report places the change summary first, includes an `Errors` section, and records a reconstructed equivalent command under `ANSIBLE_COMMAND`.

# Reporting behavior is controlled by `choco_deploy_report_enabled`, `choco_deploy_report_dir`, `choco_deploy_local_report_enabled`, and `choco_deploy_local_report_dir` in [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml).

### Log retention
# The role automatically compresses per-host reports older than `choco_deploy_local_report_retain_days` (default 90) on each target host.
# Old logs are zipped into `C:\tools\chocolog\archive\YYYYMMDD_chocoDeploy_old_logs.zip` and the originals are removed.
# This runs at the end of every deployment, keeping the main log directory clean.

### Fleet summary report
# After a downtime window (potentially multiple runs across multiple sites), generate a consolidated fleet summary on the control node.
# The fleet summary script reads per-host JSONs from the control node log directory and produces a board-ready text report plus a structured JSON report.
# Results are grouped by site (derived from the inventory source path in each JSON).
# When a host has multiple runs (e.g. a retry after fixing an issue), the script applies last-run-wins dedup:
# only the latest event per software counts, and errors resolved by a later successful run are cleared.
# Retried hosts are annotated so the board report shows final outcomes, not intermediate failures.

## Fleet summary usage
```bash
# Summarize all runs from today, archive consumed JSONs into a zip
python3.12 playbooks/roles/chocoDeploy/files/fleet_summary.py \
  --today --short-names --archive

# Summarize a specific time window
python3.12 playbooks/roles/chocoDeploy/files/fleet_summary.py \
  --since 20260318T010000Z --until 20260318T070000Z \
  --short-names --archive
```

# `--archive` zips consumed per-host JSONs into `archive/YYYYMMDDTHHMMSSZ_chocoDeploy_run.zip` and removes the originals.
# `--retain-days N` (default 90) prunes archive zips older than N days.
# `--short-names` strips the domain suffix from hostnames for cleaner output.

## Pull the fleet report to a local workstation
```powershell
scp <you>@ansible-ctl-01.example.com:/opt/ansible/LOGS/chocoDeploy/reports/* C:\tools\chocolog\
```

## Fleet summary output
# The text report includes per-site sections with host counts, success rates, retry counts, and software action tables, followed by fleet-wide roll-ups, pending reboots, problematic systems, and retried systems.
# The JSON report contains the same structured data for Graylog ingestion or downstream tooling.
# The HTML report is a standalone dark-themed page (matching the per-host chocoDeploy and patchReady reports) with stat boxes, per-site software tables, per-host detail rows, and embedded JSON.

### Key files
- fleet summary script: [playbooks/roles/chocoDeploy/files/fleet_summary.py](../../playbooks/roles/chocoDeploy/files/fleet_summary.py)
- fleet summary output: `/opt/ansible/LOGS/chocoDeploy/reports/YYYYMMDDTHHMMSSZ_chocoDeploy_fleet_summary.txt`, `.json`, and `.html`

#### Conversion logic
### How app detection works
# Non-infra apps are detected from both Chocolatey inventory and Windows uninstall registry inventory.
# Detection patterns come from `registry_patterns` in [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml).

### What that means
- vendor-installed apps can be found even if Chocolatey does not list them
- those installs can be removed best-effort
- the approved Chocolatey package can then be installed or upgraded

#### Microsoft Teams
### Package model
# Teams is managed through the Chocolatey package `microsoft-teams-new-bootstrapper`.
# This is the Microsoft machine-wide bootstrapper model, and the Teams client self-updates after provisioning.

### Role behavior
- Teams is explicit-only and is skipped by the default workload
- `choco_baseline` installs it if and only if it was explicitly targeted
- `choco_conversion` converts detected Teams installs to the approved Chocolatey package only when it was explicitly targeted
- `microsoft-teams` and `microsoft-teams.install` are treated as conflicts and removed before alignment

### Version control
# The approved minimum version is controlled in [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml) under `acceptable_versions.applications.microsoft_teams_new_bootstrapper`.

#### Trusted source behavior
### Source default (public Chocolatey community)
# As of June 2026 the role defaults to the public Chocolatey community feed.
# `trusted_choco_source` ships EMPTY (name: "", url: ""), so no internal source
# is registered or probed and every package is pulled from the public feed
# (`choco_public_source_name`, default "chocolatey").
#
# The old internal mirror legacy-choco (https://nexus-legacy.example.com/repository/legacy-choco/)
# is DEPRECATED and is no longer the default.
#
# To use an internal/mirror source for a run, set it explicitly, for example:
#   -e '{"trusted_choco_source": {"name": "chocoRepo", "url": "\\\\mirror-01.infra.example.com\\chocoRepo", "priority": 1}}'
# or pin it in group_vars/host_vars. Use the FQDN for UNC mirror sources so
# Kerberos can resolve the cifs SPN across domains.
#
# The new Nexus repository (not yet approved for fleet use; see the chocoBuild
# QuickRef "Nexus repository" section) is named the same way:
#   -e '{"trusted_choco_source": {"name": "nexus", "url": "http://192.0.2.20:8081/repository/chocolatey-development/", "priority": 1}}'
- source settings: [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml)

# When an internal source IS configured, it is given highest priority so approved
# internal packages are preferred over the public feed.

### Source routing
# The role routes package installs directly to either the public source or the
# internal source by package id.
# That avoids having every client probe the internal repo for packages that are not hosted there.

## Runtime discovery behavior
# When an internal source is configured, the role probes it once at the start of
# the run for managed application package ids, and reuses that result for all hosts.
# With the empty default, this probe is skipped and everything routes to the public feed.

## To force a package to the internal repo
# Add its Chocolatey package id to `chocoInternalRepo` in [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml).

# Example:
```yaml
chocoInternalRepo:
  - git
  - microsoft-teams-new-bootstrapper
```

# This manual list is optional for managed apps. Use it when you want to force package ids to the internal repo, or if you later disable auto-discovery with `choco_auto_discover_internalized_apps: false`.

#### Building the internalized package mirror (chocoBuild)
The `.nupkg` files this role consumes are produced by a sibling role,
[`chocoBuild`](../build/). chocoBuild is the **build side** of the
package lifecycle; chocoDeploy is the **deploy side**. They cooperate
through a single source of truth: the per-package directories under
`C:\tools\chocoRepo\` on the mirror host.

You need chocoBuild when:
- A new package is being added to the approved catalog
- An existing package's version pin is being bumped
- A wrapper package is being built for a version not (yet) on the
  Chocolatey community feed (e.g. Docker Desktop 4.76 ahead of community)
- The internalize-package rewriter logic has changed and every cached
  `.nupkg` needs to be regenerated

You do NOT need chocoBuild for routine fleet alignment -- once a
`.nupkg` is on the mirror, chocoDeploy is self-sufficient.

Mirror directory layout that chocoDeploy reads:
```
C:\tools\chocoRepo\
  <package-id>\
    <package-id>.<version>.nupkg            <- bundled, ready to serve
    .internalized\<version>.done             <- chocoBuild sentinel
```

Supply-chain trust note: chocoBuild's wrapper synthesis verifies both
the cached base `.nupkg` (against a pinned SHA256) and the downloaded
vendor installer binary (against the vendor's official hash) before
producing a new `.nupkg`. All trust material is captured in version
control in chocoBuild's spec files. See
[chocoBuild_Guide.md](../build/chocoBuild_Guide.md) for the
trust model and the install-script family taxonomy, and
[chocoBuild_QuickRef.md](../build/chocoBuild_QuickRef.md) for
the operator runbook.

The catalog of packages chocoBuild produces is mirrored in chocoDeploy's
`acceptable_versions` ([defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml))
and chocoBuild's
[internalize-spec.yml](../../playbooks/roles/chocoBuild/files/internalize-spec.yml).
When a version is bumped, both files must be updated together.

> **Set app floor pins to the latest tested version.** On an in-place UPGRADE the
> role installs `state: latest` (whatever the feed serves), but on a FRESH install
> it pins to exactly `min_version`. If the floor is below the feed latest, clean
> hosts and previously-installed hosts converge on DIFFERENT versions. Pin the
> floor to the latest known-good version so both install paths land on the same
> build. (Observed 2026-07-20: a Vim floor of 9.2.653 left clean hosts on 9.2.653
> while upgraded hosts went to 9.2.810; floor raised to 9.2.810 to converge.)

#### Serving the mirror (separate workflow)
Chocolatey requires a **NuGet v2 (OData)** feed - NuGet v3 (the newer JSON
API) is not supported by the Chocolatey client. Whichever serving solution
is chosen, it must expose a v2/OData endpoint. In product config this is
typically labelled "NuGet hosted (v2)" or "Chocolatey-compatible".

Common serving options:
- **Local folder / UNC share** - `choco install <id> --source C:\path` or `\\server\share`. No HTTP layer, no auth, no search index, but works directly against what the playbook produces. Good for quick verification and small / air-gapped sites.
- **Chocolatey.Server** - lightweight IIS-hosted NuGet v2 feed maintained by Chocolatey Software. Drop the `.nupkg`s into its `App_Data\Packages\` folder and IIS serves them. The canonical free "host your own" answer.
- **ProGet / Sonatype Nexus (NuGet hosted) / JFrog Artifactory** - full-featured artifact servers with NuGet v2 hosted repo support. Either bind-mount the package directory or `nuget push` each `.nupkg` into the feed.

The choice of feed product is out of scope for this playbook. Whoever owns
the feed side iterates over `C:\tools\chocoRepo\*\*.nupkg` (per-package
subdirectories, latest version per directory or all versions, depending on
retention policy) and feeds those files into the chosen server.

To smoke-test a bundled package against `chocoDeploy` without a running
feed, copy a single `.nupkg` to any path reachable by the target host and:
```bash
ansible <host> -m ansible.windows.win_shell \
  -a "choco install <id> --source <unc-or-local-path> --force -y"
```
The role itself reads its source URL from `trusted_choco_source` in
[defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml); point
that at the real feed once it is up.

#### Runtime policy
### Default `.NET` policy
- family: `aspnetruntime`
- auto-detects all present tracks based on deployment mode
- configured channels: `8.0`, `9.0`, `10.0`

### `.NET` multi-track behavior
# When `targetRuntimes` includes `dotnet_runtime` without a specific `track` or `tracks`, the role auto-detects which .NET tracks are present:
- `choco_conversion`: scans both Chocolatey inventory and the Windows uninstall registry for Runtime / ASP.NET Core / Windows Desktop Runtime entries across all configured tracks
- `choco_update`: scans Chocolatey inventory only
- `choco_baseline`: processes all configured channels

# Only tracks with a configured channel minimum version are processed. A vendor-installed .NET 6 with no channel config is silently ignored by alignment; use `min_supported_track` plus `dotnetSweep` to actively remove EOL tracks (see below).

# The Chocolatey package installed for each track uses the policy family (default `aspnetruntime`), e.g. `dotnet-8.0-aspnetruntime`, `dotnet-10.0-aspnetruntime`.

### Approved `.NET` channel minimums
The configured tracks and their minimums live in
`acceptable_versions.runtimes.dotnet_runtime.channels` in
[defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml).
That file is the master pin reference; the values move as candidates are promoted
through the test-pin workflow, so they are not restated here.

#### .NET behavior by deployment mode
- `choco_baseline` - aligns every track declared in `channels` (or `tracks` override). Installs missing tracks at the channel minimum. Vendor cleanup is opt-in (`dotnet_cleanup_vendor: true`).
- `choco_update` - only aligns tracks Chocolatey already owns on the host. Never installs a new track, never sweeps.
- `choco_conversion` - aligns tracks present in choco inventory OR detected as vendor installs in the uninstall registry. With `dotnet_cleanup_vendor: true`, removes the matching vendor Runtime / ASP.NET Core / Windows Desktop Runtime entries after the choco install verifies.

#### .NET flags
- `dotnet_cleanup_vendor` (default `false`) - remove non-Chocolatey .NET Runtime / ASP.NET Core / Windows Desktop Runtime entries whose major.minor matches an aligned track. SDKs, Targeting Packs, Host components, and IIS Hosting Bundles are **never** touched.
- `dotnet_audit_only` (default `false`) - discover and report what would change without making changes. Useful for the first run of `exclusive: true` or `dotnet_cleanup_vendor: true`.
- `acceptable_versions.runtimes.dotnet_runtime.exclusive` (default `false`) - enables `dotnetSweep` over channel mismatches. Out-of-policy tracks (both choco-managed and vendor) are removed.
- `acceptable_versions.runtimes.dotnet_runtime.min_supported_track` (default `""`, i.e. OFF) - any installed .NET track strictly less than this value is removed by `dotnetSweep` regardless of exclusive mode. **As of June 16 2026 this ships EMPTY so routine runs never retire EOL .NET.** Set it to a track (e.g. `"8.0"`) in `defaults/main.yml` to make EOL sweep the fleet default again, or opt in per run with `-e '{"targetRuntimes":[{"key":"dotnet_runtime","min_supported_track":"8.0"}]}'`.
- `acceptable_versions.runtimes.dotnet_runtime.floor_required` (default `false`) - when true, the floor track is always added to the alignment list and `dotnetSweep` runs even in `choco_update` mode. Designed for mixed-fleet onboarding where some hosts have no .NET at all.

#### .NET sweep (out-of-policy cleanup)
**Default = OFF (June 16 2026).** With the shipped catalog (`min_supported_track: ""`, `exclusive: false`, `floor_required: false`) the sweep predicate is inactive and NOTHING is removed. EOL .NET 6/7 are left in place; only detected 8.0/9.0/10.0 tracks upgrade in-channel. Re-enable the sweep deliberately (catalog edit for fleet-wide, or per-run `-e` opt-in) and ONLY after a per-host dependency scan: a framework-dependent app pinned to `net6.0` does NOT roll forward to .NET 8 by default and will fail to start if its runtime is removed. A June 2026 fleet probe found .NET 6.0.36 on 36 of 123 hosts (4 also carry WindowsDesktop.App 6.0.36 = .NET 6 GUI apps).

`dotnetSweep` runs when ANY of `exclusive: true`, `min_supported_track` (non-empty), or `floor_required: true` is set, after the per-track aligners. It removes:
- Any choco package matching `^dotnet-[0-9]+\.[0-9]+-(aspnetruntime|runtime|windowsdesktop-runtime)$` whose track is **below the floor** (e.g. `dotnet-6.0-aspnetruntime` when floor is `8.0`)
- Any same-pattern choco package whose track is **not in `channels`** (exclusive mode only)
- Any vendor Runtime / ASP.NET Core / Windows Desktop Runtime entry in the uninstall registry matching the same predicates

Sweep is **skipped in `choco_update` mode** unless `floor_required: true` (mixed-fleet onboarding).

SDKs, Targeting Packs, Host components, and IIS Hosting Bundles are **never** removed by sweep - those can break unrelated workloads and must be addressed deliberately, not as a side effect of runtime alignment.

The report `notes` column distinguishes the reason:
- `Removed .NET track 6.0 (below min supported track 8.0)`
- `Removed out-of-policy .NET track 11.0 (exclusive mode)`

### Example: align all detected `.NET` tracks
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l <host> \
  -e "deployment=choco_conversion" \
  -e '{"targetRuntimes":["dotnet_runtime"]}'
```

### Example: target specific `.NET` tracks
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l <host> \
  -e "deployment=choco_conversion" \
  -e '{"targetRuntimes":[{"key":"dotnet_runtime","tracks":["8.0","10.0"]}]}'
```

### Example: convert vendor .NET to Chocolatey ownership (cleanup vendor)
```bash
# Detects vendor Runtime/AspNet/WindowsDesktop entries for aligned tracks,
# installs the matching choco package, then uninstalls the vendor entries.
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l <host> \
  -e "deployment=choco_conversion" \
  -e '{"targetRuntimes":["dotnet_runtime"],"dotnet_cleanup_vendor":true}'
```

### Example: retire EOL .NET 6 / 7 across the fleet (mixed-fleet onboarding)
```bash
# - Hosts with no .NET                -> floor (8.0) installed
# - Hosts on .NET 6 / 7 (choco/vendor) -> removed by sweep, floor installed
# - Hosts on .NET 8 / 9 / 10           -> updated in-channel
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -e "deployment=choco_update" \
  -e '{"targetRuntimes":[{"key":"dotnet_runtime","floor_required":true}]}'
```

### Example: single `.NET` track override
## Put this in host vars or group vars for systems that must stay on `.NET 8`
```yaml
acceptable_versions:
  runtimes:
    dotnet_runtime:
      family: "aspnetruntime"
      track: "8.0"
      min_version: "8.0.28"
```

# Result: the host stays on `.NET 8` and is still upgraded to the approved `.NET 8` patch level.

### Example Python override
Python is **side-by-side capable** - multiple major.minor tracks can coexist on the same host, each as its own Chocolatey package (`python312`, `python313`, `python314`). The catalog declares all supported tracks under `channels`.

```yaml
acceptable_versions:
  runtimes:
    python:
      # Legacy single-track fallback (used only when channels is empty).
      package_name: "python313"
      min_version: "3.13.5"
      # exclusive: true causes pythonSweep to remove any choco-managed or
      # vendor Python install whose major.minor is NOT in this channel map.
      exclusive: false
      # min_supported_track: any track strictly less than this value is
      # removed by pythonSweep regardless of exclusive mode. Use this to
      # enforce a floor (e.g. retire end-of-life Python) without forcing
      # exclusivity over newer-than-catalog tracks.
      min_supported_track: "3.12"
      # floor_required: when true, the min_supported_track is always added
      # to the alignment list and sweep runs even in choco_update mode.
      # Use this for mixed-fleet onboarding - hosts with no python get
      # the floor installed, hosts with newer tracks update in-channel,
      # below-floor installs are removed.
      # FLEET DEFAULT IS TRUE -- every targetRuntimes:["python"] run
      # enforces the 3.12 floor across all hosts. See "Python flags" below.
      floor_required: true
      channels:
        "3.12":
          package_name: "python312"
          min_version: "3.12.13"
        "3.13":
          package_name: "python313"
          min_version: "3.13.5"
        "3.14":
          package_name: "python314"
          min_version: "3.14.3"
```

Per-host narrowing (e.g. lab host only needs 3.13):
```yaml
choco_target_runtime_map:
  python:
    tracks: ["3.13"]
```

Per-host pinning of a specific patch level on a single track:
```yaml
choco_target_runtime_map:
  python:
    tracks: ["3.13"]
    min_version: "3.13.13"
    package_name: "python313"
```

#### Python behavior by deployment mode
- `choco_baseline` - aligns every track declared in `channels` (or `tracks` override). Installs missing tracks at floor. Vendor cleanup is opt-in (`python_cleanup_vendor: true`).
- `choco_update` - aligns tracks Chocolatey already owns on the host. With the fleet default `floor_required: true`, ALSO installs the floor track (3.12) on hosts that have no python and sweeps below-floor installs in this mode.
- `choco_conversion` - aligns tracks that are present in choco inventory OR detected as vendor installs in the uninstall registry. Will replace vendor python with choco-managed python for the matching track. With the fleet default `floor_required: true`, ensures the 3.12 floor ends up installed on every targeted host regardless of what was there before.

#### Python flags
- `python_cleanup_vendor` (default `false`) - remove non-Chocolatey python installs whose major.minor matches an aligned track.
- `python_cleanup_aliases` (default `false`) - remove generic alias packages (`python`, `python3`).
- `python_audit_only` (default `false`) - discover and report what would change without making changes. Useful for the first run of `exclusive: true`.
- `acceptable_versions.runtimes.python.exclusive` (default `false`) - enables `pythonSweep` over channel mismatches. Out-of-policy tracks (both choco-managed and vendor) are removed.
- `acceptable_versions.runtimes.python.min_supported_track` (default `"3.12"`) - any installed Python track strictly less than this value is removed by `pythonSweep` regardless of exclusive mode. Set to `""` to disable the floor.
- `acceptable_versions.runtimes.python.floor_required` (**default `true`** as of June 2026 fleet policy) - when true, the floor track is always added to the alignment list and `pythonSweep` runs even in `choco_update` mode. Every `targetRuntimes:["python"]` run will guarantee the host ends up at or above the 3.12 floor. To opt out for a single run, pass `-e '{"targetRuntimes":[{"key":"python","floor_required":false}]}'`.

#### Mixed-fleet onboarding pattern (`floor_required: true`)
One run brings a list of hosts in any state to policy:
- No python installed -> floor track is installed at `min_version` (e.g. 3.12.13)
- Has older 3.12.x -> upgraded to 3.12.13 in-channel
- Has 3.13.x / 3.14.x -> upgraded to channel `min_version`
- Has 3.11 / 3.10 / 3.9 / 2.x -> removed by sweep, floor track installed

Typical command:
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i inventory/<your_list>.yml \
  --vault-password-file=vault/.vault_key.txt \
  -e "deployment=choco_update" \
  -e '{"targetRuntimes":[{"key":"python","floor_required":true}]}'
```

#### Python sweep (out-of-policy cleanup)
`pythonSweep` runs when ANY of `exclusive: true`, `min_supported_track`, or `floor_required: true` is set, after the per-track aligners. The fleet default `floor_required: true` means the sweep runs on every `targetRuntimes:["python"]` invocation. It removes:
- Any choco package matching `^python[0-9]+$` whose track is **below the floor** (e.g. `python39` when floor is `3.12`)
- Any choco package matching `^python[0-9]+$` whose track is **not in `channels`** (exclusive mode only)
- Any vendor python install in the uninstall registry matching the same predicates
- Alias packages (`python`, `python3`) if `python_cleanup_aliases: true`

Sweep is **skipped in `choco_update` mode ONLY when `floor_required: false`**. Because the fleet default is `floor_required: true`, every routine update run for python now sweeps below-floor installs as well.

The report `notes` column distinguishes the reason:
- `Removed Python track 3.10 (below min supported track 3.12)`
- `Removed out-of-policy Python track 3.15 (exclusive mode)`

#### Per-user Python discovery (HKEY_USERS advisory)
The HKLM-based sweep only sees machine-wide Python installs. Per-user installs (Python installer "Install for me only", default for some user workflows) land in the per-user hive under `HKCU` and are not visible via `HKLM` scans.

`pythonResolve` now performs a **read-only HKEY_USERS scan** on every run that includes `targetRuntimes:["python"]`. For every loaded user hive it walks:
- `HKEY_USERS\<SID>\Software\Microsoft\Windows\CurrentVersion\Uninstall\*`

Matches against `DisplayName ~ '^Python\s+\d+\.\d+'` with `Publisher != Chocolatey` are recorded. The role does **not** remove them; per-user Python removal needs explicit follow-up because the uninstaller's MSI state is per-user and the role runs as the admin context.

Output:
- Each finding appears in the per-run JSON under `advisories.python_hku.findings` with SID, resolved user name, DisplayName, version, track, and install location.
- A summary advisory event is added to `errors[]` (`software=python-hku`, `operation=per-user-python-advisory`) so it surfaces in the standard Errors & Advisories table.
- The per-host HTML report renders a dedicated **"Per-user Python detected (HKEY_USERS)"** section when at least one finding exists.

Cost: ~0.5-1s on a typical host, 2-5s on a multi-session Terminal Services host. Read-only registry walk; no disk I/O.

Limitations:
- Only **loaded** user hives are visible. A user who hasn't logged in since last boot won't have their hive in HKEY_USERS. The role does not mount profile hives.
- Removal is intentionally not automated. Use the SID + install location from the report to drive a targeted manual cleanup.


### Example PowerShell override
```yaml
acceptable_versions:
  runtimes:
    powershell_core:
      package_name: "powershell-core"
      min_version: "7.6.3"
      floor_required: true
```

#### PowerShell Core behavior
**Fleet default (June 2026): `min_version: 7.6.3`, `floor_required: true`.**
- Single-track runtime (no channels). One install per host.
- Every `targetRuntimes:["powershell_core"]` run brings the host to >= 7.6.x. Hosts with no pwsh get one installed; hosts on older versions are upgraded in place.
- Sweep runs in all deployment modes (including `choco_update`) because `floor_required: true`.
- `pwsh_audit_only=true` previews changes without making them. Standard pattern for the first run on an inventory that has not been touched.
- **Known WinRM disconnect during install**: The PowerShell engine is part of the WinRM service plugin chain on Windows. A pwsh upgrade can momentarily yank file handles and the WinRM session returns HTTP 400. That disconnect is a transport-level error raised before the module returns, so `failed_when: false` cannot catch it; the install task therefore uses `ignore_errors: true`. Success is decided afterward by a retried `choco list` query plus a version assert, so a real failure is still caught while a harmless mid-install disconnect is tolerated. The install usually completes successfully even when Ansible saw a disconnect mid-task.
- **Vendor cleanup is gated on Chocolatey ownership, not floor compliance.** The vendor-discovery / parse / removal tasks run only when Chocolatey does **not** already own `powershell-core` (`not pwsh_choco_present`). A choco-owned host that is simply below the floor (e.g. choco 7.6.0 under a 7.6.3 floor) upgrades in place and never enters the vendor path. This avoids a false-positive removal: choco-installed pwsh leaves an MSI uninstall entry whose `Publisher` is `Microsoft Corporation` (or null), not `Chocolatey`, so the publisher-based vendor scan would otherwise misflag the currently-managed install as "vendor", "remove" it, and re-install it. That would emit a misleading `Removed (source=vendor)` event even though nothing was actually lost. Vendor cleanup now fires only on true vendor-only hosts (no choco package present).

#### Vendor Python cleanup (integrated into pythonSweep)

Vendor-installed Python (the python.org bundle EXE, run directly or pre-Chocolatey) registers as 8-10 component MSIs per track (Core Interpreter, Standard Library, Tcl/Tk Support, Test Suite, Documentation, pip Bootstrap, Add to Path, Executables, etc.) with NO single bundle entry visible to silent uninstall. `pythonSweep` handles this automatically as part of any chocoDeploy run that targets the python runtime when the sweep is active (floor_required, min_supported_track, or exclusive).

The sweep groups discovered vendor components by major.minor track, then for each below-floor or out-of-policy track invokes the helper script [playbooks/roles/chocoDeploy/files/remove_vendor_python_track.ps1](../../playbooks/roles/chocoDeploy/files/remove_vendor_python_track.ps1) which:

- Runs `msiexec /x <ProductCode> /qn /norestart` on every component for that track.
- Falls back to direct registry-key removal for components that return 1603 (typically pip Bootstrap and Tcl/Tk Support, whose custom actions fail when Core Interpreter is already gone). The actual files are removed by Core's uninstall; the fallback just deletes the orphan registry entry so the host reports clean.
- Removes empty install directories (`C:\PythonXY`, `C:\Program Files\PythonXY`) only when empty.

Each removed component produces a `Removed` event in the per-run JSON tagged `source=vendor` with the removal action recorded in notes (`via msiexec_ok` or `via msi_fail_reg_deleted`). A `python-vendor-sweep-incomplete` error is added to the report only when components remain after all attempts. Validate cleanup behavior and timing on your own isolated lab targets.

#### Optional standalone fleet reconnaissance tools

Two helpers exist for planning vendor python cleanup **before** running chocoDeploy with `python_audit_only=true`:

- [playbooks/roles/chocoDeploy/files/scan_python_state.ps1](../../playbooks/roles/chocoDeploy/files/scan_python_state.ps1) - read-only PowerShell scan, emits compact JSON per host listing every Python-related install (choco + vendor components grouped by track).
- [playbooks/roles/chocoDeploy/files/fleet_python_scan_summary.py](../../playbooks/roles/chocoDeploy/files/fleet_python_scan_summary.py) - control-node aggregator. Reads scan output collected via ansible and produces a fleet-wide report with `--floor 3.12` showing which hosts have below-floor tracks.

```bash
# Scan
ansible <hosts> -i <inv> --vault-password-file=vault/.vault_key.txt -e @vault/corp-ans-secret.yml \
  -m ansible.windows.win_copy \
  -a 'src=playbooks/roles/chocoDeploy/files/scan_python_state.ps1 dest=C:/Windows/Temp/scan_python_state.ps1'

ansible <hosts> -i <inv> --vault-password-file=vault/.vault_key.txt -e @vault/corp-ans-secret.yml \
  -m ansible.windows.win_shell \
  -a '& "C:/Windows/Temp/scan_python_state.ps1"' > /opt/ansible/LOGS/chocoDeploy/fleet_python_scan.txt

python3.12 playbooks/roles/chocoDeploy/files/fleet_python_scan_summary.py \
  /opt/ansible/LOGS/chocoDeploy/fleet_python_scan.txt --floor 3.12
```

The python.org bundle EXE (`python-X.Y.Z-amd64.exe /uninstall /quiet`) is NOT a reliable cleanup path on fleet hosts: it depends on cached payloads in `C:\ProgramData\Package Cache\.unverified\` that are routinely missing, returning 1603 with no entries removed. `choco uninstall pythonXY` only works when Chocolatey installed the package; it refuses to touch what it didn't install. The integrated pythonSweep handles both cases correctly without operator decisions.

#### Role defaults reference
Every setting below lives in
[defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml). That file
keeps only one-line labels; this section is the explanation. Override any of them
per run with `-e`, or per inventory in `group_vars`/`host_vars`.

**Run scope**
- `deployment` - default `choco_conversion`. See "Deployment modes".
- `targetSoftware` / `removeSoftware` - `null` = full catalog, `[]` = skip, a list = only
  those entries. See "Target software input" and "Remove software input".
- `targetRuntimes` - default `[]` (no runtime alignment). See "Target runtime input".
- `alwaysRemoveSoftware` and `managed_runtimes` - legacy keys from older inventories.
  Still honored; do not use them in new work.

**Reports**
- `choco_deploy_report_dir` - control-node report dir, default
  `$CHOCO_FLEET_DATA_ROOT/LOGS/chocoDeploy` (`/opt/ansible/LOGS/chocoDeploy`).
- `choco_deploy_local_report_dir` - on-target dir, default `C:\tools\chocolog`, ACL'd to
  `Authenticated Users: Modify`, pruned after `choco_deploy_local_report_retain_days` (90).
- `choco_deploy_reset_daily` - `true` deletes today's (UTC) JSON/HTML reports on the
  target before writing this run's report. Use after a troubleshooting session left
  bad data in the daily roll-up.

**Reboots and pending reboots**
- `choco_deploy_reboot` - `never` (default), `always`, or `if_needed`. The reboot is
  logged to the Windows Application event log first. Keep `never` during patch
  windows: record the advisory, do not force a fleet reboot.
- `choco_deploy_skip_pending_reboot` - `true` skips alignment on hosts with a pending
  reboot and logs an advisory. Either way, hosts that had a pending reboot are listed
  in `choco_deploy_pending_reboot_inventory`
  (`<report dir>/pending_reboot_hosts.yml`) for a separate, deliberate reboot pass.

**Timeouts**
- Each catalog entry declares `install_size`, which picks both limits:

  | Size | Examples | Chocolatey timeout | Task cap |
  | --- | --- | --- | --- |
  | small | 7zip, putty, vim, winscp, notepad++ | 300 s | 360 s |
  | medium | git, vscode, docker-desktop, teams, pwsh, python, modern .NET | 900 s | 1080 s |
  | large | PyCharm and other JetBrains IDEs, .NET Framework | 2700 s | 3000 s |

- The Chocolatey `--execution-timeout` only counts while Chocolatey thinks work is
  progressing, so a stalled WinRM session or stuck uninstaller never trips it. The
  Ansible task cap is what actually kills a hung task; it sits slightly higher so
  Chocolatey can report its own failure first.
- `choco_deploy_install_timeout` (900) is the fallback for anything without a size.

**Vendor uninstall verification**
- Many uninstallers (JetBrains, Inno Setup, NSIS) return success while a helper is
  still tearing down, so the registry entry lingers. Before the Chocolatey install,
  the role waits for it to disappear: `choco_deploy_vendor_verify_retries` (12) x
  `choco_deploy_vendor_verify_delay` (5 s) = 60 s budget. It exits on first success.

**Setting a version floor** (`acceptable_versions`)
- Floors move by promotion only: stage in `choco_test_pins`, validate on TEST, then
  promote. See the QuickRef "Test-pin workflow".
- Use the Chocolatey version, not the registry `DisplayVersion`. Chocolatey drops
  leading zeros: 7-Zip `26.02` (registry `26.02.0.0`) is `26.2.0`.
- A fresh install pins to exactly `min_version`, while an upgrade (`state: latest`)
  lands on the feed's latest. For fast-moving packages (for example vim), set the floor
  to the feed latest so both paths end on the same version.
- `azure_cli`: bump the floor and its chocoBuild internalize-spec entry together, then
  re-run chocoBuild `--tags community`. Microsoft ships a new minor about every three weeks.
- `nxlog` means the community `nxlog` package, not the abandoned `nxlog-ce`.

**Test pin fields** (`choco_test_pins.<name>`)
- `candidate_version` - version under test; not the fleet floor.
- `rollback_version` - one step older; use it if the candidate fails, without touching
  `acceptable_versions`.
- `current_floor` - the floor when the pin was staged, so drift is visible.
- `status` - `testing` | `promoted` | `rolled_back`. `test_inventory` - where it is validated.
- After promotion, delete the entry. Git history keeps the record.

**Current runtime policy**
- Python: `floor_required: true`, `min_supported_track: "3.12"`. Every run that targets
  python ends at or above 3.12, including installing it on hosts with none, even in
  `choco_update`. See "Python flags".
- PowerShell Core: single track, `floor_required: true`. Every run that targets
  `powershell_core` installs it where missing and upgrades in `choco_update` too. Opt
  out for one run with `-e '{"targetRuntimes":[{"key":"powershell_core","floor_required":false}]}'`.
- .NET: `min_supported_track: ""` on purpose, so EOL tracks are never retired by a
  routine run. See ".NET sweep".
- .NET Framework: uses `netfx-4.8.1`, because the `dotnetfx` meta-package stops at 4.8.
  Supported on Win10 22H2, Win11 and Server 2022/2025; installs as a no-op where 4.8.1
  is already in-box. Detected by the `Release` DWORD at
  `HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\Release` (533320 on Win11,
  533325 on Win10 / Server 2022). It cannot be uninstalled, and the 4.8 -> 4.8.1 upgrade
  needs a reboot.

**Sources**
- See "Trusted source behavior". `choco_disable_public_source: true` removes the public
  feed entirely, so only use it once every catalog package is on the internal mirror.

**Managed app catalog** (`choco_managed_apps`, `choco_always_remove_catalog`)
- `key` - Chocolatey package id. `aliases` - names accepted in `targetSoftware` /
  `removeSoftware`.
- `detect_packages` / `registry_patterns` - how existing Chocolatey and vendor installs
  are found.
- `task_file` - per-app task file under `tasks/apps/`.
- `requires_explicit_target: true` - never part of a default run; only runs when named
  in `targetSoftware` (Teams, azure-cli).
- `pre_remove_script` - runs before a vendor uninstall during conversion. It kills the
  app with `taskkill /F /T`, because `Stop-Process` from the WinRM SYSTEM context can
  miss RDP and console sessions. Inno Setup apps (Greenshot, WinSCP) otherwise leave
  `PendingFileRenameOperations` behind, which puts the next run into reboot-advisory mode.
- `force_orphan_cleanup_script` - opt-in per run with
  `-e <key>_force_replace_orphan=true` (dots and dashes become underscores). It removes
  the orphaned non-Chocolatey uninstall key and install directory left by a failed vendor
  uninstall. For Docker Desktop it also clears stale Chocolatey lib metadata. User data
  and settings are always kept. Available for `docker_desktop`, `greenshot`, `pycharm`
  and `winscp_install`.

#### Where to change behavior
## Change approved versions
# Promote a validated test pin into `acceptable_versions` in [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml). See the QuickRef "Test-pin workflow"; do not hand-edit floors to chase a version.

## Change the default mode
# Edit `deployment` in [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml).

## Change the managed app catalog
# Edit `choco_managed_apps` in [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml).

## Add custom install or uninstall behavior
# Edit or add app task files under [playbooks/roles/chocoDeploy/tasks/apps](../../playbooks/roles/chocoDeploy/tasks/apps).

## Change the trusted source
# Edit `trusted_choco_source` in [playbooks/roles/chocoDeploy/defaults/main.yml](../../playbooks/roles/chocoDeploy/defaults/main.yml).

#### Safe operating guidance
- use `choco_conversion` for routine alignment without adding new apps
- use `choco_update` for the fastest recurring compliance pass
- use `choco_baseline` for provisioning or full remediation
- use `choco_selective` to add/update ONE named app across deployed hosts
  (install-if-missing + convert + upgrade); always pass an explicit
  `targetSoftware` -- the mode refuses to run without one
- test new app logic on one host first with `-l <hostname>`
- keep host-specific exceptions such as `.NET 8` in host vars or group vars

#### Chocolatey install behavior
### `choco_ignore_checksums`
# Default: `true`. Bypasses Chocolatey package integrity checks during install.
# Set to `false` when all packages are served from a signed internal repository.

### `choco_force_install`
# Default: `false`. Forces reinstall even when the same version is already present.
# Adds overhead on every aligned package; enable only for troubleshooting.

#### Quick decision table
| Goal | Mode | Expected result |
|---|---|---|
| Convert what is already there | `choco_conversion` | Detected managed software is brought under approved Chocolatey management |
| Fast align only Chocolatey-visible software | `choco_update` | Only Chocolatey-reported managed software is checked and upgraded if needed |
| Install and standardize everything approved | `choco_baseline` | Full approved catalog is installed and aligned |
| Add/update ONE named app across deployed hosts | `choco_selective` | Only the named `targetSoftware` apps are installed-if-missing, converted, or upgraded; nothing else is touched |

#### Plain rule of thumb
- routine patch cycle with conversion: `choco_conversion`
- fast recurring check on Chocolatey-managed apps only: `choco_update`
- build or re-baseline a system: `choco_baseline`
- add or update a specific app (e.g. azure-cli) on existing hosts: `choco_selective`