# Shared by Export-OperationsReport.ps1 and Export-ResilienceReport.ps1. Dot-source it.

# Resolves the report window. -From/-To are LOCAL time; the containers run on UTC.
function Get-ReportWindow($From, $To, [int]$Hours) {      # untyped: either may be omitted ($null)
    if (-not $To)   { $To = Get-Date }
    if (-not $From) { $From = $To.AddHours(-$Hours) }
    if ($From -ge $To) { throw '-From must be earlier than -To.' }
    [pscustomobject]@{
        From = $From; To = $To; FromUtc = $From.ToUniversalTime(); ToUtc = $To.ToUniversalTime()
        Display = [ordered]@{
            fromLocal = $From.ToString('yyyy-MM-dd HH:mm'); toLocal = $To.ToString('yyyy-MM-dd HH:mm')
            fromUtc = $From.ToUniversalTime().ToString('yyyy-MM-dd HH:mm'); toUtc = $To.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') }
    }
}

# DBNull -> $null, so ConvertTo-Json writes null instead of {}
function ConvertFrom-DbNull($v) { if ($v -is [DBNull]) { $null } else { $v } }

# Display name for a subscriber
function Get-SubscriberLabel([string]$Name) { if ($Name -like '*.database.windows.net*') { 'Azure SQL MI' } else { $Name } }

# Incident rows as report objects
function ConvertTo-IncidentData($Rows) {
    @($Rows | ForEach-Object { [ordered]@{
        id = $_.IncidentId; kind = $_.Kind; sub = (Get-SubscriberLabel $_.SubscriberName)
        detected = (ConvertFrom-DbNull $_.DetectedAt); diagnosis = (ConvertFrom-DbNull $_.Diagnosis)
        action = (ConvertFrom-DbNull $_.Action); actionAt = (ConvertFrom-DbNull $_.ActionAt)
        resolved = (ConvertFrom-DbNull $_.ResolvedAt); openSec = (ConvertFrom-DbNull $_.OpenSec)
        runId = (ConvertFrom-DbNull $_.RunId) } })
}

# RepairLog rows as report objects
function ConvertTo-RepairData($Rows) {
    @($Rows | ForEach-Object { [ordered]@{
        id = $_.RepairId; incident = (ConvertFrom-DbNull $_.IncidentId); at = $_.RepairedAt
        sub = (Get-SubscriberLabel $_.SubscriberName); table = $_.TableName; key = $_.KeyValues; mode = $_.Mode
        errCode = (ConvertFrom-DbNull $_.ErrorCode); errText = (ConvertFrom-DbNull $_.ErrorText)
        command = (ConvertFrom-DbNull $_.FailedCommand); before = (ConvertFrom-DbNull $_.SubscriberBefore)
        pub = (ConvertFrom-DbNull $_.PublisherRow); after = (ConvertFrom-DbNull $_.SubscriberAfter)
        runId = (ConvertFrom-DbNull $_.RunId) } })
}

# The SQL that tags an incident with the chaos run that caused it (same subscriber, inside the run's
# window; a run that never recovered is given 15 minutes). Used by both reports.
$ChaosLinkSql = @'
OUTER APPLY (SELECT TOP (1) c.RunId FROM dbo.ChaosRun c
             WHERE c.SubscriberName = i.SubscriberName
               AND i.DetectedAt >= c.InjectedAt
               AND i.DetectedAt <= DATEADD(SECOND, 60, ISNULL(c.RecoveredAt, DATEADD(MINUTE, 15, c.InjectedAt)))
             ORDER BY c.InjectedAt DESC) ch
'@ + "`n"    # here-strings drop their last line break; keep the pieces separate when joined

$IncidentSelectSql = @'
SELECT i.IncidentId, i.Kind, i.SubscriberName,
       CONVERT(varchar(23), i.DetectedAt, 121) AS DetectedAt, i.Diagnosis, i.Action,
       CONVERT(varchar(23), i.ActionAt, 121)   AS ActionAt,
       CONVERT(varchar(23), i.ResolvedAt, 121) AS ResolvedAt,
       DATEDIFF(MILLISECOND, i.DetectedAt, i.ResolvedAt) / 1000.0 AS OpenSec,
       ch.RunId
FROM dbo.Incident i
'@ + "`n"

$RepairSelectSql = @'
SELECT r.RepairId, r.IncidentId, CONVERT(varchar(23), r.RepairedAt, 121) AS RepairedAt, r.SubscriberName,
       r.TableName, r.KeyValues, r.Mode, r.ErrorCode, r.ErrorText, r.FailedCommand,
       r.SubscriberBefore, r.PublisherRow, r.SubscriberAfter, ch.RunId
FROM dbo.RepairLog r
LEFT JOIN dbo.Incident i ON i.IncidentId = r.IncidentId
'@ + "`n"

# Same classification as classify() in report-common.js, done in SQL so large volumes are counted
# on the server instead of shipped to the page.
$RepairTypeSql = @'
CASE WHEN r.ErrorCode = N'20598' THEN 'Missing row'
     WHEN r.ErrorCode IN (N'2627', N'2601') AND (r.ErrorText LIKE N'%UNIQUE KEY%' OR r.ErrorText LIKE N'%unique index%')
          THEN CASE WHEN r.Mode = 'delete' THEN 'Duplicate key: stray row' ELSE 'Duplicate key: stale row' END
     WHEN r.ErrorCode IN (N'2627', N'2601') THEN 'Duplicate key: primary key'
     WHEN r.Mode = 'delete' THEN 'Silent drift: extra row'
     ELSE 'Silent drift: changed row' END
'@

# Builds the self-contained page: template + shared CSS + shared JS + data
function Write-ReplReport([string]$Template, $Data, [string]$FileName) {
    $json = ($Data | ConvertTo-Json -Depth 8 -Compress).Replace('</', '<\/')   # "</script>" in data can't close the tag
    $html = Get-Content -Raw (Join-Path $PSScriptRoot $Template)
    $html = $html.Replace('/*__BASE_CSS__*/', (Get-Content -Raw (Join-Path $PSScriptRoot 'report-base.css')))
    $html = $html.Replace('/*__COMMON_JS__*/', (Get-Content -Raw (Join-Path $PSScriptRoot 'report-common.js')))
    $html = $html.Replace('/*__DATA__*/null', $json)
    $out = Join-Path (Split-Path -Parent $PSScriptRoot) 'output'
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $file = Join-Path $out $FileName
    $html | Set-Content -Encoding utf8 $file
    $file
}
