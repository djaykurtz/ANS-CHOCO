# Credential layout examples

All values here are explicit, plain-text **nonfunctional examples**. They are
not encrypted deployment credentials and must not be used to authenticate.

| File | Expected fields or purpose |
| --- | --- |
| `.vault_key.txt` | Local vault encryption password; replace in your private copy |
| `corp-ans-secret.yml` | `ansible_user`, `ansible_password` for WinRM |
| `domJoin-secret.yml` | `sys_adm`, `sys_adm_pass`, `dom_adm`, `dom_adm_pass` |
| `.nexus_api_key` | Optional Nexus push key |

Copy the layout to the source-control-ignored `vault/`, edit the **private copy**
with your authorized lab values, and encrypt its YAML files before using it:

```bash
cp -r vault.example vault
chmod 700 vault
chmod 600 vault/* vault/.vault_key.txt vault/.nexus_api_key
# Edit private vault values and choose a new vault password first.
ansible-vault encrypt vault/corp-ans-secret.yml vault/domJoin-secret.yml \
  --vault-password-file=vault/.vault_key.txt
```

Never put real credentials in this directory. Keep vault keys and backups
restricted, out of shared logs, and out of source control. See
[CONFIGURE.md](../CONFIGURE.md).
