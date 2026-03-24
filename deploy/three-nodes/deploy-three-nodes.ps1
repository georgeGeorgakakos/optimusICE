# =============================================================================
# deploy-three-nodes.ps1 — OptimusDB three-node local simulation
# =============================================================================
# Usage:
#   .\deploy-three-nodes.ps1              # bring all three nodes up
#   .\deploy-three-nodes.ps1 -Mode down   # stop all (keep volumes)
#   .\deploy-three-nodes.ps1 -Mode clean  # stop all + delete volumes
#   .\deploy-three-nodes.ps1 -Mode status # show all containers
#   .\deploy-three-nodes.ps1 -Mode swarm  # peer IPFS nodes together
#   .\deploy-three-nodes.ps1 -Mode test   # smoke test all three nodes
# =============================================================================

param(
    [ValidateSet("up","down","clean","status","swarm","test")]
    [string]$Mode = "up"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$NodeDirs = @(
    "$ScriptDir\node-a",
    "$ScriptDir\node-b",
    "$ScriptDir\node-c"
)
$NodeNames  = @("node-a",  "node-b",  "node-c")
$NodeIDs    = @("node-alpha", "node-beta", "node-gamma")
$TrinoPorts = @(8080, 8180, 8280)
$BridgePorts= @(9090, 9190, 9290)
$IpfsPorts  = @(5001, 5101, 5201)
$ZenohPorts = @(8000, 8100, 8200)

$SHARED_NET = "iceberg-mesh"

function Write-Info  { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Sec   { param($msg) Write-Host "`n══ $msg ══" -ForegroundColor Blue }

function Ensure-SharedNetwork {
    Write-Sec "Shared mesh network"
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $exists = docker network ls --filter "name=$SHARED_NET" --format "{{.Name}}" 2>&1
    $ErrorActionPreference = $prev
    if ($exists -match $SHARED_NET) {
        Write-Ok "$SHARED_NET already exists"
    } else {
        docker network create $SHARED_NET
        Write-Ok "$SHARED_NET created"
    }
}

function Start-AllNodes {
    Write-Sec "Starting all three nodes"
    for ($i = 0; $i -lt 3; $i++) {
        $dir  = $NodeDirs[$i]
        $name = $NodeNames[$i]
        Write-Info "Starting $name ..."
        Push-Location $dir
        try {
            docker compose up -d --remove-orphans
            if ($LASTEXITCODE -ne 0) { Write-Err "$name failed to start"; exit 1 }
            Write-Ok "$name started"
        } finally { Pop-Location }
    }
}

function Stop-AllNodes {
    param([bool]$Clean = $false)
    Write-Sec "Stopping all nodes"
    for ($i = 0; $i -lt 3; $i++) {
        $dir  = $NodeDirs[$i]
        $name = $NodeNames[$i]
        Write-Info "Stopping $name ..."
        Push-Location $dir
        try {
            if ($Clean) {
                docker compose down -v --remove-orphans
            } else {
                docker compose down --remove-orphans
            }
            Write-Ok "$name stopped"
        } finally { Pop-Location }
    }
    if ($Clean) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        docker network rm $SHARED_NET 2>&1 | Out-Null
        $ErrorActionPreference = $prev
        Write-Ok "Mesh network removed"
    }
}

function Show-AllStatus {
    Write-Sec "All container status"
    for ($i = 0; $i -lt 3; $i++) {
        Write-Host "`n  ── $($NodeNames[$i]) ──" -ForegroundColor Blue
        Push-Location $NodeDirs[$i]
        try { docker compose ps } finally { Pop-Location }
    }
    Write-Sec "Port map"
    Write-Host ""
    for ($i = 0; $i -lt 3; $i++) {
        $n = $NodeNames[$i]
        Write-Host "  $n  Trino :$($TrinoP[$i])  Catalog :$($CatalogP[$i])  Bridge :$($BridgePorts[$i])  Zenoh :$($ZenohPorts[$i])" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  Node A  Trino  → http://localhost:8080" -ForegroundColor Cyan
    Write-Host "  Node B  Trino  → http://localhost:8180" -ForegroundColor Cyan
    Write-Host "  Node C  Trino  → http://localhost:8280" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Node A  Bridge → http://localhost:9090/metrics" -ForegroundColor Cyan
    Write-Host "  Node B  Bridge → http://localhost:9190/metrics" -ForegroundColor Cyan
    Write-Host "  Node C  Bridge → http://localhost:9290/metrics" -ForegroundColor Cyan
}

function Peer-IpfsSwarm {
    Write-Sec "Peering IPFS swarm across nodes"
    Write-Info "Waiting 10s for IPFS nodes to be ready..."
    Start-Sleep -Seconds 10

    $containers = @("iceberg-ipfs-node-a", "iceberg-ipfs-node-b", "iceberg-ipfs-node-c")
    $peerIDs = @{}
    $peerAddrs = @{}

    # Collect peer IDs and listen addresses
    foreach ($c in $containers) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $idJson = docker exec $c ipfs id --encoding=json 2>&1
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "$c not ready yet — run .\deploy-three-nodes.ps1 -Mode swarm again in 30s"
            return
        }
        $id = ($idJson | ConvertFrom-Json)
        $peerIDs[$c] = $id.ID
        # Use the container's internal swarm address (172.x.x.x/tcp/4001)
        $addr = ($id.Addresses | Where-Object { $_ -match "172\." -and $_ -match "tcp/4001" } | Select-Object -First 1)
        if (-not $addr) {
            $addr = ($id.Addresses | Where-Object { $_ -match "tcp/4001" } | Select-Object -First 1)
        }
        $peerAddrs[$c] = $addr
        Write-Ok "$c  PeerID: $($id.ID.Substring(0,20))..."
    }

    # Cross-peer all three nodes
    foreach ($src in $containers) {
        foreach ($dst in $containers) {
            if ($src -eq $dst) { continue }
            $addr = $peerAddrs[$dst]
            if (-not $addr) { Write-Warn "No addr for $dst — skipping"; continue }
            Write-Info "  $src → add peer $dst"
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            docker exec $src ipfs swarm connect $addr 2>&1 | Out-Null
            $ErrorActionPreference = $prev
        }
    }

    Write-Ok "IPFS swarm peered — verify with:"
    Write-Host "  docker exec iceberg-ipfs-node-a ipfs swarm peers" -ForegroundColor DarkGray
}

function Invoke-SmokeTest {
    Write-Sec "Smoke test — all three nodes"

    for ($i = 0; $i -lt 3; $i++) {
        $name   = $NodeNames[$i]
        $trino  = $TrinoPorts[$i]
        $bridge = $BridgePorts[$i]
        $zenoh  = $ZenohPorts[$i]

        Write-Host "`n  ── $name ──" -ForegroundColor Blue

        # Trino
        try {
            $r = Invoke-RestMethod "http://localhost:$trino/v1/info" -TimeoutSec 5
            Write-Ok "Trino :$trino  (starting=$($r.starting))"
        } catch { Write-Warn "Trino :$trino not ready" }

        # Zenoh
        try {
            $r = Invoke-RestMethod "http://localhost:$zenoh/@/router/local" -TimeoutSec 5
            $sessions = ($r | ConvertTo-Json -Depth 5 | Select-String "sessions").Count
            Write-Ok "Zenoh :$zenoh  responding"
        } catch { Write-Warn "Zenoh :$zenoh not ready" }

        # Bridge
        try {
            $r = Invoke-WebRequest "http://localhost:$bridge/metrics" -TimeoutSec 5
            $published = ($r.Content | Select-String "bridge_partitions_published_total (\d+)").Matches[0].Groups[1].Value
            Write-Ok "Bridge :$bridge  partitions_published=$published"
        } catch { Write-Warn "Bridge :$bridge not ready" }
    }

    Write-Sec "Zenoh mesh connectivity"
    Write-Info "Checking sessions on node-a router..."
    try {
        $r = Invoke-RestMethod "http://localhost:8000/@/router/local" -TimeoutSec 5
        Write-Ok "Node-A Zenoh router responding"
    } catch { Write-Warn "Could not reach node-a Zenoh REST" }
}

# ── Main ──────────────────────────────────────────────────────────────────────
Write-Host @"

  ╔══════════════════════════════════════════════════════╗
  ║   OptimusDB — Three-Node Local Simulation            ║
  ║   node-alpha  :8080  node-beta :8180  node-gamma :8280 ║
  ╚══════════════════════════════════════════════════════╝

"@ -ForegroundColor Blue

switch ($Mode) {
    "up" {
        Ensure-SharedNetwork
        Start-AllNodes
        Write-Info "Waiting 15s before IPFS swarm peering..."
        Start-Sleep -Seconds 15
        Peer-IpfsSwarm
        Show-AllStatus
        Write-Host ""
        Write-Ok "Three-node mesh is up. Run -Mode test after ~3 min for Trino to finish starting."
    }
    "down"   { Stop-AllNodes -Clean $false }
    "clean"  { Stop-AllNodes -Clean $true }
    "status" { Show-AllStatus }
    "swarm"  { Peer-IpfsSwarm }
    "test"   { Invoke-SmokeTest }
}
