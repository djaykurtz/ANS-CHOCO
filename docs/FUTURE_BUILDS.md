# Future work and implementation boundaries

This is a technical backlog, not a record of a deployed environment.
Items below are not claims of working integrations.

## 1. Package-source migration and coverage

An SMB mirror and a NuGet-compatible Nexus source are supported configuration
choices. Before changing sources, compare actual package versions and SHA-256
hashes, confirm repository capacity/upload limits, then test each approved
version on an isolated host. A bundled internalized package is not necessarily
identical to the smaller community package that downloads a vendor installer.

The shared catalog and `internalize-spec.yml` describe intended mirror coverage;
they do not query a live repository. `validate_catalog.py` currently warns about
the Docker Desktop floor missing from `mirror_versions` and the Java runtime
mirror version missing from the internalization spec. Resolve those gaps before
relying on either source for those versions.

`nexus_ingest.py` has a dry-run path and optional installer substitution, but
real ingestion needs authorized credentials and a configured destination.
External manifests and infrastructure are not supplied here.

## 2. Deployment dependency reconciliation

The Arc deployment example invokes an external `Pull-AnsibleRepo.ps1`; the
script is not included. A real implementation should apply reviewed source
changes and install the pinned collections into the checkout:

```bash
ansible-galaxy collection install -r requirements.yml -p collections
```

Verify that `ansible.cfg` resolves the intended collection set. Do not rely on
whatever happens to be installed system-wide.

## 3. Full Azure Key Vault integration

`getAzKVSecret` retrieves through `pwsh`, Az modules and managed identity, and
sets `keyVaultSecretValue`. Its task output is suppressed and the example checks
presence without displaying a value.

Fleet playbooks still use `vars_files` from ignored `vault/`. Runtime integration
would need explicit identity permissions, consistent secret names, playbook
credential propagation, an ad-hoc-command equivalent, UI/ingestion updates, and
lab validation. Do not remove the file-vault workflow before that path exists.

## 4. Build and maintenance completion

First-party authoring, package-family classification, and standalone build
extract/repack/sign/verify actions remain fail-fast stubs. Community and wrapper
paths and on-target iteration are separate implemented paths.

`sysPatch` still needs verification/report tasks, its HTML template, a runnable
entry playbook and lab validation. `winUpdate` needs a standalone entry playbook.
See [sysPatch design](maintenance/sysPatch_Design.md).

## 5. Orchestration and recovery

Azure Automation/Semaphore integration and automatic remediation inventories are
design options, not implemented execution layers. Keep human authorization,
target-policy review, evidence retention, and explicit reboot policy in any
future scheduler integration.
