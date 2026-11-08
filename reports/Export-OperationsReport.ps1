<#
.SYNOPSIS
    Operations report for a time window: latency per subscriber against the SLO, where the time
    goes, every REAL incident with what ReplMon concluded and did, and each repaired row
    (missing row / duplicate key / silent drift) with the values before and after.
    Incidents caused by chaos tests are excluded and counted; they belong in the resilience report.

.PARAMETER From / To
    Window in YOUR local time (converted to UTC, which is what the containers use).
.PARAMETER Hours
    Used when -From is not given: the last N hours.
.PARAMETER Collapsed
    Fold the detail sections (default: everything expanded, for review and screenshots).
.PARAMETER DetailRows
    How many of the most recent repaired rows get a full before/after card (default 20).
    Every repaired row is always counted in the summary and written to a CSV beside the report.

.EXAMPLE
    ./reports/Export-OperationsReport.ps1 -Hours 12
    ./reports/Export-OperationsReport.ps1 -From '2026-11-08 01:25' -To '2026-11-08 02:35'
#>
[CmdletBinding()]
param([datetime]$From, [datetime]$To, [int]$Hours = 2, [int]$DetailRows = 20, [switch]$Collapsed)
. "$PSScriptRoot/../scripts/common.ps1"
. "$PSScriptRoot/report-helpers.ps1"
Initialize-LabSession
$pub = $Lab.PublisherHost
$w = Get-ReportWindow $From $To $Hours
$win = @{ f = $w.FromUtc; t = $w.ToUtc }

$series = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -SqlParameter $win -Query @'
SELECT SubscriberName,
       CONVERT(char(16), DATEADD(MINUTE, DATEDIFF(MINUTE, 0, PublisherCommit), 0), 120) AS Minute,
       AVG(TotalLatencyMs) AS TotalMs
FROM dbo.TracerLatency
WHERE PublisherCommit >= @f AND PublisherCommit < @t
GROUP BY SubscriberName, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, PublisherCommit), 0)
ORDER BY Minute;
'@
if (-not $series) { throw "No tracer latency between $($w.From) and $($w.To) (local). Are the ReplMon jobs enabled?" }

$slo = (Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -Query "SELECT CAST(Value AS int) AS s FROM dbo.Settings WHERE Name = N'LatencySloSec'").s
$summary = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -SqlParameter ($win + @{ slo = $slo * 1000 }) -Query @'
SELECT DISTINCT l.SubscriberName, s.Tier,
       COUNT(*) OVER (PARTITION BY l.SubscriberName) AS Tokens,
       PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY DistLatencyMs)  OVER (PARTITION BY l.SubscriberName) AS DistP50,
       PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY SubLatencyMs)   OVER (PARTITION BY l.SubscriberName) AS SubP50,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TotalLatencyMs) OVER (PARTITION BY l.SubscriberName) AS TotalP95,
       MAX(TotalLatencyMs) OVER (PARTITION BY l.SubscriberName) AS TotalMax,
       SUM(CASE WHEN TotalLatencyMs <= @slo THEN 1 ELSE 0 END) OVER (PARTITION BY l.SubscriberName) AS WithinSlo
FROM dbo.TracerLatency l JOIN dbo.Subscriber s ON s.SubscriberName = l.SubscriberName
WHERE l.PublisherCommit >= @f AND l.PublisherCommit < @t;
'@

$incRows = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -SqlParameter $win -Query ($IncidentSelectSql + $ChaosLinkSql + @'
WHERE i.DetectedAt < @t AND ISNULL(i.ResolvedAt, GETDATE()) >= @f
ORDER BY i.DetectedAt;
'@)
$realRepairs = "WHERE r.RepairedAt >= @f AND r.RepairedAt < @t AND ch.RunId IS NULL"   # chaos-test repairs excluded

# 1. counted on the server: type x table x subscriber
$repSummary = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -SqlParameter $win -Query (@"
SELECT x.RepairType, x.TableName, x.SubscriberName, COUNT(*) AS RowsRepaired,
       CONVERT(varchar(19), MIN(x.RepairedAt), 120) AS FirstAt, CONVERT(varchar(19), MAX(x.RepairedAt), 120) AS LastAt
FROM (SELECT $RepairTypeSql AS RepairType, r.TableName, r.SubscriberName, r.RepairedAt
      FROM dbo.RepairLog r LEFT JOIN dbo.Incident i ON i.IncidentId = r.IncidentId
"@ + "`n" + $ChaosLinkSql + @"
      $realRepairs) x
GROUP BY x.RepairType, x.TableName, x.SubscriberName
ORDER BY RowsRepaired DESC;
"@)

# 2. full evidence only for the most recent N
$repRows = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -SqlParameter ($win + @{ n = $DetailRows }) -Query (
    $RepairSelectSql.Replace('SELECT r.RepairId', 'SELECT TOP (@n) r.RepairId') + $ChaosLinkSql + "$realRepairs ORDER BY r.RepairId DESC;")

# 3. every repaired row, for anyone who needs them all
$csvRows = Invoke-LabSql -SqlInstance $pub -Database 'ReplMon' -SqlParameter $win -Query (@"
SELECT r.RepairId, r.IncidentId, CONVERT(varchar(23), r.RepairedAt, 121) AS RepairedAtUtc, r.SubscriberName,
       $RepairTypeSql AS RepairType, r.TableName, r.KeyValues, r.Mode, r.ErrorCode,
       r.SubscriberBefore, r.PublisherRow, r.SubscriberAfter, r.FailedCommand
FROM dbo.RepairLog r LEFT JOIN dbo.Incident i ON i.IncidentId = r.IncidentId
"@ + "`n" + $ChaosLinkSql + "$realRepairs ORDER BY r.RepairId;")
$repairTotal = @($repSummary | Measure-Object RowsRepaired -Sum).Sum
if (-not $repairTotal) { $repairTotal = 0 }
$allInc = ConvertTo-IncidentData $incRows

$subs = foreach ($row in ($summary | Sort-Object Tier, SubscriberName)) {
    $pts = [ordered]@{}
    foreach ($r in ($series | Where-Object SubscriberName -eq $row.SubscriberName)) { $pts[$r.Minute] = $r.TotalMs }
    [ordered]@{
        name = (Get-SubscriberLabel $row.SubscriberName); tier = $row.Tier; tokens = $row.Tokens
        distP50 = [math]::Round($row.DistP50); subP50 = [math]::Round($row.SubP50)
        p95 = [math]::Round($row.TotalP95); max = $row.TotalMax; points = $pts
        withinSlo = $row.WithinSlo
    }
}
$stamp = "{0:yyyyMMdd-HHmm}-{1:HHmm}" -f $w.From, $w.To
$csvName = "repaired-rows-$stamp.csv"
$data = [ordered]@{
    sloMs         = $slo * 1000
    window        = $w.Display
    minutes       = @($series.Minute | Sort-Object -Unique)
    subs          = @($subs)
    incidents     = @($allInc | Where-Object { $null -eq $_.runId })
    repairs       = @(ConvertTo-RepairData $repRows)
    repairSummary = @($repSummary | ForEach-Object { [ordered]@{
        type = $_.RepairType; table = $_.TableName; sub = (Get-SubscriberLabel $_.SubscriberName)
        rows = $_.RowsRepaired; first = $_.FirstAt; last = $_.LastAt } })
    repairTotal   = $repairTotal
    csvName       = $csvName
    chaosExcluded = @($allInc | Where-Object { $null -ne $_.runId }).Count
    expand        = -not $Collapsed
    built         = (Get-Date).ToString('yyyy-MM-dd HH:mm')
}
$file = Write-ReplReport 'operations-report.template.html' $data "operations-report-$stamp.html"
$csvRows | Select-Object * -ExcludeProperty RowError, RowState, Table, ItemArray, HasErrors |
    Export-Csv -NoTypeInformation -Encoding utf8 (Join-Path (Split-Path $file) $csvName)
Write-Host ("Window : {0} -> {1} local ({2} -> {3} UTC)" -f $w.Display.fromLocal, $w.Display.toLocal, $w.Display.fromUtc, $w.Display.toUtc)
Write-Host ("Found  : {0} real incident(s), {1} repaired row(s); {2} chaos-test incident(s) left to the resilience report" -f `
    $data.incidents.Count, $repairTotal, $data.chaosExcluded)
Write-Host "CSV    : every repaired row -> $csvName" 
Write-Host "Report : $file" -ForegroundColor Green
