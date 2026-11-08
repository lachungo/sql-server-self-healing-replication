<#
.SYNOPSIS
    Status / Start / Stop / Remove for the lab Managed Instance.
    Stop it at the end of every session: compute billing stops, the instance and network stay.

.EXAMPLE
    ./infra/mi-power.ps1 -Action Stop -MiName replab-mi-louis
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateSet('Status', 'Start', 'Stop', 'Remove')] [string]$Action,
    [Parameter(Mandatory)] [string]$MiName,
    [string]$ResourceGroup = 'rg-replab'
)
$ErrorActionPreference = 'Stop'

switch ($Action) {
    'Status' {
        az sql mi show -g $ResourceGroup -n $MiName --query '{state:state, fqdn:fullyQualifiedDomainName, publicEndpoint:publicDataEndpointEnabled, vCores:vCores}' -o table
    }
    'Start' {
        Write-Host "Starting $MiName (several minutes)..."
        az sql mi start -g $ResourceGroup --mi $MiName
    }
    'Stop' {
        Write-Host "Stopping $MiName (compute billing stops once it reports Stopped)..."
        az sql mi stop -g $ResourceGroup --mi $MiName
    }
    'Remove' {
        if ($PSCmdlet.ShouldProcess($ResourceGroup, 'Delete the resource group, the Managed Instance and its network (cannot be undone)')) {
            az group delete -n $ResourceGroup --yes --no-wait
            Write-Host "Deletion of $ResourceGroup started."
        }
    }
}
if ($LASTEXITCODE) { throw "az exited with code $LASTEXITCODE" }
