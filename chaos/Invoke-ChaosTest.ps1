<#
.SYNOPSIS
    Breaks replication on purpose, then measures how long ReplMon takes to detect, repair and recover.
    The runner only injects faults and watches. Detection and repair are done by the scheduled
    ReplMon jobs on the publisher, exactly as they would be at 3 a.m.
    Every run is recorded in ReplMon.dbo.ChaosRun when it is injected, so failed runs are kept
    too, and the resilience report scores each run against ReplMon.dbo.ChaosTarget.

.SCENARIOS
    AgentStopped - stop the subscriber's Distribution Agent job
    RowNotFound  - delete a row at the subscriber, then update it at the publisher -> error 20598
    DuplicateKey - a stray subscriber row holds a SKU that a new publisher row needs -> error 2627
    SilentDrift  - change a row directly at the subscriber: no replication error is ever raised
                   (recorded as SilentDriftScheduled unless -TriggerDriftNow is used)

.EXAMPLE
    ./chaos/Invoke-ChaosTest.ps1 -Scenario All -TriggerDriftNow
    ./chaos/Invoke-ChaosTest.ps1 -Scenario DuplicateKey -Subscriber sqlsub1
#>
[CmdletBinding()]
param(
    [ValidateSet('AgentStopped', 'RowNotFound', 'DuplicateKey', 'SilentDrift', 'All')] [string]$Scenario = 'All',
    [string]$Subscriber,                 # default: a sensible subscriber per scenario
    [switch]$TriggerDriftNow,            # start the drift job immediately instead of waiting for its schedule
    [int]$TimeoutMin = 12
)
. "$PSScriptRoot/../scripts/common.ps1"
Initialize-LabSession
$pub = $Lab.PublisherHost
$script:CurrentRun = $null

function Get-ServerNow { (Invoke-LabSql -SqlInstance $pub -Query 'SELECT GETDATE() AS Now').Now }
function Get-Sub([string]$Name) {
    $s = $Lab.Subscribers | Where-Object Name -eq $Name
    if (-not $s) { throw "Unknown subscriber '$Name'. Known: $($Lab.Subscribers.Name -join ', ')" }
    $s
}
function Invoke-SubSql($Sub, [string]$Query, [hashtable]$SqlParameter) {
    Invoke-LabSql -SqlInstance $Sub.Host -Credential (Get-SubscriberCredential $Sub) -Database $Sub.Db `
        -Query $Query -SqlParameter $SqlParameter
}

# ------------------------------------------------------------------ run bookkeeping
function Start-Run([string]$Name, [string]$SubName, [datetime]$Injected, [string]$Notes) {
    $script:CurrentRun = (Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -Query @'
INSERT dbo.ChaosRun (Scenario, SubscriberName, InjectedAt, Notes, Result)
OUTPUT inserted.RunId VALUES (@sc, @sub, @inj, @notes, 'Running');
'@ -SqlParameter @{ sc = $Name; sub = $SubName; inj = $Injected; notes = $Notes }).RunId
}

function Complete-Run($Incident, [datetime]$Injected, [string]$Notes) {
    $rec = Get-ServerNow
    $row = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -Query @'
UPDATE dbo.ChaosRun
SET DetectedAt = @det, RepairedAt = @rep, RecoveredAt = @rec, IncidentId = @inc,
    Notes = CONCAT(Notes, N' | ', @notes), Result = 'Passed'
OUTPUT inserted.RunId, inserted.Scenario, inserted.SubscriberName, inserted.DetectSec, inserted.RecoverSec, inserted.Notes, inserted.Result
WHERE RunId = @run;
'@ -SqlParameter @{ run = $script:CurrentRun; det = $Incident.DetectedAt; rep = $Incident.ActionAt
                    rec = $rec; inc = $Incident.IncidentId; notes = $Notes }
    Write-Host ("    recovered +{0,6:N1}s  verified" -f ($rec - $Injected).TotalSeconds) -ForegroundColor Green
    $script:CurrentRun = $null
    $row
}

function Stop-RunAsFailed([string]$Reason) {
    if (-not $script:CurrentRun) { return }
    Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -Query @'
UPDATE dbo.ChaosRun SET Result = 'Failed', Notes = CONCAT(Notes, N' | FAILED: ', @why) WHERE RunId = @run;
'@ -SqlParameter @{ run = $script:CurrentRun; why = $Reason } | Out-Null
    $script:CurrentRun = $null
}

# ------------------------------------------------------------------ waiting
function Wait-Incident([string]$Kind, [string]$SubName, [datetime]$Since) {
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $detected = $null
    while ((Get-Date) -lt $deadline) {
        $i = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -Query @'
SELECT TOP (1) IncidentId, DetectedAt, ActionAt, ResolvedAt, Diagnosis, Action
FROM dbo.Incident WHERE Kind = @k AND SubscriberName = @s AND DetectedAt >= @since
ORDER BY IncidentId DESC;
'@ -SqlParameter @{ k = $Kind; s = $SubName; since = $Since }
        if ($i -and -not $detected) {
            $detected = $i
            Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -Query 'UPDATE dbo.ChaosRun SET DetectedAt = @d, IncidentId = @i WHERE RunId = @r' `
                -SqlParameter @{ d = $i.DetectedAt; i = $i.IncidentId; r = $script:CurrentRun } | Out-Null
            Write-Host ("    detected  +{0,6:N1}s  {1}" -f ($i.DetectedAt - $Since).TotalSeconds, $i.Diagnosis) -ForegroundColor Yellow
        }
        if ($i -and $i.ResolvedAt -isnot [DBNull]) {
            if ($i.Action -isnot [DBNull]) {
                Write-Host ("    repaired  +{0,6:N1}s  {1}" -f ($i.ActionAt - $Since).TotalSeconds, $i.Action) -ForegroundColor Yellow
            }
            return $i
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out after $TimeoutMin min waiting for $Kind on $SubName to be detected and resolved."
}

function Wait-Barrier([string]$SubName) {
    $r = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -QueryTimeout 300 -Query @'
SET ANSI_NULLS ON; SET ANSI_WARNINGS ON;
DECLARE @a bit; EXEC dbo.usp_WaitForBarrier @SubscriberName = @s, @Arrived = @a OUTPUT; SELECT @a AS Arrived;
'@ -SqlParameter @{ s = $SubName }
    [bool]$r.Arrived
}

# ------------------------------------------------------------------ scenarios
function Test-AgentStopped([string]$SubName) {
    $job = (Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' `
        -Query 'SELECT JobName FROM dbo.vSubscriberAgent WHERE SubscriberName = @s' -SqlParameter @{ s = $SubName }).JobName
    Write-Host "`n[AgentStopped] $SubName : stopping job '$job'"
    $inj = (Invoke-LabSql -SqlInstance $pub -Database 'msdb' `
        -Query 'EXEC msdb.dbo.sp_stop_job @job_name = @j; SELECT GETDATE() AS Now;' -SqlParameter @{ j = $job }).Now
    Start-Run 'AgentStopped' $SubName $inj "Stopped job $job"
    $inc = Wait-Incident 'AgentStopped' $SubName $inj
    if (-not (Wait-Barrier $SubName)) { throw 'Replication did not resume after the agent restart.' }
    Complete-Run $inc $inj 'Agent restarted; backlog drained (token arrived)'
}

function Test-RowNotFound([string]$SubName) {
    $sub = Get-Sub $SubName
    $id = Get-Random -Minimum 1 -Maximum 1000           # stable range the workload never touches
    Write-Host "`n[RowNotFound] $SubName : delete Customer $id at the subscriber, update it at the publisher"
    Invoke-SubSql $sub 'DELETE dbo.Customer WHERE CustomerID = @id;' @{ id = $id } | Out-Null
    $inj = (Invoke-LabSql -SqlInstance $pub -Database $Lab.PublisherDb -Query @'
UPDATE dbo.Customer SET Email = CONCAT(N'chaos-', LEFT(NEWID(), 8), N'@example.com'), ModifiedAt = SYSUTCDATETIME()
WHERE CustomerID = @id;
SELECT GETDATE() AS Now;
'@ -SqlParameter @{ id = $id }).Now
    Start-Run 'RowNotFound' $SubName $inj "Deleted Customer $id at the subscriber, then updated it at the publisher"
    $inc = Wait-Incident 'DataConflict' $SubName $inj
    if (-not (Wait-Barrier $SubName)) { throw 'Replication did not resume after repair.' }
    $p = Invoke-LabSql -SqlInstance $pub -Database $Lab.PublisherDb -Query 'SELECT Email FROM dbo.Customer WHERE CustomerID = @id' -SqlParameter @{ id = $id }
    $s = Invoke-SubSql $sub 'SELECT Email FROM dbo.Customer WHERE CustomerID = @id' @{ id = $id }
    if (-not $s -or $s.Email -ne $p.Email) { throw "Customer $id still differs at $SubName." }
    Complete-Run $inc $inj "Customer $id restored; agent resumed"
}

function Test-DuplicateKey([string]$SubName) {
    $sub = Get-Sub $SubName
    $sku = 'SKU-CHAOS-{0}' -f (Get-Random -Minimum 10000 -Maximum 99999)
    $stray = Get-Random -Minimum 900000 -Maximum 999999
    Write-Host "`n[DuplicateKey] $SubName : stray product $stray holds $sku at the subscriber; the publisher adds a real product with the same SKU"
    Invoke-SubSql $sub "INSERT dbo.Product (ProductID, Sku, Name, ListPrice) VALUES (@id, @sku, N'Chaos stray (subscriber only)', 1.00);" `
        @{ id = $stray; sku = $sku } | Out-Null
    $r = Invoke-LabSql -SqlInstance $pub -Database $Lab.PublisherDb -SqlParameter @{ sku = $sku } -Query @'
INSERT dbo.Product (Sku, Name, ListPrice) VALUES (@sku, N'Chaos product (real)', 9.99);
SELECT CAST(SCOPE_IDENTITY() AS int) AS Id, GETDATE() AS Now;
'@
    $inj = $r.Now
    Start-Run 'DuplicateKey' $SubName $inj "Stray ProductID $stray at the subscriber vs new ProductID $($r.Id) on $sku"
    $inc = Wait-Incident 'DataConflict' $SubName $inj
    if (-not (Wait-Barrier $SubName)) { throw 'Replication did not resume after repair.' }
    $s = @(Invoke-SubSql $sub 'SELECT ProductID FROM dbo.Product WHERE Sku = @sku' @{ sku = $sku })
    if ($s.Count -ne 1 -or $s[0].ProductID -ne $r.Id) { throw "$sku at $SubName is not the publisher's ProductID $($r.Id)." }
    Complete-Run $inc $inj "Stray $stray removed; ProductID $($r.Id) replicated"
}

function Test-SilentDrift([string]$SubName) {
    $sub = Get-Sub $SubName
    $id = Get-Random -Minimum 15000 -Maximum 20000      # oldest seeded orders: stable at the publisher
    $name = if ($TriggerDriftNow) { 'SilentDrift' } else { 'SilentDriftScheduled' }
    Write-Host "`n[$name] $SubName : tamper with SalesOrder $id at the subscriber (no error will ever fire)"
    Invoke-SubSql $sub "UPDATE dbo.SalesOrder SET Status = 'TAMPERED' WHERE OrderID = @id;" @{ id = $id } | Out-Null
    $inj = Get-ServerNow
    Start-Run $name $SubName $inj "Set SalesOrder $id Status to TAMPERED at the subscriber"
    if ($TriggerDriftNow) {
        # A scheduled run may already be in progress (it can't see a change made after it began),
        # and SQL Agent refuses to start a running job: wait for it to finish, then start a fresh run.
        $isRunning = @'
SELECT COUNT(*) AS n FROM msdb.dbo.sysjobactivity ja JOIN msdb.dbo.sysjobs j ON j.job_id = ja.job_id
WHERE j.name = N'ReplMon - Drift check' AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL;
'@
        while ((Invoke-LabSql -SqlInstance $pub -Database 'msdb' -Query $isRunning).n -gt 0) {
            Write-Host '    a scheduled drift check is running; waiting for it to finish...' -ForegroundColor DarkGray
            Start-Sleep -Seconds 3
        }
        Invoke-LabSql -SqlInstance $pub -Database 'msdb' -Query "EXEC msdb.dbo.sp_start_job @job_name = N'ReplMon - Drift check';" | Out-Null
    } else { Write-Host '    waiting for the scheduled drift check (every 5 min)...' -ForegroundColor DarkGray }
    $inc = Wait-Incident 'SilentDrift' $SubName $inj
    $p = Invoke-LabSql -SqlInstance $pub -Database $Lab.PublisherDb -Query 'SELECT Status FROM dbo.SalesOrder WHERE OrderID = @id' -SqlParameter @{ id = $id }
    $s = Invoke-SubSql $sub 'SELECT Status FROM dbo.SalesOrder WHERE OrderID = @id' @{ id = $id }
    if ($s.Status -ne $p.Status) { throw "SalesOrder $id still differs at $SubName." }
    Complete-Run $inc $inj "SalesOrder $id restored"
}

# ------------------------------------------------------------------ run
$onprem = @($Lab.Subscribers | Where-Object Tier -eq 'on-prem')
$cloud  = $Lab.Subscribers | Where-Object Tier -eq 'cloud' | Select-Object -First 1
$pick = { param($default) if ($Subscriber) { $Subscriber } else { $default } }
$plan = @(switch ($Scenario) {
    'AgentStopped' { , @('AgentStopped', (& $pick $onprem[-1].Name)) }
    'RowNotFound'  { , @('RowNotFound',  (& $pick $onprem[0].Name)) }
    'DuplicateKey' { , @('DuplicateKey', (& $pick $onprem[0].Name)) }
    'SilentDrift'  { , @('SilentDrift',  (& $pick ($cloud ? $cloud.Name : $onprem[-1].Name))) }
    'All' {
        , @('AgentStopped', $onprem[-1].Name)
        , @('RowNotFound',  $onprem[0].Name)
        , @('DuplicateKey', $onprem[0].Name)
        , @('SilentDrift',  ($cloud ? $cloud.Name : $onprem[-1].Name))
    }
})

$results = for ($n = 0; $n -lt $plan.Count; $n++) {
    $step = $plan[$n]
    try { & "Test-$($step[0])" $step[1] }
    catch {
        $why = $_.Exception.Message
        Write-Host "    FAILED: $why" -ForegroundColor Red
        Stop-RunAsFailed $why
        [pscustomobject]@{ Scenario = $step[0]; SubscriberName = $step[1]; DetectSec = $null; RecoverSec = $null
                           Notes = "FAILED: $why"; Result = 'Failed' }
    }
    if ($n -lt $plan.Count - 1) { Start-Sleep -Seconds 30 }   # let the system settle between faults
}

Write-Host "`nChaos results" -ForegroundColor Cyan
$results | Format-Table Scenario, SubscriberName, DetectSec, RecoverSec, Result, Notes -AutoSize
Write-Host 'Resilience report: ./reports/Export-ResilienceReport.ps1 -Hours 1'
