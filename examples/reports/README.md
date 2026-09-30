# Synthetic report inputs

These two files are hand-authored **fictitious demonstration data**, not logs,
deployment evidence, or performance measurements. They follow the per-run JSON
shape written by `playbooks/roles/chocoDeploy/tasks/ops/report.yml`.

`demo-host-01.example.com` first has a simulated install failure, then a
successful retry. This exercises the real fleet-summary script's latest-success
error resolution. Any counts in the rendered output describe this fixture only.

From the project root:

```powershell
python playbooks\roles\chocoDeploy\files\fleet_summary.py `
  --json-dir examples\reports `
  --output-dir .demo\reports `
  --since 20260101T000000Z --until 20260101T235959Z `
  --short-names --include-json --include-text
```

On Linux use `python3` and forward slashes in the paths. Do not pass `--archive`:
it moves/removes its consumed inputs. `.demo/` is ignored and should not be
published. Neither these fixtures nor the UI preview contacts a Windows target.
