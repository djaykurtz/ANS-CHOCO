# ANS-CHOCO documentation

The [static architecture showcase](index.html) provides the visual overview.

Central index for all repository documentation. The repo root
[README.md](../README.md) is the project landing page; everything below is the
detailed reference.

## Access & hosting
- [access/Environment_Access.md](access/Environment_Access.md) - how to reach `ansible-ctl-01`, how the Azure DevOps/Arc deploy path works, and where every credential lives / how to obtain it with auth
- [ans-choco-demo/Demo_Walkthrough.md](ans-choco-demo/Demo_Walkthrough.md) - six steps on the TEST host: one patch cycle and one version-floor update

## Publishing
- [publishing/Tooling_Catalog.md](publishing/Tooling_Catalog.md) - external-facing catalog of the tooling we have built, written in the publishing style format

## Orchestration and platforms
- [orchestration/Automation_Arc_Semaphore.md](orchestration/Automation_Arc_Semaphore.md) - what Azure Automation, Azure Arc, and Semaphore should and could be used for, how they integrate with Ansible, and where third-party application patching stays with this repo

## Deploy (software alignment)
- [deploy/chocoDeploy_Guide.md](deploy/chocoDeploy_Guide.md) - full reference for the chocoDeploy role
- [deploy/chocoDeploy_QuickRef.md](deploy/chocoDeploy_QuickRef.md) - command cheat sheet for chocoDeploy
- [../playbooks/catalogs/chocolatey_packages.yml](../playbooks/catalogs/chocolatey_packages.yml) - shared package identity, approved versions, acquisition, and mirror metadata
- [../campaigns/template.yml](../campaigns/template.yml) - campaign, phase, wave, and run manifest template

## Build (package authoring)
- [build/chocoBuild_Guide.md](build/chocoBuild_Guide.md) - full reference for the chocoBuild role
- [build/chocoBuild_QuickRef.md](build/chocoBuild_QuickRef.md) - command reference for chocoBuild
- [build/INTERNALIZE_FAMILIES.md](build/INTERNALIZE_FAMILIES.md) - package family classification

## Reporting
- [reporting/Reporting_Guide.md](reporting/Reporting_Guide.md) - how the readiness, post-patch, fleet, and usage reports are built
- [reporting/Reporting_QuickRef.md](reporting/Reporting_QuickRef.md) - report command reference

## Maintenance windows (in development)
- [maintenance/sysPatch_Design.md](maintenance/sysPatch_Design.md) - design and missing implementation pieces for sysPatch/winUpdate; not an end-to-end runnable workflow.

## Troubleshooting
- [troubleshooting/WinRM_Fixes.md](troubleshooting/WinRM_Fixes.md) - WinRM error-signature triage, double-hop-safe relay diagnostics, and remote fixes/workarounds

## Backlog
- [FUTURE_BUILDS.md](FUTURE_BUILDS.md) - agreed build work not yet done (starting with the SMB-to-Nexus migration)

## Folder-local notes (kept next to their code)
- [playbooks/roles/chocoBuild/README.md](../playbooks/roles/chocoBuild/README.md)
- [webui/README.md](../webui/README.md)
