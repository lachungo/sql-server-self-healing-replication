<#
.SYNOPSIS
    One command tears the lab down: drops the subscriber database on the Managed Instance
    (if configured) and removes the containers and their volumes.
    The Managed Instance itself is left alone: stop it with ./infra/mi-power.ps1 -Action Stop
    or delete it with -Action Remove.
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$KeepVolumes)
. "$PSScriptRoot/scripts/common.ps1"
Initialize-LabSession

$mi = $Lab.Subscribers | Where-Object Tier -eq 'cloud'
if ($mi -and $PSCmdlet.ShouldProcess($mi.Name, "Drop database $($mi.Db)")) {
    Write-Step "Dropping $($mi.Db) on the Managed Instance"
    try {
        Invoke-LabSql -SqlInstance $mi.Host -Credential (Get-SubscriberCredential $mi) -Query @"
IF DB_ID(N'$($mi.Db)') IS NOT NULL DROP DATABASE [$($mi.Db)];   -- subscription metadata lives in this database
"@ -Database 'master'
    } catch { Write-Warning "MI cleanup skipped: $($_.Exception.Message)" }
}

if ($PSCmdlet.ShouldProcess('replab containers', 'docker compose down')) {
    Write-Step 'Removing containers'
    Push-Location $PSScriptRoot
    try {
        if ($KeepVolumes) { docker compose --env-file .env down } else { docker compose --env-file .env down -v }
    } finally { Pop-Location }
}
Write-Host 'Lab removed.' -ForegroundColor Green
