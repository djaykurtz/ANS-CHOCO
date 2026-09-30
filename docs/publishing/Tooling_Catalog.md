# ANS-CHOCO tooling catalog

Package preparation, target preparation, deployment and reporting are separate
responsibilities. [The root README](../../README.md) distinguishes executable
paths from incomplete work and includes local examples.

| Tool | Implemented responsibility | Source / reference |
| --- | --- | --- |
| chocoDeploy | Vendor-to-Chocolatey conversion, version-floor alignment, selected installs, runtime policy and per-host evidence | [Playbook](../../playbooks/chocoDeploy.yml), [guide](../deploy/chocoDeploy_Guide.md) |
| chocoBuild | Community internalization, checksum-verified wrappers and on-target extract/repack/install iteration; standalone signing and other planned actions remain stubs | [Playbook](../../playbooks/chocoBuild.yml), [guide](../build/chocoBuild_Guide.md) |
| csv_to_inventory | Deduplicate a host CSV, exclude protected AD OUs, optionally probe DNS/WinRM, write a campaign inventory | [Tool](../../playbooks/tools/csv_to_inventory.py) |
| patchReady | Reachability, disk/reboot/Chocolatey checks and readiness HTML; also archives older target logs | [Playbook](../../playbooks/patchReady.yml), [reporting](../reporting/Reporting_Guide.md) |
| fleet_summary | Combine per-host JSON with retry resolution and reboot advisories; write fleet HTML and optional JSON/text | [Tool](../../playbooks/roles/chocoDeploy/files/fleet_summary.py), [reporting](../reporting/Reporting_Guide.md) |
| softwareUsage | Read Security 4688 events for recent application usage; output may include private user/command-line data | [Playbook](../../playbooks/softwareUsage.yml), [reporting](../reporting/Reporting_Guide.md) |

These relative source links work in the repository. For the Pages showcase,
use its source-evidence links into GitHub; only `docs/` is deployed there.
