# Deployment Guide

This guide covers two deployment targets for **iceberg-decentralized**:

| Target | Best for | Script |
|--------|----------|--------|
| [Docker Desktop](#docker-desktop) | Local development, demos, single-machine testing | `deploy-docker.sh` / `deploy-docker.ps1` |
| [K3s](#k3s) | Production, multi-node, edge, research clusters | `deploy-k3s.sh` + `k3s-manifest.yaml` |

Both deployments run the same 7 services and expose the same ports.

---

## Prerequisites

### All targets
- Git
- Docker Desktop 4.x+ (includes Docker Engine + Compose v2)
- 8 GB RAM minimum allocated to Docker / K3s
- The bridge image must be built from source (see step 1 in each section)

### K3s only
- A running K3s cluster (`curl -sfL https://get.k3s.io | sh -`)
- `kubectl` configured and pointing at the cluster
- `local-path` StorageClass (installed by default with K3s)

---

## Docker Desktop

### File layout

```
deploy/docker-desktop/
├── docker-compose.yml          ← 7 services, volumes, health checks
├── deploy-docker.sh            ← Bash script  (Mac / Linux / WSL)
├── deploy-docker.ps1           ← PowerShell   (Windows)
└── config/
    ├── coordinator/
    │   ├── config.properties   ← Trino coordinator settings
    │   ├── jvm.config          ← JVM heap / GC flags
    │   └── node.properties     ← Node identity
    ├── worker/
    │   ├── config.properties   ← Trino worker settings
    │   ├── jvm.config
    │   └── node.properties
    └── catalog/
        └── iceberg.properties  ← Iceberg REST catalog connector
```

### Quick start

#### Windows (PowerShell)

```powershell
# 1. Open PowerShell in the deploy\docker-desktop folder
cd deploy\docker-desktop

# 2. Allow script execution (first time only)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 3. Full deploy — builds bridge image, pulls all images, starts stack, runs smoke test
.\deploy-docker.ps1

# Done. Trino is at http://localhost:8080
```

#### Mac / Linux / WSL (Bash)

```bash
cd deploy/docker-desktop
chmod +x deploy-docker.sh
./deploy-docker.sh
```

### Script modes

Both `deploy-docker.sh` and `deploy-docker.ps1` accept the same modes:

```bash
# Bash
./deploy-docker.sh              # full deploy (default)
./deploy-docker.sh --up         # compose up only (skips bridge build)
./deploy-docker.sh --down       # stop containers, keep volumes
./deploy-docker.sh --clean      # stop containers AND delete volumes (all data lost)
./deploy-docker.sh --status     # show container state + port map
./deploy-docker.sh --logs       # tail all service logs
./deploy-docker.sh --test       # re-run smoke tests against running stack
```

```powershell
# PowerShell
.\deploy-docker.ps1 -Mode deploy
.\deploy-docker.ps1 -Mode up
.\deploy-docker.ps1 -Mode down
.\deploy-docker.ps1 -Mode clean
.\deploy-docker.ps1 -Mode status
.\deploy-docker.ps1 -Mode logs
.\deploy-docker.ps1 -Mode test
```

### Services and ports

| Container | Image | Host port | Purpose |
|-----------|-------|-----------|---------|
| `iceberg-ipfs` | `ipfs/kubo:v0.26.0` | `5001` (API), `4001` (swarm), `8888` (gateway) | Content-addressed block store |
| `iceberg-zenoh` | `eclipse/zenoh:0.11.0` | `7447` (protocol), `8000` (REST) | Peer discovery & partition gossip |
| `iceberg-catalog` | `tabulario/iceberg-rest:0.10.0` | `8181` | Iceberg table registry |
| `iceberg-trino-coordinator` | `trinodb/trino:435` | **`8080`** | SQL entry point |
| `iceberg-trino-worker-1` | `trinodb/trino:435` | — | Query execution |
| `iceberg-trino-worker-2` | `trinodb/trino:435` | — | Query execution |
| `iceberg-bridge` | `optimusdb/zenoh-iceberg-bridge:0.1.0` | `9090` (metrics) | Zenoh ↔ Iceberg sync |

### Docker Desktop memory settings

The stack needs at least **6 GB** allocated to Docker:

1. Open Docker Desktop → **Settings** → **Resources**
2. Set **Memory** to `6144` MB or higher
3. Click **Apply & Restart**

### Startup sequence

The script waits for each service to pass its health check before proceeding:

```
IPFS → Zenoh → Iceberg catalog → Trino coordinator → Workers → Bridge
```

Trino takes the longest (~60–90 seconds on first start while it warms up the JVM).

### Verify manually

```bash
# Iceberg catalog
curl http://localhost:8181/v1/config

# IPFS node identity
curl -X POST http://localhost:5001/api/v0/id

# Zenoh router info
curl http://localhost:8000/@/router/local

# Trino info
curl http://localhost:8080/v1/info

# Bridge health
curl http://localhost:9090/healthz

# Bridge Prometheus metrics
curl http://localhost:9090/metrics
```

### Connect with Trino CLI

```bash
# Run trino inside the coordinator container
docker exec -it iceberg-trino-coordinator trino

# Or install the CLI locally and connect
trino --server http://localhost:8080
```

### Connect with DBeaver

1. **New Database Connection** → select **Trino**
2. Host: `localhost` Port: `8080`
3. Database: `iceberg`
4. Username: any value (no auth by default)
5. **Test Connection** → **Finish**

### First SQL queries

```sql
-- Create a schema backed by the IPFS warehouse volume
CREATE SCHEMA IF NOT EXISTS iceberg.energy
WITH (location = '/iceberg-warehouse/energy');

-- Create a partitioned Iceberg table
CREATE TABLE IF NOT EXISTS iceberg.energy.readings (
    ts        TIMESTAMP(6),
    node_id   VARCHAR,
    metric    VARCHAR,
    value     DOUBLE
)
WITH (
    format       = 'PARQUET',
    partitioning = ARRAY['day(ts)']
);

-- Insert a row
INSERT INTO iceberg.energy.readings
VALUES (CURRENT_TIMESTAMP, 'docker-node', 'solar_kw', 42.5);

-- Query it
SELECT * FROM iceberg.energy.readings;

-- Time-travel: query a previous snapshot
SELECT * FROM iceberg.energy.readings
FOR VERSION AS OF <snapshot_id>;

-- Show available snapshots
SELECT * FROM iceberg.energy."readings$snapshots";
```

### Watch the bridge sync

```bash
docker logs -f iceberg-bridge

# Expected output:
# [INFO] zenoh-iceberg-bridge starting
# [INFO] node_id=docker-desktop-node ...
# [INFO] published energy.readings (snapshot 88273...)
```

### Teardown

```bash
# Stop containers, keep data volumes
./deploy-docker.sh --down          # bash
.\deploy-docker.ps1 -Mode down     # PowerShell

# Stop containers AND delete all data
./deploy-docker.sh --clean
.\deploy-docker.ps1 -Mode clean
```

---

## K3s

### File layout

```
deploy/k3s/
├── k3s-manifest.yaml   ← All 19 Kubernetes resources in one file
└── deploy-k3s.sh       ← Bash script: build, import, apply, verify, teardown
```

### Quick start

```bash
cd deploy/k3s
chmod +x deploy-k3s.sh

# Full deploy: builds bridge image, imports into K3s, applies manifest, waits for pods
./deploy-k3s.sh
```

### What the script does

1. **Preflight** — checks `kubectl`, `docker`, cluster access, and `local-path` StorageClass
2. **Build** — `docker build` the bridge image from `../../bridge/`
3. **Import** — `docker save | k3s ctr images import` loads it into K3s containerd (no registry needed)
4. **Apply** — `kubectl apply -f k3s-manifest.yaml` creates all 19 resources
5. **Wait** — `kubectl rollout status` for each Deployment
6. **Smoke test** — hits Iceberg catalog, Trino NodePort, IPFS API, bridge healthz, runs `SHOW CATALOGS`
7. **Status** — prints pod table and access URLs

### Script modes

```bash
./deploy-k3s.sh            # full deploy (default)
./deploy-k3s.sh --apply    # apply manifest only (bridge image already imported)
./deploy-k3s.sh --status   # pod/service/PVC status + access URLs
./deploy-k3s.sh --test     # re-run smoke tests
./deploy-k3s.sh --logs     # tail bridge logs
./deploy-k3s.sh --delete   # delete all resources, keep PVCs (data safe)
./deploy-k3s.sh --clean    # delete everything including PVCs (all data lost)
```

### Resources created

The manifest (`k3s-manifest.yaml`) creates exactly 19 resources:

| # | Kind | Name | Notes |
|---|------|------|-------|
| 1 | Namespace | `iceberg-decentralized` | All resources live here |
| 2 | PersistentVolumeClaim | `iceberg-metadata` | 10Gi, Iceberg warehouse |
| 3 | PersistentVolumeClaim | `ipfs-data` | 20Gi, IPFS block store |
| 4 | ConfigMap | `trino-coordinator-config` | `config.properties`, `jvm.config`, `node.properties` |
| 5 | ConfigMap | `trino-worker-config` | Same for workers |
| 6 | ConfigMap | `trino-catalog-iceberg` | `iceberg.properties` connector |
| 7 | Deployment | `ipfs-node` | IPFS Kubo with init container |
| 8 | Service | `ipfs-node` | ClusterIP, ports 5001/4001/8080 |
| 9 | Deployment | `zenoh` | Zenoh router |
| 10 | Service | `zenoh` | ClusterIP, ports 7447/8000 |
| 11 | Deployment | `iceberg-rest-catalog` | Mounts `iceberg-metadata` PVC |
| 12 | Service | `iceberg-rest-catalog` | ClusterIP, port 8181 |
| 13 | Deployment | `trino-coordinator` | Mounts all 3 ConfigMaps |
| 14 | Service | `trino-coordinator` | ClusterIP, port 8080 |
| 15 | Service | `trino-coordinator-external` | **NodePort :30080** — external SQL access |
| 16 | Deployment | `trino-worker` | 2 replicas, mounts ConfigMaps |
| 17 | Service | `trino-worker` | Headless — coordinator discovers workers via DNS |
| 18 | Deployment | `zenoh-iceberg-bridge` | NODE_ID injected from `spec.nodeName` |
| 19 | Service | `zenoh-iceberg-bridge` | ClusterIP, port 9090 (metrics) |

### Bridge image — no registry required

The script uses `k3s ctr images import` to inject the image directly into K3s containerd. No Docker Hub, no private registry needed:

```bash
# What the script does automatically:
docker build -t optimusdb/zenoh-iceberg-bridge:0.1.0 ../../bridge/
docker save optimusdb/zenoh-iceberg-bridge:0.1.0 | sudo k3s ctr images import -

# Verify it's there:
sudo k3s ctr images ls | grep zenoh-iceberg-bridge
```

### Apply without the script

If you only want to apply the manifest directly:

```bash
# Build and import bridge image first (required)
docker build -t optimusdb/zenoh-iceberg-bridge:0.1.0 ../../bridge/
docker save optimusdb/zenoh-iceberg-bridge:0.1.0 | sudo k3s ctr images import -

# Apply everything
kubectl apply -f k3s-manifest.yaml

# Watch pods come up
kubectl get pods -n iceberg-decentralized -w
```

### Verify deployment

```bash
# All pods should reach Running/Ready
kubectl get pods -n iceberg-decentralized

# Get the node IP for NodePort access
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Trino via NodePort
curl http://${NODE_IP}:30080/v1/info

# Port-forward for local access
kubectl port-forward -n iceberg-decentralized svc/trino-coordinator 8080:8080 &
trino --server http://localhost:8080

# Bridge sync logs
kubectl logs -n iceberg-decentralized deploy/zenoh-iceberg-bridge -f

# Bridge metrics
kubectl port-forward -n iceberg-decentralized svc/zenoh-iceberg-bridge 9090:9090 &
curl http://localhost:9090/metrics
```

### Scaling workers

```bash
# Scale up to 4 workers
kubectl scale deployment trino-worker -n iceberg-decentralized --replicas=4

# Scale back down
kubectl scale deployment trino-worker -n iceberg-decentralized --replicas=2
```

### Teardown

```bash
# Remove all resources, keep PVC data
./deploy-k3s.sh --delete

# Remove everything including volumes (irreversible)
./deploy-k3s.sh --clean

# Or directly with kubectl
kubectl delete -f k3s-manifest.yaml
kubectl delete namespace iceberg-decentralized   # removes PVCs too
```

---

## Troubleshooting

### Docker Desktop

| Symptom | Fix |
|---------|-----|
| `Cannot connect to Docker daemon` | Open Docker Desktop, wait for the whale icon to stop animating |
| `Ports are not available: 8080` | Another service is using port 8080. Stop it or change `ports` in `docker-compose.yml` |
| Trino workers not joining | Wait 90s — workers register after the coordinator passes its health check |
| Bridge shows `CID unreachable` | IPFS swarm peering takes ~60s on startup. Normal on first run |
| Out of memory / containers killed | Increase Docker Desktop memory: Settings → Resources → Memory |
| `failed to build bridge image` | Make sure `../../bridge/main.go` exists — you need the full repo, not just the deploy folder |

### K3s

| Symptom | Fix |
|---------|-----|
| `PVC stuck in Pending` | Check StorageClass: `kubectl get storageclass`. Install local-path if missing |
| `ImagePullBackOff` on bridge | Image not imported into K3s. Run `docker save ... \| sudo k3s ctr images import -` |
| `ImagePullBackOff` on other images | K3s node has no internet access. Pre-pull on a connected machine and import |
| Trino pods in `CrashLoopBackOff` | ConfigMap not mounted — check: `kubectl describe pod -n iceberg-decentralized <pod>` |
| Workers not registering | Check discovery URI in ConfigMap matches the coordinator Service name exactly |
| Bridge `CID unreachable` warnings | Expected until IPFS swarm connects. Check: `kubectl exec -n iceberg-decentralized deploy/ipfs-node -- ipfs swarm peers` |
| NodePort not reachable | K3s firewall — open port 30080: `sudo ufw allow 30080/tcp` |

---

## Port reference

| Port | Protocol | Exposed by | Description |
|------|----------|------------|-------------|
| `8080` | HTTP | Docker host / K3s pod | Trino SQL (internal) |
| `30080` | HTTP | K3s NodePort | Trino SQL (external) |
| `8181` | HTTP | Internal only | Iceberg REST catalog |
| `5001` | HTTP | Docker host | IPFS Kubo API |
| `4001` | TCP | Docker host | IPFS Swarm (P2P) |
| `8888` | HTTP | Docker host | IPFS Gateway |
| `7447` | TCP | Docker host | Zenoh protocol |
| `8000` | HTTP | Internal only | Zenoh REST API |
| `9090` | HTTP | Docker host | Bridge metrics (Prometheus) |
