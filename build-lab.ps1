<#
.SYNOPSIS
    One command builds the whole lab: containers, distributor, publication, push subscriptions
    (2 on-prem + Azure SQL Managed Instance when MI_SUBSCRIBER is set in .env), and ReplMon.

.EXAMPLE
    ./build-lab.ps1                    # everything configured in .env
    ./build-lab.ps1 -SkipMI            # on-prem tier only
    ./build-lab.ps1 -LatencySloSec 15
#>
[CmdletBinding()]
param(
    [switch]$SkipMI,
    [int]$LatencySloSec = 30,
    [int]$SyncTimeoutMin = 15
)
. "$PSScriptRoot/scripts/common.ps1"
$sw = [Diagnostics.Stopwatch]::StartNew()
Initialize-LabSession
if ($SkipMI) { $Lab.Subscribers = @($Lab.Subscribers | Where-Object Tier -ne 'cloud') }
$pub = $Lab.PublisherHost

Write-Step 'Containers'
Push-Location $PSScriptRoot
try { docker compose --env-file .env up -d; if ($LASTEXITCODE) { throw 'docker compose up failed' } }
finally { Pop-Location }
Wait-LabInstance $pub -RequireAgent
foreach ($s in $Lab.Subscribers) { Wait-LabInstance $s.Host -Credential (Get-SubscriberCredential $s) }
docker exec sqlpub mkdir -p $Lab.SnapshotDir
if ($LASTEXITCODE) { throw 'Could not create the snapshot folder in sqlpub' }

Write-Step 'Publisher database and workload'
Invoke-LabSqlFile $pub 'sql/01-demo-db.sql'

Write-Step 'Subscriber databases'
foreach ($s in $Lab.Subscribers) {
    Invoke-LabSql -SqlInstance $s.Host -Credential (Get-SubscriberCredential $s) `
        -Query "IF DB_ID(N'$($s.Db)') IS NULL CREATE DATABASE [$($s.Db)];"
    Write-Host "  $($s.Name) -> $($s.Db) [$($s.Tier)]"
}

Write-Step 'Distributor'
Invoke-LabSqlFile $pub 'sql/02-distribution.sql' @{
    DIST_PWD = $LabEnv.DIST_ADMIN_PASSWORD; SA_PWD = $LabEnv.SA_PASSWORD; SNAPSHOT_DIR = $Lab.SnapshotDir }

Write-Step 'Publication'
Invoke-LabSqlFile $pub 'sql/03-publication.sql' @{ SA_PWD = $LabEnv.SA_PASSWORD }

Write-Step 'Push subscriptions'
foreach ($s in $Lab.Subscribers) {
    $cred = Get-SubscriberCredential $s
    Invoke-LabSqlFile $pub 'sql/04-subscription.sql' @{
        SUBSCRIBER = $s.Name; SUB_DB = $s.Db
        SUB_LOGIN = $cred.UserName; SUB_PWD = $cred.GetNetworkCredential().Password }
}

Write-Step 'Snapshot'
Invoke-LabSql -SqlInstance $pub -Database $Lab.PublisherDb `
    -Query "EXEC sys.sp_startpublication_snapshot @publication = N'$($Lab.Publication)';"

Write-Step 'ReplMon framework'
Invoke-LabSqlFile $pub 'sql/10-replmon.sql' @{
    PUBLISHER_DB = $Lab.PublisherDb; PUBLICATION = $Lab.Publication; LATENCY_SLO_SEC = $LatencySloSec }
foreach ($s in $Lab.Subscribers) {
    $cred = Get-SubscriberCredential $s
    # The linked server lives on sqlpub, so the replication name is also the network name:
    # container hostname on-prem, public endpoint for MI.
    Invoke-LabSqlFile $pub 'sql/11-register-subscriber.sql' @{
        LS_NAME = $s.LinkedServer; DATASRC = $s.Name; SUB_LOGIN = $cred.UserName
        SUB_PWD = $cred.GetNetworkCredential().Password; SUBSCRIBER = $s.Name; SUB_DB = $s.Db; TIER = $s.Tier }
}

Write-Step 'Waiting for initial sync (tracer-token barrier per subscriber)'
$deadline = (Get-Date).AddMinutes($SyncTimeoutMin)
foreach ($s in $Lab.Subscribers) {
    do {
        try {
            $r = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -QueryTimeout 300 -Query @"
SET ANSI_NULLS ON; SET ANSI_WARNINGS ON;
DECLARE @a bit; EXEC dbo.usp_WaitForBarrier @SubscriberName = @sub, @Arrived = @a OUTPUT; SELECT @a AS Arrived;
"@ -SqlParameter @{ sub = $s.Name }
        } catch {
            # tracer tokens need an active subscription; until the snapshot is applied, posting fails
            $r = [pscustomobject]@{ Arrived = $false }; Start-Sleep -Seconds 10
        }
        if (-not $r.Arrived) { Write-Host "  $($s.Name): snapshot still applying..." -ForegroundColor DarkGray }
    } until ($r.Arrived -or (Get-Date) -gt $deadline)
    if (-not $r.Arrived) { throw "$($s.Name) did not sync within $SyncTimeoutMin minutes. Check Replication Monitor / MSdistribution_history." }
    Write-Host "  $($s.Name): in sync" -ForegroundColor Green
}

Write-Step 'Enabling ReplMon jobs'
Invoke-LabSql -SqlInstance $pub -Database 'msdb' -Query @"
UPDATE ReplMon.dbo.Subscriber SET RegisteredAt = GETDATE();
DECLARE @n sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM msdb.dbo.sysjobs WHERE name LIKE N'ReplMon - %';
OPEN c; FETCH NEXT FROM c INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC msdb.dbo.sp_update_job @job_name = @n, @enabled = 1; FETCH NEXT FROM c INTO @n; END
CLOSE c; DEALLOCATE c;
"@

$sw.Stop()
Write-Host "`nLab built in $([int]$sw.Elapsed.TotalMinutes) min $($sw.Elapsed.Seconds) s." -ForegroundColor Green
Write-Host 'Next: let latency collect for 15+ minutes, then ./chaos/Invoke-ChaosTest.ps1 -Scenario All'
