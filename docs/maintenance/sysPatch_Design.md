# sysPatch and winUpdate: design and current boundaries

**In development, not an end-to-end runnable maintenance workflow.**
The role code demonstrates a reusable maintenance-window pattern, but missing
tasks and entry playbooks prevent treating it as a finished feature.

## Intended flow

```text
authorized lab inventory + per-system check catalog
  -> acknowledgment + off-peak/reboot gates
  -> preflight
  -> Windows Update (winUpdate)
  -> vendor firmware / drivers
  -> optional reboot + wait for WinRM
  -> application-stack verification
  -> per-host evidence + explicit failure
```

All examples refer to fictitious systems. A real system needs authorized access,
a verified network path, a tested credential and its own reviewable inventory
configuration. No network topology, application inventory or operator account is
provided by this document.

## Role separation

`winUpdate` owns Windows Update search/download/install policy and update-client
state reporting. `sysPatch` delegates to it, then coordinates vendor firmware,
reboot and application health. Third-party Chocolatey application alignment
stays in `chocoDeploy`, not in either maintenance role.

## Current source files

| Area | Present implementation |
| --- | --- |
| `winUpdate/defaults/main.yml` | Audit/download/install modes, categories, retention and reboot controls |
| `winUpdate/tasks/main.yml` | Update-client survey, `win_updates`, gated reboot and result mapping |
| `winUpdate/tasks/ops/report.yml` | Per-run JSON |
| `sysPatch/defaults/main.yml` | Modes, acknowledgment/window gates, Dell tool configuration and empty verification catalog |
| `sysPatch/tasks/main.yml` | Workflow router, rescue/report/failure pattern |
| `sysPatch/tasks/ops/preflight.yml` | Disk/session/reboot authorization checks |
| `sysPatch/tasks/ops/windowsUpdate.yml` | Delegation to `winUpdate` |
| `sysPatch/tasks/ops/dsu.yml` | Vendor firmware phase |
| `sysPatch/tasks/ops/rebootCycle.yml` | Reboot/wait and boot-time verification |
| `sysPatch/files/verify_stack.ps1` | Service, scheduled-task, HTTP, log-freshness and manual check engine |
| `sysPatch/files/discover_host.ps1` | Standalone host survey that emits configuration suggestions |

## Missing pieces

`sysPatch/tasks/ops/verify.yml`, `sysPatch/tasks/ops/report.yml`, and a maintenance
HTML template are missing. The router references these missing tasks, including
a static report import, so even its nominal `verify_only` mode is not a runnable
quickstart. Neither `playbooks/sysPatch.yml` nor `playbooks/winUpdate.yml` exists.
Integration, role syntax validation and authorized lab execution remain work.

## Design decisions

The intended default is verification, with state-changing stages selected
explicitly. `prestage` prepares downloads/firmware previews, `patch` installs
without rebooting, and `full` includes reboot and verification. An acknowledgment
records that the application owner cleared a maintenance window; it is a human
decision, not something the automation can infer.

Reboot requires both an operator flag and a per-host allowlist. Window rules,
disk thresholds and firmware success codes are configuration rather than
universal assumptions. The application check catalog is empty by design:
onboarding supplies service names, task paths, endpoint expectations, freshness
thresholds and manual actions through inventory `group_vars`, not role edits.

Manual checks remain visibly manual. A functioning service or HTTP endpoint
cannot establish end-to-end application behavior on its own. Reports should
capture failures and incomplete checks, not imply success from a partial proxy.

## Before extending this work

Confirm network/listener/firewall access, update source and approved categories,
vendor tool flavor and exit codes, reboot policy, and each application check's
expected result. Survey output may contain host identity, network addresses,
user sessions and application configuration: keep it outside source control.

Complete the missing tasks and entry plays, then validate in an isolated lab.
Do not treat comments about intended safety or report behavior as proof that the
unfinished orchestration already implements it end to end.
