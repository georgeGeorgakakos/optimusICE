#!/usr/bin/env bash
# =============================================================================
# deploy-k3s.sh — iceberg-decentralized on K3s
# =============================================================================
# Usage:
#   ./deploy-k3s.sh           # full deploy (build image + apply manifest)
#   ./deploy-k3s.sh --apply   # apply manifest only (skip bridge build)
#   ./deploy-k3s.sh --delete  # delete all resources (keep PVCs)
#   ./deploy-k3s.sh --clean   # delete all resources including PVCs
#   ./deploy-k3s.sh --status  # show pod/service status
#   ./deploy-k3s.sh --logs    # tail bridge logs
#   ./deploy-k3s.sh --test    # run smoke test
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$SCRIPT_DIR/k3s-manifest.yaml"
BRIDGE_DIR="$REPO_ROOT/bridge"
BRIDGE_IMAGE="optimusdb/zenoh-iceberg-bridge:0.1.0"
NAMESPACE="iceberg-decentralized"

MODE="deploy"
case "${1:-}" in
  --apply)  MODE="apply"  ;;
  --delete) MODE="delete" ;;
  --clean)  MODE="clean"  ;;
  --status) MODE="status" ;;
  --logs)   MODE="logs"   ;;
  --test)   MODE="test"   ;;
esac

# ── Preflight ─────────────────────────────────────────────────────────────────
check_prerequisites() {
  section "Preflight checks"
  local missing=0

  for cmd in kubectl docker; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd: $(command -v $cmd)"
    else
      error "$cmd not found"
      missing=$((missing + 1))
    fi
  done

  # Check K3s / kubectl cluster access
  if kubectl cluster-info &>/dev/null; then
    ok "kubectl cluster access OK"
    kubectl cluster-info | head -1
  else
    error "Cannot reach cluster — is K3s running? Try: sudo systemctl status k3s"
    missing=$((missing + 1))
  fi

  # Check local-path provisioner
  if kubectl get storageclass local-path &>/dev/null; then
    ok "local-path StorageClass found"
  else
    warn "local-path StorageClass not found — PVCs may not bind"
    warn "Install: kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"
  fi

  [[ $missing -eq 0 ]] || { error "Fix the above and retry."; exit 1; }
}

# ── Build & import bridge image ───────────────────────────────────────────────
build_bridge() {
  section "Building Zenoh-Iceberg Bridge"

  if [[ ! -f "$BRIDGE_DIR/main.go" ]]; then
    error "Bridge source not found at $BRIDGE_DIR/main.go"
    exit 1
  fi

  info "Building Docker image: $BRIDGE_IMAGE"
  docker build -t "$BRIDGE_IMAGE" "$BRIDGE_DIR"
  ok "Image built"

  info "Importing image into K3s containerd ..."
  docker save "$BRIDGE_IMAGE" | sudo k3s ctr images import -
  ok "Image imported into K3s: $BRIDGE_IMAGE"

  # Verify import
  if sudo k3s ctr images ls | grep -q "zenoh-iceberg-bridge"; then
    ok "Image verified in K3s image store"
  else
    warn "Image not found in K3s store after import — check containerd logs"
  fi
}

# ── Apply manifest ─────────────────────────────────────────────────────────────
apply_manifest() {
  section "Applying K3s manifest"
  info "Applying $MANIFEST ..."
  kubectl apply -f "$MANIFEST"
  ok "Manifest applied — 19 resources"
}

# ── Wait for pods ──────────────────────────────────────────────────────────────
wait_for_pods() {
  section "Waiting for pods to become ready"

  local deployments=(
    "ipfs-node"
    "zenoh"
    "iceberg-rest-catalog"
    "trino-coordinator"
    "trino-worker"
    "zenoh-iceberg-bridge"
  )

  for deploy in "${deployments[@]}"; do
    info "Waiting for deployment/$deploy ..."
    kubectl rollout status deployment/"$deploy" \
      -n "$NAMESPACE" \
      --timeout=300s \
      && ok "$deploy ready" \
      || warn "$deploy rollout timed out — check: kubectl describe pod -n $NAMESPACE -l app=$deploy"
  done

  echo ""
  kubectl get pods -n "$NAMESPACE" -o wide
}

# ── Smoke test ─────────────────────────────────────────────────────────────────
run_smoke_test() {
  section "Smoke test"

  # Get node IP
  local node_ip
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  info "K3s node IP: $node_ip"

  # Iceberg catalog
  info "Testing Iceberg REST catalog (port-forward) ..."
  kubectl port-forward -n "$NAMESPACE" svc/iceberg-rest-catalog 8181:8181 &>/dev/null &
  local pf_pid=$!
  sleep 3
  if curl -sf "http://localhost:8181/v1/config" | grep -q "defaults"; then
    ok "Iceberg catalog responding"
  else
    warn "Iceberg catalog not yet ready"
  fi
  kill $pf_pid 2>/dev/null || true

  # Trino via NodePort
  info "Testing Trino coordinator via NodePort :30080 ..."
  if curl -sf "http://${node_ip}:30080/v1/info" | grep -q "starting\|true"; then
    ok "Trino responding at http://${node_ip}:30080"
  else
    warn "Trino not yet ready — it can take up to 90s"
  fi

  # Bridge logs
  info "Bridge sync log (last 10 lines):"
  kubectl logs -n "$NAMESPACE" deploy/zenoh-iceberg-bridge --tail=10 2>/dev/null || warn "Bridge not yet logging"

  # Trino SQL via REST
  info "Running SQL: SHOW CATALOGS ..."
  local response
  response=$(curl -sf \
    -X POST "http://${node_ip}:30080/v1/statement" \
    -H "X-Trino-User: test" \
    -H "Content-Type: application/json" \
    -d "SHOW CATALOGS" 2>/dev/null || echo "")

  if echo "$response" | grep -q "nextUri\|iceberg"; then
    ok "Trino SQL query succeeded"
  else
    warn "Trino SQL query not ready yet — retry in 60s: ./deploy-k3s.sh --test"
  fi
}

# ── Status ─────────────────────────────────────────────────────────────────────
show_status() {
  section "Cluster status"
  echo ""
  echo -e "${BOLD}Pods:${NC}"
  kubectl get pods -n "$NAMESPACE" -o wide
  echo ""
  echo -e "${BOLD}Services:${NC}"
  kubectl get svc -n "$NAMESPACE"
  echo ""
  echo -e "${BOLD}PVCs:${NC}"
  kubectl get pvc -n "$NAMESPACE"

  local node_ip
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")

  section "Access"
  echo -e "  ${CYAN}Trino SQL (NodePort)${NC}  →  http://${node_ip}:30080"
  echo -e "  ${CYAN}Port-forward Trino${NC}    →  kubectl port-forward -n $NAMESPACE svc/trino-coordinator 8080:8080"
  echo -e "  ${CYAN}Trino CLI${NC}             →  kubectl exec -n $NAMESPACE deploy/trino-coordinator -- trino"
  echo -e "  ${CYAN}Bridge logs${NC}           →  kubectl logs -n $NAMESPACE deploy/zenoh-iceberg-bridge -f"
  echo -e "  ${CYAN}Bridge metrics${NC}        →  kubectl port-forward -n $NAMESPACE svc/zenoh-iceberg-bridge 9090:9090"
}

# ── Delete ─────────────────────────────────────────────────────────────────────
delete_resources() {
  local clean="${1:-false}"
  section "Deleting resources"

  if [[ "$clean" == "true" ]]; then
    warn "Deleting ALL resources including PVCs — all data will be lost"
    kubectl delete -f "$MANIFEST" --ignore-not-found=true
    kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found=true
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
    ok "All resources and data deleted"
  else
    kubectl delete -f "$MANIFEST" --ignore-not-found=true
    ok "Resources deleted (PVCs preserved — data safe)"
  fi
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════╗
  ║       iceberg-decentralized — K3s Deploy         ║
  ║     Trino + Iceberg + IPFS + Zenoh + Bridge      ║
  ╚══════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

case "$MODE" in
  deploy)
    check_prerequisites
    build_bridge
    apply_manifest
    wait_for_pods
    run_smoke_test
    show_status
    ;;
  apply)
    check_prerequisites
    apply_manifest
    wait_for_pods
    show_status
    ;;
  delete)
    delete_resources false
    ;;
  clean)
    delete_resources true
    ;;
  status)
    show_status
    ;;
  logs)
    kubectl logs -n "$NAMESPACE" deploy/zenoh-iceberg-bridge -f
    ;;
  test)
    run_smoke_test
    ;;
esac
