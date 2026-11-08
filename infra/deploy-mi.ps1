<#
.SYNOPSIS
    Provisions the Azure SQL Managed Instance subscriber (network + instance) with one command.

.DESCRIPTION
    Creates: resource group, NSG (with an inbound rule for the public data endpoint, port 3342,
    from your IP only), route table, VNet, subnet delegated to Microsoft.Sql/managedInstances,
    then a General Purpose Gen5 4-vCore MI with the public data endpoint enabled.
    Runs with --no-wait: provisioning continues in Azure while you build the on-prem tier.

.EXAMPLE
    ./infra/deploy-mi.ps1 -MiName replab-mi-louis
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$MiName,              # globally unique, lowercase
    [string]$ResourceGroup = 'rg-replab',
    [string]$Location      = 'eastus2',
    [string]$AdminUser     = 'repladmin',
    [string]$ClientIp,                                   # defaults to your current public IP
    [string]$VnetPrefix    = '10.50.0.0/16',
    [string]$SubnetPrefix  = '10.50.0.0/24'
)
$ErrorActionPreference = 'Stop'

function Invoke-Az { az @args; if ($LASTEXITCODE) { throw "az $($args -join ' ') failed" } }

if (-not $ClientIp) { $ClientIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim() }
$adminPwd = Read-Host -AsSecureString -Prompt "MI admin password for '$AdminUser'"
$adminPwdPlain = [System.Net.NetworkCredential]::new('', $adminPwd).Password

$nsg = "$MiName-nsg"; $rt = "$MiName-rt"; $vnet = "$MiName-vnet"; $subnet = 'mi-subnet'

Write-Host "Resource group $ResourceGroup ($Location)"
Invoke-Az group create -n $ResourceGroup -l $Location --output none

Write-Host 'NSG + public endpoint rule (3342 from your IP only)'
Invoke-Az network nsg create -g $ResourceGroup -n $nsg -l $Location --output none
Invoke-Az network nsg rule create -g $ResourceGroup --nsg-name $nsg -n allow-mi-public-endpoint-from-lab `
    --priority 1000 --direction Inbound --access Allow --protocol Tcp `
    --source-address-prefixes $ClientIp --destination-port-ranges 3342 --output none

Write-Host 'Route table, VNet, delegated subnet'
Invoke-Az network route-table create -g $ResourceGroup -n $rt -l $Location --output none
Invoke-Az network vnet create -g $ResourceGroup -n $vnet -l $Location --address-prefixes $VnetPrefix --output none
Invoke-Az network vnet subnet create -g $ResourceGroup --vnet-name $vnet -n $subnet `
    --address-prefixes $SubnetPrefix --delegations Microsoft.Sql/managedInstances `
    --network-security-group $nsg --route-table $rt --output none
$subnetId = az network vnet subnet show -g $ResourceGroup --vnet-name $vnet -n $subnet --query id -o tsv

Write-Host "Creating Managed Instance $MiName (no-wait)"
Invoke-Az sql mi create -g $ResourceGroup -n $MiName -l $Location `
    --admin-user $AdminUser --admin-password $adminPwdPlain `
    --subnet $subnetId --tier GeneralPurpose --family Gen5 --capacity 4 --storage 32GB `
    --license-type LicenseIncluded --public-data-endpoint-enabled true `
    --backup-storage-redundancy Local --no-wait --output none

Write-Host ''
Write-Host 'Provisioning started. Check progress with:' -ForegroundColor Green
Write-Host "  ./infra/mi-power.ps1 -Action Status -MiName $MiName -ResourceGroup $ResourceGroup"
Write-Host 'When it reports Ready, the subscriber name for build-lab.ps1 is the public endpoint:'
Write-Host "  az sql mi show -g $ResourceGroup -n $MiName --query fullyQualifiedDomainName -o tsv"
Write-Host '  -> insert ".public" after the instance name and append ",3342"'
