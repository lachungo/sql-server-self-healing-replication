# Shared helpers for the hybrid replication lab. Dot-source this file: . "$PSScriptRoot/scripts/common.ps1"
$ErrorActionPreference = 'Stop'
$LabRoot = Split-Path -Parent $PSScriptRoot

# Lab constants ---------------------------------------------------------------
$Lab = [ordered]@{
    PublisherDb   = 'SalesDemo'
    Publication   = 'pub_SalesDemo'
    SnapshotDir   = '/var/opt/mssql/data/ReplData/'
    # Host-side endpoints (what this PowerShell session connects to)
    PublisherHost = 'localhost,14331'
    # Subscribers: Name = the name replication uses (matches @@SERVERNAME / container hostname)
    #              Host = how this PowerShell session reaches it
    #              Db   = a distinct destination DB per subscriber, so each one maps to exactly
    #                     one distribution agent (MSdistribution_agents.subscriber_db)
    Subscribers   = @(
        [pscustomobject]@{ Name = 'sqlsub1'; Host = 'localhost,14332'; Db = 'SalesDemo_Sub1'; Tier = 'on-prem'; LinkedServer = 'LS_SQLSUB1' }
        [pscustomobject]@{ Name = 'sqlsub2'; Host = 'localhost,14333'; Db = 'SalesDemo_Sub2'; Tier = 'on-prem'; LinkedServer = 'LS_SQLSUB2' }
    )
}

function Import-LabEnv {
    $envFile = Join-Path $LabRoot '.env'
    if (-not (Test-Path $envFile)) { throw "Missing $envFile. Copy .env.example to .env and set passwords." }
    $cfg = @{}
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $k, $v = $line -split '=', 2
        $cfg[$k.Trim()] = $v.Trim()
    }
    foreach ($req in 'SA_PASSWORD', 'DIST_ADMIN_PASSWORD') {
        if (-not $cfg[$req]) { throw "$req is not set in .env" }
        if ($cfg[$req] -match "'") { throw "$req must not contain a single quote." }
    }
    $cfg
}

function Initialize-LabSession {
    if (-not (Get-Module -ListAvailable dbatools)) {
        throw 'dbatools is required: Install-Module dbatools -Scope CurrentUser'
    }
    Import-Module dbatools -ErrorAction Stop
    # Lab containers use self-signed certificates. Session-only, never for production.
    Set-DbatoolsInsecureConnection -SessionOnly | Out-Null
    $script:LabEnv = Import-LabEnv
    $script:SaCred = [pscredential]::new('sa', (ConvertTo-SecureString $LabEnv.SA_PASSWORD -AsPlainText -Force))

    # Add the cloud subscriber when configured
    if ($LabEnv.MI_SUBSCRIBER -and -not ($Lab.Subscribers | Where-Object Tier -eq 'cloud')) {
        $Lab.Subscribers += [pscustomobject]@{
            Name = $LabEnv.MI_SUBSCRIBER; Host = $LabEnv.MI_SUBSCRIBER; Db = 'SalesDemo_MI'
            Tier = 'cloud'; LinkedServer = 'LS_AZURE_MI'
        }
    }
}

function Get-SubscriberCredential([pscustomobject]$Sub) {
    if ($Sub.Tier -eq 'cloud') {
        return [pscredential]::new($LabEnv.MI_LOGIN, (ConvertTo-SecureString $LabEnv.MI_PASSWORD -AsPlainText -Force))
    }
    $SaCred
}

function Invoke-LabSql {
    param(
        [Parameter(Mandatory)] [string]$SqlInstance,
        [Parameter(Mandatory)] [string]$Query,
        [string]$Database = 'master',
        [pscredential]$Credential = $SaCred,
        [hashtable]$SqlParameter,
        [int]$QueryTimeout = 600
    )
    $p = @{ SqlInstance = $SqlInstance; SqlCredential = $Credential; Database = $Database
            Query = $Query; QueryTimeout = $QueryTimeout; EnableException = $true }
    if ($SqlParameter) { $p.SqlParameter = $SqlParameter }
    Invoke-DbaQuery @p
}

# Runs a .sql file after replacing {{TOKEN}} placeholders. Values are escaped for N'...' literals.
function Invoke-LabSqlFile {
    param(
        [Parameter(Mandatory)] [string]$SqlInstance,
        [Parameter(Mandatory)] [string]$Path,
        [hashtable]$Tokens = @{},
        [pscredential]$Credential = $SaCred
    )
    $sql = Get-Content -Raw -Path (Join-Path $LabRoot $Path)
    foreach ($k in $Tokens.Keys) { $sql = $sql.Replace("{{$k}}", ([string]$Tokens[$k]).Replace("'", "''")) }
    if ($sql -match '\{\{[A-Z_]+\}\}') { throw "Unreplaced token in $Path : $($Matches[0])" }
    Write-Host "  -> $Path on $SqlInstance" -ForegroundColor DarkGray
    Invoke-LabSql -SqlInstance $SqlInstance -Query $sql -Credential $Credential
}

function Wait-LabInstance {
    param([string]$SqlInstance, [pscredential]$Credential = $SaCred, [int]$TimeoutSec = 180, [switch]$RequireAgent)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $q = if ($RequireAgent) {
                "SELECT COUNT(*) AS n FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent%'"
            } else { 'SELECT 1 AS n' }
            $r = Invoke-LabSql -SqlInstance $SqlInstance -Query $q -Credential $Credential -QueryTimeout 10
            if ($r.n -gt 0) { return }
        } catch { }
        Start-Sleep -Seconds 3
    }
    throw "$SqlInstance not ready after $TimeoutSec s$(if ($RequireAgent) {' (SQL Agent not running)'})"
}

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
