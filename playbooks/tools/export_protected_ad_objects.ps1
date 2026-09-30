# Export AD evidence for playbooks/tools/csv_to_inventory.py.
# Always exports every object below the two protected OUs. With -HostListPath it
# also looks up each listed computer, so the inventory report shows where every
# host lives in AD (and which hosts AD does not know).
# Run on a Windows host with the ActiveDirectory module:
#   .\playbooks\tools\export_protected_ad_objects.ps1 -OutputPath .\ad-protected-objects.json
#   .\playbooks\tools\export_protected_ad_objects.ps1 -OutputPath .\ad-protected-objects.json -HostListPath .\campaign_001.csv
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    # CSV with a DeviceName/Hostname/Host/ComputerName/Name column, or a plain list.
    [string]$HostListPath
)

$searchBases = @(
    "OU=Restricted,OU=Services,OU=Lab,OU=CloudSync,OU=Managed,DC=corp,DC=example,DC=com",
    "OU=Restricted,OU=Services,OU=Lab,OU=LocalOnly,OU=Managed,DC=corp,DC=example,DC=com"
)

$objects = @(foreach ($searchBase in $searchBases) {
    Get-ADObject -SearchBase $searchBase -Filter * -Properties cn, distinguishedName |
        Select-Object cn, distinguishedName
})
$protectedCount = $objects.Count

if ($HostListPath) {
    $names = if ($HostListPath -match '\.csv$') {
        $rows = Import-Csv -Path $HostListPath
        $column = @('DeviceName', 'Hostname', 'Host', 'ComputerName', 'Computer', 'Name') |
            Where-Object { $rows.Count -and $rows[0].PSObject.Properties.Name -contains $_ } |
            Select-Object -First 1
        if (-not $column) { throw "No host column found in $HostListPath" }
        $rows | ForEach-Object { $_.$column }
    } else {
        Get-Content -Path $HostListPath
    }
    $short = $names | Where-Object { $_ -and $_.Trim() } |
        ForEach-Object { ($_.Trim().Split('.')[0].ToLower()) -replace '[^a-z0-9-]', '' } |
        Where-Object { $_ } | Sort-Object -Unique
    $known = @{}
    foreach ($o in $objects) { $known[$o.distinguishedName] = $true }
    $missing = 0
    foreach ($name in $short) {
        $computer = Get-ADComputer -Filter "Name -eq '$name'" -Properties cn, distinguishedName
        if ($computer) {
            foreach ($c in @($computer)) {
                if (-not $known.ContainsKey($c.distinguishedName)) {
                    $objects += [pscustomobject]@{ cn = $c.cn; distinguishedName = $c.distinguishedName }
                    $known[$c.distinguishedName] = $true
                }
            }
        } else {
            $missing++
        }
    }
    Write-Host "Looked up $($short.Count) listed hosts; $missing not found in AD"
}

$json = ConvertTo-Json -InputObject $objects -Depth 3
Set-Content -Path $OutputPath -Value $json -Encoding UTF8

Write-Host "Wrote $($objects.Count) AD objects ($protectedCount below protected OUs) to $OutputPath"
