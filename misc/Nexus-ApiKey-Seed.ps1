# Seed the Nexus choco-repo API key from Azure Key Vault into vault/.nexus_api_key
# on the control node. Same pattern as Seed-VaultFromKeyVault.ps1: backup before
# overwrite, and the key travels over the SSH session's stdin only (never a
# command-line argument, shell history entry, or ps listing on either host).
# Needs an Az PowerShell session with read access to the kv-example-admin Key Vault.
#   .\misc\Nexus-ApiKey-Seed.ps1 -NodeUser <checkout owner> [-RemoteRepoDir /opt/ansible/repos/choco-fleet]
param(
    [string]$AnsibleNode = "ansible-ctl-01.example.com",
    [string]$NodeUser = $env:USERNAME,
    # Checkout path on the node, relative to the remote home unless absolute.
    [string]$RemoteRepoDir = "/opt/ansible/repos/choco-fleet"
)

$KeyVaultName = "kv-example-admin"
$SecretName = "nexus-api-key"

# Single quotes keep $HOME for the remote shell to expand.
$VaultDirectory = if ($RemoteRepoDir.StartsWith('/')) { "$RemoteRepoDir/vault" } else { '$HOME/' + $RemoteRepoDir + '/vault' }
$KeyFilePath = "$VaultDirectory/.nexus_api_key"

$apiKey = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName -AsPlainText

$remoteScript = @'
set -euo pipefail
umask 077
ts=$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 700 "__VAULT_DIR__"
backup_dir="__VAULT_DIR__/backup"
mkdir -p "$backup_dir"
[ -f "__KEYFILE_PATH__" ] && cp "__KEYFILE_PATH__" "$backup_dir/.nexus_api_key.$ts.bak" || true
chmod 600 "$backup_dir"/*.bak 2>/dev/null || true
read -r new_key
printf '%s' "$new_key" > "__KEYFILE_PATH__"
chmod 600 "__KEYFILE_PATH__"
echo "REBUILD_OK ts=$ts backup=$backup_dir"
'@
$remoteScript = $remoteScript.Replace('__VAULT_DIR__', $VaultDirectory)
$remoteScript = $remoteScript.Replace('__KEYFILE_PATH__', $KeyFilePath)

# Base64 so the script runs under bash whatever the login shell is.
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
$apiKey | ssh "$NodeUser@$AnsibleNode" ('bash -c "$(printf %s ' + $encoded + ' | base64 -d)"')

$apiKey = $null

# Confirm on the node: stat -c '%a %U' ~/choco-fleet/vault/.nexus_api_key   # expect: 600 <you>
