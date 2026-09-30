<#
.SYNOPSIS and DESCRIPTION
    Used in the Deploy-ChocoFleet pipeline for continuous deployment of the production and dev Windows Ansible repo (choco-fleet).
    
    This PowerShell script should not be executed outside of the typical pipeline flow.

    Requires windows:latest, powershell, and the Az module.

.NOTES
    Manual Azure DevOps / Azure Arc sample. Configure the environment before use.
#>

function throwError {
   param (
      [Parameter(Mandatory=$true)]
      [string]$errorMsg
   )
    
    Write-Error $error[0]
    throw $errorMsg
}

<#region CONNECT TO AZURE
Try {
    Connect-AzAccount -Identity -Subscription '00000000-0000-0000-0000-000000000000' -ErrorAction Stop
}Catch {
    throwError "Failed to connect to Azure. Exiting..."
}
#>

#region EXEC DEPLOYMENT
$resourceGroupName = "rg-arc-example"
$ansibleControlNode = "ansible-ctl-01"
$location = "westus2"
$runCommandName = "Update-ChocoFleet"
Try {
    New-AzConnectedMachineRunCommand -ResourceGroupName $resourceGroupName -MachineName $ansibleControlNode -Location $location -RunCommandName $runCommandName -SourceScript "HOME=/root pwsh --File '/opt/ansible/tools/Pull-AnsibleRepo.ps1'"
}Catch {
    throwError "Failed to execute remote deployment script. Exiting..."
}
#endregion