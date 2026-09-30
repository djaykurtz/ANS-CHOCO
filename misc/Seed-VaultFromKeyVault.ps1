# Rebuild the file-based Ansible vault on the control node from Azure Key Vault.
# Run from any Windows machine with `az login` done and read access to the Key
# Vault. Secrets travel over the SSH session's stdin only, never on a command
# line, and the previous files are backed up to vault/backup/ first.
#   .\misc\Seed-VaultFromKeyVault.ps1 -NodeUser <checkout owner>   # writes /opt/ansible/repos/choco-fleet/vault
#   .\misc\Seed-VaultFromKeyVault.ps1 -NodeUser <user> -RemoteRepoDir <path>   # another checkout
param(
    [string]$AnsibleNode = "ansible-ctl-01.example.com",
    [string]$NodeUser = $env:USERNAME,
    # Checkout path on the node, relative to the remote home unless absolute.
    [string]$RemoteRepoDir = "/opt/ansible/repos/choco-fleet"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$KeyVaultName = "kv-example-ansible"
$SecretName = "winrm-service-account"
$AnsVaultName = "ansible-vault-key"

# Single quotes keep $HOME for the remote shell to expand.
$VaultDirectory = if ($RemoteRepoDir.StartsWith('/')) { "$RemoteRepoDir/vault" } else { '$HOME/' + $RemoteRepoDir + '/vault' }
$SecretsFilePath = "$VaultDirectory/corp-ans-secret.yml"
$VaultPasswordFile = "$VaultDirectory/.vault_key.txt"

function Get-KeyVaultSecretValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $value = & az keyvault secret show `
        --vault-name $KeyVaultName `
        --name $Name `
        --query value `
        --output tsv `
        --only-show-errors 2>$null

    if ($LASTEXITCODE -ne 0 -or $null -eq $value) {
        throw "Unable to read Key Vault secret '$Name' from '$KeyVaultName'."
    }

    return ($value -join "`n").TrimEnd("`r", "`n")
}

function Invoke-NodeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$StandardInput
    )

    # The script travels base64-encoded and runs under bash whatever the login
    # shell is; stdin stays free for the secrets. SSH may prompt for your password.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    $remote = 'bash -c "$(printf %s ' + $encoded + ' | base64 -d)"'

    $StandardInput | & ssh "$NodeUser@$AnsibleNode" $remote

    if ($LASTEXITCODE -ne 0) {
        throw "Vault rebuild on $AnsibleNode failed."
    }
}

$remoteScript = @'
set -euo pipefail
umask 077
ts=$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 700 "__VAULT_DIR__"
backup_dir="__VAULT_DIR__/backup"
install -d -m 700 "$backup_dir"
[ -f "__VAULTKEY_PATH__" ] && cp "__VAULTKEY_PATH__" "$backup_dir/.vault_key.txt.$ts.bak" || true
[ -f "__SECRETS_PATH__" ] && cp "__SECRETS_PATH__" "$backup_dir/corp-ans-secret.yml.$ts.bak" || true
chmod 600 "$backup_dir"/*.bak 2>/dev/null || true
read -r new_vault_key
read -r new_user
read -r new_pass
printf '%s\n' "$new_vault_key" > "__VAULTKEY_PATH__"
chmod 600 "__VAULTKEY_PATH__"
printf "ansible_user: '%s'\nansible_password: '%s'\n" "$new_user" "$new_pass" > "__SECRETS_PATH__"
ansible-vault encrypt "__SECRETS_PATH__" --vault-password-file "__VAULTKEY_PATH__"
chmod 600 "__SECRETS_PATH__"
echo "REBUILD_OK ts=$ts backup=$backup_dir"
'@
$remoteScript = $remoteScript.Replace('__VAULT_DIR__', $VaultDirectory)
$remoteScript = $remoteScript.Replace('__VAULTKEY_PATH__', $VaultPasswordFile)
$remoteScript = $remoteScript.Replace('__SECRETS_PATH__', $SecretsFilePath)

$secret = $null
$vaultKey = $null
$payload = $null

try {
    $secret = Get-KeyVaultSecretValue -Name $SecretName
    $vaultKey = Get-KeyVaultSecretValue -Name $AnsVaultName
    $escapedSecret = $secret.Replace("'", "''")
    $payload = "$vaultKey`n" + "CORP\svc-ansible`n" + "$escapedSecret`n"

    Invoke-NodeCommand -StandardInput $payload -Command $remoteScript
}
finally {
    $secret = $null
    $vaultKey = $null
    $payload = $null
}
