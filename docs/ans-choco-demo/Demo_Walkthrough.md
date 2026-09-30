# Demo Walkthrough

Six example steps that walk one patch cycle and one version-floor update, each
showing a different part of ANS-CHOCO. Configure your own isolated, authorized lab
first; included host names and credentials are nonfunctional examples.
Use a lab target in `inventory/TEST/inv-TEST-solo.yml`. Only steps 3 and 6d
change software on the host (optional step 6c adds a package to the mirror), and
nothing in the example commands requests a reboot.

## Before you start

Use your Linux lab checkout; `/opt/ansible/repos/choco-fleet` is an example path
for an independently configured control node. The optional Azure/Arc pipeline is
manual and requires separately provisioned infrastructure. See
[CONFIGURE.md](../../CONFIGURE.md); none of these commands requires an existing
work account.

```bash
cd /opt/ansible/repos/choco-fleet
```

It needs `vault/` (`.vault_key.txt`, `corp-ans-secret.yml`) inside that folder,
placed by the checkout owner until Key Vault retrieval replaces it. Step 1 confirms
it works.

| What | Where |
| --- | --- |
| Code and policy | this repo |
| Approved versions (master pin reference) | `acceptable_versions` in [chocoDeploy defaults](../../playbooks/roles/chocoDeploy/defaults/main.yml) |
| Campaign lists | `/opt/ansible/incoming/<campaign-id>/` (never in the repo) |
| Reports | `/opt/ansible/LOGS/` |
| Credentials | `vault/` in `/opt/ansible/repos/choco-fleet` (gitignored) |

## 1. Can we reach a host?

Proves the vault decrypts and WinRM/NTLM works. Ad-hoc commands need the vault
file passed with `-e @`.

```bash
ansible -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -e @vault/corp-ans-secret.yml \
  test-host-01.corp.example.com \
  -m ansible.windows.win_ping
```

Expect `SUCCESS` and `"ping": "pong"`.

## 2. Pre-patch readiness

Scores the host before a change window: WinRM, pending reboot, free space on C:,
Chocolatey health. No software changes, no reboots.

```bash
ansible-playbook playbooks/patchReady.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts
```

Expect `READY`, `WARN` or `FAIL` per host in the console (`WARN` shows as `CHECK`
in the HTML), and a report in `/opt/ansible/LOGS/patchReady/`. A pending reboot is
reported, never acted on.

## 3. Patch

`chocoDeploy` in `choco_update` mode brings Chocolatey-managed apps up to their
floors. This is the QuickRef's "Interactive monitored run" block, which shows every
part of a real deployment command: mode, explicit app/removal/runtime selection,
no reboot, and a colorized side log for watching the run.

```bash
ANSIBLE_FORCE_COLOR=1 ansible-playbook playbooks/chocoDeploy.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_update" \
  -e '{"targetSoftware":["vscode","7zip","git"],"removeSoftware":[],"targetRuntimes":[]}' \
  -e "choco_deploy_reboot=never" \
  2>&1 | tee /opt/ansible/LOGS/chocoDeploy/demo-patch.log
```

Actual events depend on your lab host's installed state; no run result is
promised by this example. The console line
`chocoDeploy summary: ... changes=N` counts report events, not upgrades; the
per-run JSON `summary` block has the real counts. Other modes
(`choco_conversion`, `choco_selective`, `choco_baseline`) are in the
[QuickRef](../deploy/chocoDeploy_QuickRef.md).

## 4. Post-patch report

Every chocoDeploy run writes a per-run JSON (host `C:\tools\chocolog\` and
`/opt/ansible/LOGS/chocoDeploy/`) and updates the host's daily HTML. Roll the
window up into one fleet report; this runs locally and contacts no host.

```bash
python3.12 playbooks/roles/chocoDeploy/files/fleet_summary.py \
  --last-hours 24 \
  --short-names
```

Expect `Found N JSON files across M hosts` (M is the coverage check) and an HTML
report in `/opt/ansible/LOGS/chocoDeploy/reports/`. For a change window use
`--since/--until <UTC>`; for a folder of recovered or copied reports add
`--json-dir <folder>`.

## 5. Rebuild a report without touching software

`report_only` re-renders the host's daily HTML from its existing JSON. Same
command shape as step 3; only the mode differs.

```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=report_only"
```

Expect the daily HTML rewritten in `C:\tools\chocolog` on the host.

## 6. Update a pinned version

Approved versions move only by promotion: find a candidate, stage it as a test
pin, prove it on the test host, then raise the floor. 7-Zip is a compact example;
query the current feed and validate a candidate in your own lab rather than
treating a documented version as currently available.

Steps a and d are commands run on ansible-ctl-01. Steps b, c (SMB mirror) and e
change files in the repository: make those through your reviewed version-control
process, rather than editing a deployment-managed checkout.

**a. Find the candidate.** Lists packages with a newer version on the feed
(`package|installed|available|pinned`). Read-only.

```bash
ansible -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -e @vault/corp-ans-secret.yml \
  test-host-01.corp.example.com \
  -m ansible.windows.win_shell -a "choco outdated --limit-output"
```

Expect `7zip.install|26.2.0|26.3.0|false`. Use the feed's version as the
candidate: an upgrade always lands on the newest version the feed has.

**b. Stage the pin.** In `playbooks/roles/chocoDeploy/defaults/main.yml`, add
under `choco_test_pins:`. The pin is a record only; nothing reads it during a run.

```yaml
  sevenzip_install:
    candidate_version: "26.3.0"
    rollback_version: "26.2.0"
    current_floor: "26.2.0"
    status: "testing"
    test_inventory: "inventory/TEST/inv-TEST-solo.yml"
```

**c. Optional: ingest the candidate into an internal repository (chocoBuild).**
Installs come from the public Chocolatey feed unless a run names an internal
source (`trusted_choco_source`). There are two internal repositories:

- **Nexus** (new, intended primary mirror; not yet approved for fleet use):
  `http://192.0.2.20:8081/repository/chocolatey-development/`. Ingest with
  chocoBuild's `nexus_ingest.py`; the real push needs `vault/.nexus_api_key`.

  ```bash
  python3.12 playbooks/roles/chocoBuild/files/nexus_ingest.py --id 7zip.install --version 26.3.0 --dry-run
  python3.12 playbooks/roles/chocoBuild/files/nexus_ingest.py --id 7zip.install --version 26.3.0
  ```

  To install from Nexus in step d, add:

  ```bash
    -e '{"trusted_choco_source":{"name":"nexus","url":"http://192.0.2.20:8081/repository/chocolatey-development/","priority":1}}'
  ```

- **SMB mirror** on mirror-01 (current). Add the candidate above the current
  entry in `playbooks/roles/chocoBuild/files/internalize-spec.yml`:

  ```yaml
    - { id: '7zip.install',                      version: '26.3.0' }   # future (candidate)
  ```

  Build it (the chocoBuild QuickRef "Refresh the entire mirror" command; it skips
  packages already built):

  ```bash
  ansible-playbook playbooks/chocoBuild.yml \
    -i inventory/Internalize/inv-internalize.yml \
    --vault-password-file=vault/.vault_key.txt \
    --tags community
  ```

  To install from the SMB mirror in step d, add:

  ```bash
    -e '{"trusted_choco_source":{"name":"chocoRepo","url":"\\\\mirror-01.infra.example.com\\chocoRepo","priority":1}}'
  ```

**d. Test the candidate.** The candidate takes effect only when passed with `-e`
against a TEST inventory (the QuickRef "Test-pin workflow" command for an
application).

```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=choco_conversion" \
  -e '{"targetSoftware":[{"key":"7zip","min_version":"26.3.0"}],"removeSoftware":[],"targetRuntimes":[]}' \
  -e "choco_deploy_reboot=never"
```

Expect one `Upgraded` event (26.2.0 to 26.3.0) and `errors=0`. Re-run step a:
7-Zip is no longer listed.

**e. Promote.** Raise the floor and delete the pin entry in
`playbooks/roles/chocoDeploy/defaults/main.yml`:

```yaml
acceptable_versions:
  applications:
    sevenzip_install:
      min_version: "26.3.0"
```

Set the same version in the shared catalog,
`playbooks/catalogs/chocolatey_packages.yml`:

```yaml
    approved_version: '26.3.0'
```

If you ingested into the SMB mirror in step c, keep its rollback window at
current plus previous: in that catalog entry set
`mirror_versions: ['26.3.0', '26.2.0']`, and in `internalize-spec.yml` drop the
`26.1.0` line and change the new line's comment to `# current (floor)`.

Commit the change with the validated host in the message, for example
`Promote 7-Zip floor 26.2.0 -> 26.3.0 (validated on test-host-01)`. First run:

```bash
python3.12 playbooks/tools/validate_catalog.py
```

`validate_catalog.py` must end with `PASS`. It fails if `approved_version` and the
floor differ, and checks that the internalize spec and `mirror_versions` agree.
Without the SMB ingestion it warns that 26.3.0 is not in `mirror_versions`; that
is expected when installs come from the public feed or Nexus. The fleet uses the
new floor once the change reaches `main` and deploys. If the test fails, delete the pin and leave the floor alone.
chocoDeploy never downgrades, so the test host keeps the candidate.

## Long runs

For runs against hundreds of hosts, tee the output to a side log and follow it
with `playbooks/tools/watch_run.py`, which reports unreachable and failed hosts
as they happen. See "Running with an assistant" in the
[QuickRef](../deploy/chocoDeploy_QuickRef.md).

## Where to read next

- [docs/index.md](../index.md). Each area has a Guide (understand it) and a
  QuickRef (do it).
- [FUTURE_BUILDS.md](../FUTURE_BUILDS.md) for agreed build work.

## What's next

- Dell Command Update and server firmware through the paused `sysPatch` role
  ([design](../maintenance/sysPatch_Design.md)).
- Reach hosts through Azure Arc instead of direct WinRM
  ([positioning](../orchestration/Automation_Arc_Semaphore.md)).
- Grow the webui command builder and add a reporting front end.
