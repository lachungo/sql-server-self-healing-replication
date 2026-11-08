<#
.SYNOPSIS
    Resilience report for a time window: every chaos run scored against its targets
    (ReplMon.dbo.ChaosTarget), the change since the previous run of the same fault, and the
    evidence per run: what was injected, the incident ReplMon opened, and the rows it repaired.

.PARAMETER From / To
    Window in YOUR local time (converted to UTC, which is what the containers use).
.PARAMETER Hours
    Used when -From is not given: the last N hours.
.PARAMETER Collapsed
    Fold the detail sections (default: everything expanded, for review and screenshots).

.EXAMPLE
    ./reports/Export-ResilienceReport.ps1 -Hours 1
    ./reports/Export-ResilienceReport.ps1 -From '2026-11-07 14:00' -To '2026-11-08 03:00'
#>
[CmdletBinding()]
param([datetime]$From, [datetime]$To, [int]$Hours = 24, [switch]$Collapsed)
. "$PSScriptRoot/../scripts/common.ps1"
. "$PSScriptRoot/report-helpers.ps1"
Initialize-LabSession
$pub = $Lab.PublisherHost
$w = Get-ReportWindow $From $To $Hours
$win = @{ f = $w.FromUtc; t = $w.ToUtc }

$runRows = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -SqlParameter $win -Query @'
WITH r AS (
    SELECT c.*, LAG(c.DetectSec)  OVER (PARTITION BY c.Scenario ORDER BY c.RunId) AS PrevDetect,
                LAG(c.RecoverSec) OVER (PARTITION BY c.Scenario ORDER BY c.RunId) AS PrevRecover
    FROM dbo.ChaosRun c)
SELECT r.RunId, r.Scenario, r.SubscriberName, CONVERT(varchar(23), r.InjectedAt, 121) AS InjectedAt,
       CAST(r.DetectSec AS decimal(9,1)) AS DetectSec, CAST(r.RecoverSec AS decimal(9,1)) AS RecoverSec,
       CAST(DATEDIFF(MILLISECOND, r.InjectedAt, r.RepairedAt) / 1000.0 AS decimal(9,1)) AS RepairSec,
       CAST(r.PrevDetect AS decimal(9,1)) AS PrevDetect, CAST(r.PrevRecover AS decimal(9,1)) AS PrevRecover,
       ISNULL(r.Result, CASE WHEN r.RecoveredAt IS NULL THEN 'Failed' ELSE 'Passed' END) AS Result,
       r.Notes, t.DetectTargetSec, t.RecoverTargetSec, t.Description
FROM r LEFT JOIN dbo.ChaosTarget t ON t.Scenario = r.Scenario
WHERE r.InjectedAt >= @f AND r.InjectedAt < @t
ORDER BY r.RunId;
'@

$inWindow = 'ch.RunId IN (SELECT RunId FROM dbo.ChaosRun WHERE InjectedAt >= @f AND InjectedAt < @t)'
$incRows = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -SqlParameter $win -Query ($IncidentSelectSql + $ChaosLinkSql + "WHERE $inWindow ORDER BY i.DetectedAt;")
$repRows = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -SqlParameter $win -Query ($RepairSelectSql + $ChaosLinkSql + "WHERE $inWindow ORDER BY r.RepairId;")

$data = [ordered]@{
    window    = $w.Display
    runs      = @($runRows | ForEach-Object { [ordered]@{
        id = $_.RunId; scenario = $_.Scenario; sub = (Get-SubscriberLabel $_.SubscriberName); injected = $_.InjectedAt
        detectSec = (ConvertFrom-DbNull $_.DetectSec); repairSec = (ConvertFrom-DbNull $_.RepairSec)
        recoverSec = (ConvertFrom-DbNull $_.RecoverSec)
        prevDetect = (ConvertFrom-DbNull $_.PrevDetect); prevRecover = (ConvertFrom-DbNull $_.PrevRecover)
        detectTarget = (ConvertFrom-DbNull $_.DetectTargetSec); recoverTarget = (ConvertFrom-DbNull $_.RecoverTargetSec)
        description = (ConvertFrom-DbNull $_.Description); notes = (ConvertFrom-DbNull $_.Notes); result = $_.Result } })
    incidents = @(ConvertTo-IncidentData $incRows)
    repairs   = @(ConvertTo-RepairData $repRows)
    expand    = -not $Collapsed
    built     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
}
$file = Write-ReplReport 'resilience-report.template.html' $data ("resilience-report-{0:yyyyMMdd-HHmm}-{1:HHmm}.html" -f $w.From, $w.To)
Write-Host ("Window : {0} -> {1} local ({2} -> {3} UTC)" -f $w.Display.fromLocal, $w.Display.toLocal, $w.Display.fromUtc, $w.Display.toUtc)
Write-Host ("Found  : {0} chaos run(s), {1} linked incident(s), {2} repaired row(s)" -f $data.runs.Count, $data.incidents.Count, $data.repairs.Count)
Write-Host "Report : $file" -ForegroundColor Green
