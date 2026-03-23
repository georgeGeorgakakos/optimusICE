#!/usr/bin/env bash
# =============================================================================
# deploy-docker.sh — iceberg-decentralized on Docker Desktop
# =============================================================================
# Usage:
#   ./deploy-docker.sh           # full deploy (build + up)
#   ./deploy-docker.sh --up      # compose up only (skip bridge build)
#   ./deploy-docker.sh --down    # tear down (keep volumes)
#   ./deploy-docker.sh --clean   # tear down + remove volumes
#   ./deploy-docker.sh --status  # show service status
#   ./deploy-docker.sh --logs    # tail all logs
#   ./deploy-docker.sh --test    # run smoke test SQL query
# =============================================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}"; }

# ── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
BRIDGE_DIR="$REPO_ROOT/bridge"
BRIDGE_IMAGE="optimusdb/zenoh-iceberg-bridge:0.1.0"
TRINO_PORT=8080
CATALOG_PORT=8181
IPFS_PORT=5001
BRIDGE_METRICS_PORT=9090

# ── Argument parsing ─────────────────────────────────────────────────────────
MODE="deploy"
case "${1:-}" in
  --up)     MODE="up"     ;;
  --down)   MODE="down"   ;;
  --clean)  MODE="clean"  ;;
  --status) MODE="status" ;;
  --logs)   MODE="logs"   ;;
  --test)   MODE="test"   ;;
  --help|-h)
    sed -n '3,10p' "$0" | sed 's/^# //'
    exit 0
    ;;
esac

# ── Preflight checks ─────────────────────────────────────────────────────────
check_prerequisites() {
  section "Preflight checks"
  local missing=0

  if command -v docker &>/dev/null; then
    ok "docker found: $(command -v docker)"
  else
    error "docker not found — please install Docker Desktop"
    missing=$((missing + 1))
  fi

  # Check Docker is running
  if docker info &>/dev/null; then
    ok "Docker daemon is running"
  else
    error "Docker daemon is not running — start Docker Desktop first"
    missing=$((missing + 1))
  fi

  # Check compose v2
  if docker compose version &>/dev/null; then
    ok "Docker Compose v2 available"
  else
    error "Docker Compose v2 not found — update Docker Desktop"
    missing=$((missing + 1))
  fi

  # Check available memory (warn if < 8GB)
  if [[ "$(uname)" == "Darwin" ]]; then
    local mem_gb
    mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    if [[ $mem_gb -lt 8 ]]; then
      warn "Only ${mem_gb}GB RAM detected. Recommend 8GB+ for this stack."
    else
      ok "RAM: ${mem_gb}GB"
    fi
  fi

  [[ $missing -eq 0 ]] || { error "Fix the above issues and retry."; exit 1; }
}

# ── Build bridge image ───────────────────────────────────────────────────────
build_bridge() {
  section "Building Zenoh-Iceberg Bridge"

  if [[ ! -f "$BRIDGE_DIR/main.go" ]]; then
    error "Bridge source not found at $BRIDGE_DIR/main.go"
    error "Make sure you cloned the full repo."
    exit 1
  fi

  info "Building $BRIDGE_IMAGE from $BRIDGE_DIR ..."
  docker build -t "$BRIDGE_IMAGE" "$BRIDGE_DIR"
  ok "Bridge image built: $BRIDGE_IMAGE"
}

# ── Pull all other images ────────────────────────────────────────────────────
pull_images() {
  section "Pulling images"
  local images=(
    "ipfs/kubo:v0.26.0"
    "eclipse/zenoh:0.11.0"
    "tabulario/iceberg-rest:0.10.0"
    "trinodb/trino:435"
  )
  for img in "${images[@]}"; do
    info "Pulling $img ..."
    docker pull "$img"
    ok "$img ready"
  done
}

# ── Start services ────────────────────────────────────────────────────────────
start_services() {
  section "Starting services"
  cd "$SCRIPT_DIR"
  docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
  ok "All containers started"
}

# ── Wait for healthy ──────────────────────────────────────────────────────────
wait_for_healthy() {
  section "Waiting for all services to become healthy"
  local services=(
    "iceberg-ipfs"
    "iceberg-zenoh"
    "iceberg-catalog"
    "iceberg-trino-coordinator"
    "iceberg-trino-worker-1"
    "iceberg-trino-worker-2"
    "iceberg-bridge"
  )
  local max_wait=300
  local interval=10
  for svc in "${services[@]}"; do
    info "Waiting for $svc ..."
    local elapsed=0
    while true; do
      local status
      status=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "missing")

      if [[ "$status" == "healthy" ]]; then
        ok "$svc is healthy"
        break
      elif [[ "$status" == "missing" ]]; then
        error "Container $svc not found"
        break
      elif [[ $elapsed -ge $max_wait ]]; then
        warn "$svc not healthy after ${max_wait}s — continuing anyway"
        docker logs "$svc" --tail=20
        break
      fi

      sleep $interval
      elapsed=$((elapsed + interval))
      echo -n "."
    done
  done
}

# ── Smoke test ────────────────────────────────────────────────────────────────
run_smoke_test() {
  section "Smoke test"

  # Test Iceberg REST catalog
  info "Testing Iceberg REST catalog ..."
  if curl -sf "http://localhost:${CATALOG_PORT}/v1/config" | grep -q "defaults"; then
    ok "Iceberg catalog responding"
  else
    warn "Iceberg catalog not yet ready"
  fi

  # Test IPFS API
  info "Testing IPFS API ..."
  if curl -sf -X POST "http://localhost:${IPFS_PORT}/api/v0/id" | grep -q "ID"; then
    ok "IPFS node responding"
  else
    warn "IPFS not yet ready"
  fi

  # Test Trino info endpoint
  info "Testing Trino coordinator ..."
  if curl -sf "http://localhost:${TRINO_PORT}/v1/info" | grep -q "starting\|true"; then
    ok "Trino coordinator responding"
  else
    warn "Trino not yet ready — wait another 30s and retry"
  fi

  # Test bridge metrics
  info "Testing bridge metrics ..."
  if curl -sf "http://localhost:${BRIDGE_METRICS_PORT}/healthz" | grep -q "ok"; then
    ok "Bridge is healthy"
  else
    warn "Bridge not yet ready"
  fi

  # Run a real SQL query via Trino HTTP API
  info "Running test SQL query via Trino REST API ..."
  local query="SHOW CATALOGS"
  local response
  response=$(curl -sf \
    -X POST "http://localhost:${TRINO_PORT}/v1/statement" \
    -H "X-Trino-User: test" \
    -H "Content-Type: application/json" \
    -d "$query" 2>/dev/null || echo "")

  if echo "$response" | grep -q "nextUri\|data\|iceberg"; then
    ok "Trino SQL query succeeded"
    if command -v python3 &>/dev/null; then
      echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    cols = [c['name'] for c in d.get('columns', [])]
    rows = d.get('data', [])
    if cols: print('  Columns:', cols)
    if rows: print('  Rows:', rows[:5])
except: pass
" 2>/dev/null || true
    fi
  else
    warn "SQL query failed — Trino may still be starting. Try again in 60s."
  fi
}

# ── Show status ───────────────────────────────────────────────────────────────
show_status() {
  section "Service status"
  cd "$SCRIPT_DIR"
  docker compose -f "$COMPOSE_FILE" ps

  echo ""
  section "Port map"
  echo -e "  ${CYAN}Trino SQL${NC}          →  http://localhost:${TRINO_PORT}"
  echo -e "  ${CYAN}Iceberg catalog${NC}    →  http://localhost:${CATALOG_PORT}/v1/config"
  echo -e "  ${CYAN}IPFS API${NC}           →  http://localhost:${IPFS_PORT}/api/v0/id"
  echo -e "  ${CYAN}IPFS Gateway${NC}       →  http://localhost:8888"
  echo -e "  ${CYAN}Zenoh REST${NC}         →  http://localhost:8000/@/router/local"
  echo -e "  ${CYAN}Bridge metrics${NC}     →  http://localhost:${BRIDGE_METRICS_PORT}/metrics"
}

# ── Print access instructions ─────────────────────────────────────────────────
print_access() {
  section "Ready — connect to Trino"
  echo ""
  echo -e "  ${BOLD}Trino CLI:${NC}"
  echo -e "    docker exec -it iceberg-trino-coordinator trino"
  echo ""
  echo -e "  ${BOLD}DBeaver:${NC}"
  echo -e "    Driver: Trino  |  Host: localhost  |  Port: ${TRINO_PORT}  |  Database: iceberg"
  echo ""
  echo -e "  ${BOLD}First SQL steps:${NC}"
  cat <<'SQL'

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
SQL
  echo ""
  echo -e "  ${BOLD}Watch bridge sync:${NC}"
  echo -e "    docker logs -f iceberg-bridge"
  echo ""
}

# ── Tear down ─────────────────────────────────────────────────────────────────
teardown() {
  local clean="${1:-false}"
  section "Tearing down"
  cd "$SCRIPT_DIR"
  if [[ "$clean" == "true" ]]; then
    warn "Removing containers AND volumes (all data will be lost)"
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
    ok "Containers and volumes removed"
  else
    docker compose -f "$COMPOSE_FILE" down --remove-orphans
    ok "Containers removed (volumes preserved)"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════╗
  ║     iceberg-decentralized — Docker Desktop       ║
  ║     Trino + Iceberg + IPFS + Zenoh + Bridge      ║
  ╚══════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

case "$MODE" in
  deploy)
    check_prerequisites
    build_bridge
    pull_images
    start_services
    wait_for_healthy
    run_smoke_test
    show_status
    print_access
    ;;
  up)
    check_prerequisites
    start_services
    wait_for_healthy
    show_status
    print_access
    ;;
  down)
    teardown false
    ;;
  clean)
    teardown true
    ;;
  status)
    show_status
    ;;
  logs)
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" logs -f --tail=50
    ;;
  test)
    run_smoke_test
    ;;
esac