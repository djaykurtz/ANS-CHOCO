########## Reporting Quick Usage

The repo has four reporting systems. This is the fast command reference; for how
they are built and where output lands see [Reporting_Guide.md](Reporting_Guide.md).

1. Pre-patch readiness  - [playbooks/patchReady.yml](../../playbooks/patchReady.yml)
2. Post-patch report    - built into chocoDeploy ([playbooks/roles/chocoDeploy/tasks/ops/report.yml](../../playbooks/roles/chocoDeploy/tasks/ops/report.yml))
3. Fleet summary roll-up- [playbooks/roles/chocoDeploy/files/fleet_summary.py](../../playbooks/roles/chocoDeploy/files/fleet_summary.py)
4. Software usage scan  - [playbooks/softwareUsage.yml](../../playbooks/softwareUsage.yml)

All commands follow the repo command framing standard (see the root README).
Control-node report paths derive from `$CHOCO_FLEET_DATA_ROOT`; `/opt/ansible` is
the production default used here.

#### Report selection gate

- `patchReady.yml` = pre-patch readiness HTML on the control node.
- `deployment=report_only` = rebuilds the target's daily chocoDeploy HTML from
  existing target JSON; it does not create missing control-node JSON.
- `fleet_summary.py` = final control-node fleet HTML, with optional detailed JSON
  and text output.
- Treat the script output `Found N JSON files across M hosts` as a coverage gate.
  If `M` is below the intended scope, report the roll-up as partial. Do not hand
  author a replacement HTML or Markdown report.

#### 1. Pre-patch readiness check
No software changes, no reboots. Tests WinRM, pending-reboot, C: free space, and
Chocolatey health, then writes an HTML report. Scores each host READY / WARN (shown as
CHECK in the HTML) / FAIL. Side effect: archives chocoDeploy logs older than 90 days
on each reachable host into `C:\tools\chocolog\archive\`.
```bash
ansible-playbook playbooks/patchReady.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts
```
Output (control node): `/opt/ansible/LOGS/patchReady/<UTC>_<inventory>_patchReady.html`

> New inventory dir for the check? It needs its own `group_vars/basic_hosts.yml`
> (WinRM connection vars) or every host falls back to SSH and fails with
> `sshpass ... Host Key checking`. See the chocoDeploy Guide "Connection vars" note.

#### 2. Post-patch report (chocoDeploy)
Produced automatically by every chocoDeploy run. To rebuild the consolidated HTML
from existing per-run JSONs without changing software:
```bash
ansible-playbook playbooks/chocoDeploy.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -l basic_hosts \
  -e "deployment=report_only"
```
Outputs:
- Per-run JSON: target `C:\tools\chocolog\` and control `/opt/ansible/LOGS/chocoDeploy/`
- Consolidated daily HTML: target `C:\tools\chocolog\<date>_chocoDeploy.html`

#### 3. Fleet summary roll-up
Aggregates per-host control-node JSONs into one fleet HTML summary for a
downtime review board. Run on ansible-ctl-01 after a window.
```bash
python3.12 playbooks/roles/chocoDeploy/files/fleet_summary.py \
  --today --archive --short-names
```
```bash
python3.12 playbooks/roles/chocoDeploy/files/fleet_summary.py \
  --since 20260616T010000Z --until 20260616T070000Z --short-names
```
Common flags: `--today`, `--last-hours N`, `--since/--until <UTC>`, `--short-names`,
`--json-dir <dir>`, `--output-dir <dir>` (default `/opt/ansible/LOGS/chocoDeploy/reports/`),
`--archive`, `--retain-days N`.

`--archive` moves the consumed per-host JSONs into
`<json-dir>/archive/<UTC>_chocoDeploy_run.zip` (they leave the JSON directory, so a
later summary of the same window will not find them) and deletes archive zips older
than `--retain-days` (default 90). Leave it off when the JSONs are still needed as
evidence.

Input: `<UTC>_<host>_chocoDeploy.json` files at the top level of `--json-dir`
(default `/opt/ansible/LOGS/chocoDeploy`), plus collector `<host>/` folders one level
down. Other subfolders are not read.

The main output is always HTML. `--include-json` and `--include-text` place
structured/detail files under `<output-dir>/detailed/`.

#### Live compliance evidence after an interrupted run

Use the read-only evidence path when deployment JSON was not written:
```bash
ansible-playbook playbooks/tools/collect_compliance_state.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -e @vault/corp-ans-secret.yml \
  -l basic_hosts \
  -e "compliance_state_dir=/opt/ansible/LOGS/chocoDeploy/compliance-state"
```
```bash
python3.12 playbooks/tools/build_compliance_evidence.py \
  --state-dir /opt/ansible/LOGS/chocoDeploy/compliance-state \
  --inventory <inventory> \
  --csv <campaign.csv> \
  --defaults playbooks/roles/chocoDeploy/defaults/main.yml \
  --output-dir /opt/ansible/LOGS/chocoDeploy/compliance-json
```
Then run `fleet_summary.py --json-dir /opt/ansible/LOGS/chocoDeploy/compliance-json`. This is read-only live
version evidence, not a deployment pass.

After an interrupted run, recover target-side JSONs first:
```bash
ansible-playbook playbooks/tools/collect_chocoDeploy_reports.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -e @vault/corp-ans-secret.yml \
  -l basic_hosts \
  -e "choco_report_collect_dir=/opt/ansible/LOGS/chocoDeploy/recovered"
```

#### 4. Software usage scan
Read-only. Reads Security EventID 4688 (process creation) per host and reports which
catalog apps were actually used in a lookback window.
```bash
ansible-playbook playbooks/softwareUsage.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt
```
```bash
# 7-day window
ansible-playbook playbooks/softwareUsage.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -e "usage_days=7"
```
```bash
# "used at all" threshold
ansible-playbook playbooks/softwareUsage.yml \
  -i <inventory> \
  --vault-password-file=vault/.vault_key.txt \
  -e "usage_min_executions=1"
```

#### Pull reports to a local workstation
```powershell
scp <you>@ansible-ctl-01.example.com:/opt/ansible/LOGS/chocoDeploy/reports/* C:\tools\chocolog\
```
