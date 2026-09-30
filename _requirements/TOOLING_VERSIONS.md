# Tooling reference

These are reference versions for a Linux lab control node, not an inventory of
a running machine. Validate compatibility in your own lab before changing pins.
Application version floors live separately in
[chocoDeploy defaults](../playbooks/roles/chocoDeploy/defaults/main.yml).

| Component | Reference | Use |
| --- | --- | --- |
| Linux | Rocky Linux 9.4 or a compatible Linux environment | Ansible execution |
| Python | 3.12 | Operational scripts and Linux launch commands |
| ansible-core | 2.16.14 | Playbook execution |
| PyYAML | 6.0.2 | Catalog, campaign, and inventory tooling/tests |
| pywinrm | 0.5.0 | WinRM connection |
| Az.Accounts | 5.5.2 | Optional Azure managed-identity retrieval |
| Az.KeyVault | 6.6.0 | Optional Key Vault retrieval |
| PowerShell | `pwsh` on Linux for Key Vault; Windows PowerShell on targets | Cloud helpers and Windows scripts |

The UI/offline report preview works with Python 3.10+ and the standard library.
The existing Python test suite additionally requires PyYAML, declared in
[requirements-dev.txt](../requirements-dev.txt).

## Ansible collections

[requirements.yml](../requirements.yml) pins the collection set:

| Collection | Version |
| --- | --- |
| `ansible.windows` | 3.1.0 |
| `community.windows` | 3.0.0 |
| `chocolatey.chocolatey` | 1.5.1 |
| `microsoft.ad` | 1.12.1 |
| `ansible.posix` | 1.5.4 |

```bash
ansible-galaxy collection install -r requirements.yml -p collections
```

`ansible.cfg` gives the ignored repo-local collection directory precedence.
The optional Foreman playbook uses an additional `theforeman.foreman` collection
and separately configured service; it is not included in this pinned set.

## Check your environment

```bash
python3.12 --version
ansible --version
ansible-galaxy collection list -p collections
python3.12 -c "import yaml, winrm; print('Python dependencies available')"
```

Use the root README's offline checks before configuring lab credentials.
See [CONFIGURE.md](../CONFIGURE.md) for installation and target setup.
