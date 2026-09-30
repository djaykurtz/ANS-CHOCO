# Configure a lab environment

The offline UI and report examples in [README.md](README.md) need no fleet access.
The steps below are for authorized execution against **your own isolated lab**.
All included domains, inventory hosts, cloud resource names, and documentation
IP addresses are examples. Do not point commands at an existing fleet by accident.

## 1. Linux control node

Use Python 3.12 and the Ansible reference versions in
[_requirements/TOOLING_VERSIONS.md](_requirements/TOOLING_VERSIONS.md).

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install ansible-core==2.16.14 pywinrm==0.5.0 -r requirements-dev.txt
ansible-galaxy collection install -r requirements.yml -p collections
export CHOCO_FLEET_DATA_ROOT="$PWD/.demo"
```

Ansible execution is not supported on a native Windows control node; use Linux
or WSL for that part. The UI and offline Python tools can run on Windows.
`ansible.cfg` prefers the repo-local, ignored `collections/` directory. The
optional `foremanS25.yml` needs `theforeman.foreman` and an independently
configured Foreman instance; it is not part of the quickstart.

## 2. Credentials and inventory

Copy the layout, replace example values locally, and encrypt the YAML before
connecting to any target:

```bash
cp -r vault.example vault
chmod 700 vault
chmod 600 vault/* vault/.vault_key.txt vault/.nexus_api_key
# Edit vault/.vault_key.txt and vault/corp-ans-secret.yml with your lab values.
ansible-vault encrypt vault/corp-ans-secret.yml \
  --vault-password-file=vault/.vault_key.txt
```

The files in `vault.example/` are plain, nonfunctional examples. Change the vault
password and credentials in `vault/`; never edit the public example with a real
credential. Domain join additionally needs the fields described in
[vault.example/README.md](vault.example/README.md).

Replace hosts in `inventory/TEST/inv-TEST-solo.yml` with your lab FQDN and make
the same change in command limits. Each inventory directory needs its **own**
adjacent `group_vars/basic_hosts.yml`. The included connection variables use
WinRM, HTTP, port 5985, and NTLM. Configure the listener, firewall, authentication,
and transport policy appropriate to your lab before running Ansible.

```bash
ansible -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  -e @vault/corp-ans-secret.yml \
  -l test-host-01.corp.example.com \
  basic_hosts -m ansible.windows.win_ping

ansible-playbook playbooks/chocoDeploy.yml \
  -i inventory/TEST/inv-TEST-solo.yml \
  --vault-password-file=vault/.vault_key.txt \
  --syntax-check
```

Use your lab host in `-l`. A `pong` proves connectivity, not software safety.
Review the deployment mode, catalog, removals, and runtime cleanup policy before
using the software-changing example in the root README.

## 3. Configuration surfaces

| Setting | Location | Purpose |
| --- | --- | --- |
| `CHOCO_FLEET_DATA_ROOT` | environment; `playbooks/group_vars/all.yml` | Campaign/report root; defaults to `/opt/ansible` |
| `CHOCO_FLEET_CAMPAIGN_STORE` | environment; Web UI only | Overrides the UI's inventory store; otherwise `<data-root>/incoming` |
| Connection variables | `inventory/*/group_vars/basic_hosts.yml` | Per-inventory WinRM settings |
| Credentials | ignored `vault/` | Vault key, WinRM vars, optional domain-join vars and Nexus push key |
| Version floors | `playbooks/roles/chocoDeploy/defaults/main.yml` | `acceptable_versions`, application selection, removal and runtime policy |
| Shared catalog | `playbooks/catalogs/chocolatey_packages.yml` | Package identities, acquisition and mirror metadata |
| Trusted source | `trusted_choco_source` in defaults or extra-vars | SMB/NuGet source; empty URL uses the public feed |
| Build specifications | `playbooks/roles/chocoBuild/files/*-spec.yml` | Package versions, installer URLs and integrity hashes |
| Build host | `inventory/Internalize/` and chocoBuild defaults | Mirror target and staging paths |
| Protected OUs | `playbooks/policies/target_exclusions.yml` | Exclusion policy used during CSV inventory creation |
| Domain join | `playbooks/roles/domJoin/tasks/` | Legacy helpers requiring domain, OU and credential review |
| NXLog | `playbooks/roles/chocoDeploy/files/nxlog.conf` | Example log destination and TLS policy |
| Key Vault | `playbooks/roles/getAzKVSecret/defaults/main.yml` | Optional subscription/vault values; not integrated into fleet playbooks |

For campaign inventories, collect a fresh AD export using
`playbooks/tools/export_protected_ad_objects.ps1` and run `csv_to_inventory.py`
with your CSV, `--ad-export`, and `--campaign-id`. Review warnings, excluded
targets, and hosts absent from the export. These tools write operational data;
keep their output outside the repository. UI inventory saves do not enforce OU
exclusion.

## 4. Optional Azure DevOps / Arc samples

`.azure-pipelines/` contains manual examples, not configured infrastructure.
The lint sample runs offline tests and catalog validation.
Promotion requires an Azure DevOps `dev` and `main` branch, a permitted
`System.AccessToken`, and appropriate branch policy. Deploy requires a service
connection, Arc-enabled control node, Az modules, and a provisioned external
`Pull-AnsibleRepo.ps1`. Set its resource group, node name, location, checkout
path, and collection installation policy yourself. No deployment occurs from
the GitHub validation workflow.

Vault seeding scripts under `misc/` additionally require authorized Azure CLI
access and SSH write access to the chosen lab checkout. Review their parameters
and example account/cloud names before use. Secret retrieval suppresses task
logging; retrieval does not replace the playbooks' file-vault workflow.

## 5. Verify configuration

```bash
python -m unittest discover -s playbooks/tools/tests -p 'test_*.py'
python playbooks/tools/validate_catalog.py
```

Treat mirror warnings as coverage gaps to resolve before selecting an internal
source. Validate actual package availability and integrity in your lab; the
offline validator cannot establish either.
