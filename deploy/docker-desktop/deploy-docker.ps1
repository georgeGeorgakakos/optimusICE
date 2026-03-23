# =============================================================================
# deploy-docker.ps1 — iceberg-decentralized on Docker Desktop (Windows)
# =============================================================================
# Usage:
#   .\deploy-docker.ps1             # full deploy (build + up)
#   .\deploy-docker.ps1 -Mode up    # compose up only (skip bridge build)
#   .\deploy-docker.ps1 -Mode down  # tear down (keep volumes)
#   .\deploy-docker.ps1 -Mode clean # tear down + remove volumes
#   .\deploy-docker.ps1 -Mode status
#   .\deploy-docker.ps1 -Mode logs
#   .\deploy-docker.ps1 -Mode test
# =============================================================================

param(
    [ValidateSet("deploy","up","down","clean","status","logs","test")]
    [string]$Mode = "deploy"
)

$ErrorActionPreference = "Stop"

# ── Config ────────────────────────────────────────────────────────────────────
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$_resolved    = Resolve-Path "$ScriptDir\..\.." -ErrorAction SilentlyContinue
$RepoRoot     = if ($_resolved) { $_resolved.Path } else { "$ScriptDir\..\.." }
$ComposeFile  = "$ScriptDir\docker-compose.yml"
$BridgeDir    = "$RepoRoot\bridge"
$BridgeImage  = "optimusdb/zenoh-iceberg-bridge:0.1.0"
$TrinoPort    = 8080
$CatalogPort  = 8181
$IpfsPort     = 5001
$MetricsPort  = 9090

# ── Colors ────────────────────────────────────────────────────────────────────
function Write-Info  { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Sec   { param($msg) Write-Host "`n══ $msg ══" -ForegroundColor Blue }

# ── Banner ────────────────────────────────────────────────────────────────────
function Show-Banner {
    Write-Host @"

  ╔══════════════════════════════════════════════════╗
  ║     iceberg-decentralized — Docker Desktop       ║
  ║     Trino + Iceberg + IPFS + Zenoh + Bridge      ║
  ╚══════════════════════════════════════════════════╝

"@ -ForegroundColor Blue
}

# ── Preflight checks ──────────────────────────────────────────────────────────
function Test-Prerequisites {
    Write-Sec "Preflight checks"
    $ok = $true

    # Docker
    try {
        $v = docker --version 2>&1
        Write-Ok "Docker found: $v"
    } catch {
        Write-Err "Docker not found. Install Docker Desktop from https://docker.com/products/docker-desktop"
        $ok = $false
    }

    # Docker daemon running
    # Temporarily set Continue so docker info warnings don't throw under Stop preference
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    docker info 2>&1 | Out-Null
    $daemonOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if ($daemonOk) {
        Write-Ok "Docker daemon is running"
    } else {
        Write-Err "Docker daemon not running — open Docker Desktop and wait for it to start"
        $ok = $false
    }

    # Compose v2
    try {
        $cv = docker compose version 2>&1
        Write-Ok "Docker Compose v2: $cv"
    } catch {
        Write-Err "Docker Compose v2 not found — update Docker Desktop"
        $ok = $false
    }

    # RAM check
    $ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $ramGB = [math]::Round($ram / 1GB)
    if ($ramGB -lt 8) {
        Write-Warn "Only ${ramGB}GB RAM detected. Recommend 8GB+ for this stack."
    } else {
        Write-Ok "RAM: ${ramGB}GB"
    }

    # Docker Desktop memory allocation
    Write-Warn "Ensure Docker Desktop has at least 6GB RAM allocated:"
    Write-Warn "  Settings → Resources → Memory → set to 6144 MB or more"

    if (-not $ok) {
        Write-Err "Fix the above issues and retry."
        exit 1
    }
}

# ── Build bridge image ────────────────────────────────────────────────────────
function Build-Bridge {
    Write-Sec "Building Zenoh-Iceberg Bridge"

    $mainGo = Join-Path $BridgeDir "main.go"
    if (-not (Test-Path $mainGo)) {
        Write-Err "Bridge source not found at $mainGo"
        Write-Err "Make sure you cloned the full repo."
        exit 1
    }

    Write-Info "Building $BridgeImage from $BridgeDir ..."
    docker build -t $BridgeImage $BridgeDir
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Bridge build failed"
        exit 1
    }
    Write-Ok "Bridge image built: $BridgeImage"
}

# ── Pull images ───────────────────────────────────────────────────────────────
function Pull-Images {
    Write-Sec "Pulling images"
    $images = @(
        "ipfs/kubo:v0.26.0",
        "eclipse/zenoh:0.11.0",
        "tabulario/iceberg-rest:0.10.0",
        "trinodb/trino:435"
    )
    foreach ($img in $images) {
        Write-Info "Pulling $img ..."
        docker pull $img
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Failed to pull $img — will try at compose up"
        } else {
            Write-Ok "$img ready"
        }
    }
}

# ── Start services ────────────────────────────────────────────────────────────
function Start-Services {
    Write-Sec "Starting services"
    Push-Location $ScriptDir
    try {
        docker compose -f $ComposeFile up -d --remove-orphans
        if ($LASTEXITCODE -ne 0) { Write-Err "docker compose up failed"; exit 1 }
        Write-Ok "All containers started"
    } finally {
        Pop-Location
    }
}

# ── Wait for healthy ──────────────────────────────────────────────────────────
function Wait-ForHealthy {
    Write-Sec "Waiting for all services to become healthy"

    $services = @(
        "iceberg-ipfs",
        "iceberg-zenoh",
        "iceberg-catalog",
        "iceberg-trino-coordinator",
        "iceberg-trino-worker-1",
        "iceberg-trino-worker-2",
        "iceberg-bridge"
    )

    foreach ($svc in $services) {
        Write-Info "Waiting for $svc ..."
        $maxWait = 100
        $interval = 10
        $elapsed = 0

        while ($true) {
            $status = ""
            try {
                $status = docker inspect --format='{{.State.Health.Status}}' $svc 2>&1
            } catch {
                $status = "missing"
            }

            $status = $status.Trim()

            if ($status -eq "healthy") {
                Write-Ok "$svc is healthy"
                break
            } elseif ($status -eq "missing" -or $status -eq "") {
                Write-Warn "$svc container not found"
                break
            } elseif ($elapsed -ge $maxWait) {
                Write-Warn "$svc not healthy after ${maxWait}s — continuing anyway"
                docker logs $svc --tail=15 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
                break
            }

            Start-Sleep -Seconds $interval
            $elapsed += $interval
            Write-Host "." -NoNewline
        }
        Write-Host ""
    }
}

# ── Smoke test ────────────────────────────────────────────────────────────────
function Invoke-SmokeTest {
    Write-Sec "Smoke test"

    # Iceberg catalog
    Write-Info "Testing Iceberg REST catalog ..."
    try {
        $r = Invoke-RestMethod "http://localhost:${CatalogPort}/v1/config" -TimeoutSec 5
        Write-Ok "Iceberg catalog responding"
    } catch {
        Write-Warn "Iceberg catalog not yet ready: $_"
    }

    # IPFS API
    Write-Info "Testing IPFS API ..."
    try {
        $r = Invoke-RestMethod -Method Post "http://localhost:${IpfsPort}/api/v0/id" -TimeoutSec 5
        Write-Ok "IPFS node responding (ID: $($r.ID.Substring(0,16))...)"
    } catch {
        Write-Warn "IPFS not yet ready: $_"
    }

    # Trino info
    Write-Info "Testing Trino coordinator ..."
    try {
        $r = Invoke-RestMethod "http://localhost:${TrinoPort}/v1/info" -TimeoutSec 5
        Write-Ok "Trino coordinator responding (starting: $($r.starting))"
    } catch {
        Write-Warn "Trino not yet ready — wait 30s and run: .\deploy-docker.ps1 -Mode test"
    }

    # Bridge healthz
    Write-Info "Testing bridge health ..."
    try {
        $r = Invoke-WebRequest "http://localhost:${MetricsPort}/healthz" -TimeoutSec 5
        if ($r.StatusCode -eq 200) { Write-Ok "Bridge is healthy" }
    } catch {
        Write-Warn "Bridge not yet ready: $_"
    }

    # SQL query via Trino REST API
    Write-Info "Running test SQL via Trino REST API ..."
    try {
        $headers = @{
            "X-Trino-User" = "test"
            "Content-Type" = "application/json"
        }
        $r = Invoke-RestMethod `
            -Method Post `
            -Uri "http://localhost:${TrinoPort}/v1/statement" `
            -Headers $headers `
            -Body "SHOW CATALOGS" `
            -TimeoutSec 10
        Write-Ok "Trino SQL query succeeded"
        if ($r.columns) { Write-Host "  Columns: $($r.columns.name -join ', ')" -ForegroundColor DarkGray }
        if ($r.data)    { Write-Host "  Data: $($r.data | ConvertTo-Json -Compress)" -ForegroundColor DarkGray }
    } catch {
        Write-Warn "SQL query failed — Trino may still be starting. Run: .\deploy-docker.ps1 -Mode test"
    }
}

# ── Status ────────────────────────────────────────────────────────────────────
function Show-Status {
    Write-Sec "Service status"
    Push-Location $ScriptDir
    try {
        docker compose -f $ComposeFile ps
    } finally {
        Pop-Location
    }

    Write-Sec "Port map"
    Write-Host "  Trino SQL          ->  http://localhost:${TrinoPort}" -ForegroundColor Cyan
    Write-Host "  Iceberg catalog    ->  http://localhost:${CatalogPort}/v1/config" -ForegroundColor Cyan
    Write-Host "  IPFS API           ->  http://localhost:${IpfsPort}/api/v0/id" -ForegroundColor Cyan
    Write-Host "  IPFS Gateway       ->  http://localhost:8888" -ForegroundColor Cyan
    Write-Host "  Zenoh REST         ->  http://localhost:8000/@/router/local" -ForegroundColor Cyan
    Write-Host "  Bridge metrics     ->  http://localhost:${MetricsPort}/metrics" -ForegroundColor Cyan
}

# ── Access instructions ───────────────────────────────────────────────────────
function Show-Access {
    Write-Sec "Ready — connect to Trino"
    Write-Host ""
    Write-Host "  Trino CLI (inside container):" -ForegroundColor White
    Write-Host "    docker exec -it iceberg-trino-coordinator trino" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  DBeaver:" -ForegroundColor White
    Write-Host "    Driver: Trino  |  Host: localhost  |  Port: ${TrinoPort}  |  Database: iceberg" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  First SQL steps:" -ForegroundColor White
    Write-Host @"
    CREATE SCHEMA IF NOT EXISTS iceberg.energy
    WITH (location = '/iceberg-warehouse/energy');

    CREATE TABLE IF NOT EXISTS iceberg.energy.readings (
        ts        TIMESTAMP(6),
        node_id   VARCHAR,
        metric    VARCHAR,
        value     DOUBLE
    ) WITH (format = 'PARQUET', partitioning = ARRAY['day(ts)']);

    INSERT INTO iceberg.energy.readings
    VALUES (CURRENT_TIMESTAMP, 'docker-node', 'solar_kw', 42.5);

    SELECT * FROM iceberg.energy.readings;
"@ -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Watch bridge sync:" -ForegroundColor White
    Write-Host "    docker logs -f iceberg-bridge" -ForegroundColor DarkGray
    Write-Host ""
}

# ── Teardown ──────────────────────────────────────────────────────────────────
function Remove-Stack {
    param([bool]$Clean = $false)
    Write-Sec "Tearing down"
    Push-Location $ScriptDir
    try {
        if ($Clean) {
            Write-Warn "Removing containers AND volumes (all data will be lost)"
            docker compose -f $ComposeFile down -v --remove-orphans
            Write-Ok "Containers and volumes removed"
        } else {
            docker compose -f $ComposeFile down --remove-orphans
            Write-Ok "Containers removed (volumes preserved)"
        }
    } finally {
        Pop-Location
    }
}

# ── Logs ──────────────────────────────────────────────────────────────────────
function Show-Logs {
    Push-Location $ScriptDir
    try {
        docker compose -f $ComposeFile logs -f --tail=50
    } finally {
        Pop-Location
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────
Show-Banner

switch ($Mode) {
    "deploy" {
        Test-Prerequisites
        Build-Bridge
        Pull-Images
        Start-Services
        Wait-ForHealthy
        Invoke-SmokeTest
        Show-Status
        Show-Access
    }
    "up" {
        Test-Prerequisites
        Start-Services
        Wait-ForHealthy
        Show-Status
        Show-Access
    }
    "down"   { Remove-Stack -Clean $false }
    "clean"  { Remove-Stack -Clean $true }
    "status" { Show-Status }
    "logs"   { Show-Logs }
    "test"   { Invoke-SmokeTest }
}