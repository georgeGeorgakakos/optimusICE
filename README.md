# iceberg-decentralized Helm Chart

A decentralized analytics platform combining **Trino**, **Apache Iceberg**,
**IPFS (Kubo)**, **Zenoh**, and the custom **Zenoh-Iceberg Bridge**.

## Architecture

```
SQL Client (DBeaver / OptimusDDC / Jupyter)
        │  NodePort 30080
        ▼
  Trino Coordinator ──────────────── Trino Workers (x2)
        │                                   │
        │  REST (8181)                      │
        ▼                                   │
  Iceberg REST Catalog ◄──────────────────────
        │  (PVC: iceberg-metadata)
        │
        ▼
  ┌─────────────────────────────────────────────┐
  │         Zenoh-Iceberg Bridge                │
  │  - publishes local partition map → Zenoh    │
  │  - pulls remote announcements from Zenoh    │
  │  - verifies IPFS CID reachability           │
  │  - registers valid remote partitions        │
  │    into Iceberg REST catalog                │
  └────────────┬──────────────────┬────────────┘
               │                  │
               ▼                  ▼
           Zenoh Router        IPFS Node (Kubo)
           (port 7447)         (API 5001, Swarm 4001)
           mesh gossip         content-addressed data files
```

## What was added vs the original chart

| # | Gap | Fix |
|---|-----|-----|
| 1 | No Services | Added ClusterIP Services for all components + NodePort for Trino |
| 2 | No Trino ConfigMaps | Added `trino-configmaps.yaml` with `config.properties`, `jvm.config`, `node.properties`, `catalog/iceberg.properties` |
| 3 | IPFS not wired to Trino | Iceberg catalog now uses REST catalog; bridge syncs IPFS CIDs |
| 4 | PVC not mounted | PVC mounted in Iceberg REST catalog pod at `/iceberg-warehouse` |
| 5 | No Iceberg catalog service | Added `iceberg-rest-catalog.yaml` (tabulario/iceberg-rest) |
| 6 | No storageClassName | `storageClassName: local-path` (K3s default), configurable |
| 7 | IPFS no persistent storage | Added dedicated IPFS PVC + init container |
| 8 | No resource limits | Limits added to all components |
| 9 | No appVersion | Added to Chart.yaml |
| 10 | No probes | readinessProbe + livenessProbe on all Deployments |
| 11 | No external access | Trino NodePort 30080 |
| 12 | No namespace | `iceberg-decentralized` namespace with template |
| 13 | Zenoh peer mode | Changed to `router` mode for cross-host relay |
| 14 | enable flags ignored | `{{- if .Values.ipfs.enable }}` guards in templates |
| 15 | **No bridge** (core gap) | Added `bridge.yaml` + Go source in `bridge/` |

## Prerequisites

- K3s (or any Kubernetes 1.25+) with `local-path` storage provisioner
- Helm 3.x
- Build & push the bridge image (or use a pre-built one):

```bash
cd bridge
docker build -t optimusdb/zenoh-iceberg-bridge:0.1.0 .
docker push optimusdb/zenoh-iceberg-bridge:0.1.0
# Or load into K3s directly:
docker save optimusdb/zenoh-iceberg-bridge:0.1.0 | k3s ctr images import -
```

## Install

```bash
helm install iceberg-decentralized . \
  --namespace iceberg-decentralized \
  --create-namespace
```

## Verify

```bash
# All pods should be Running
kubectl get pods -n iceberg-decentralized

# Check bridge logs (partition sync)
kubectl logs -n iceberg-decentralized deploy/zenoh-iceberg-bridge -f

# Connect to Trino via CLI
kubectl exec -n iceberg-decentralized deploy/trino-coordinator -- \
  trino --server http://localhost:8080

# Or externally (NodePort)
trino --server http://<node-ip>:30080

# Create a test table
trino> CREATE SCHEMA iceberg.energy WITH (location = '/iceberg-warehouse/energy');
trino> CREATE TABLE iceberg.energy.readings (
         ts TIMESTAMP, node_id VARCHAR, value DOUBLE
       ) WITH (format = 'PARQUET', partitioning = ARRAY['day(ts)']);
trino> INSERT INTO iceberg.energy.readings VALUES (NOW(), 'node-1', 42.5);
trino> SELECT * FROM iceberg.energy.readings;
```

## Customisation

| Key | Default | Description |
|-----|---------|-------------|
| `trino.workers.replicas` | 2 | Scale workers for more parallelism |
| `zenoh.mode` | router | Use `peer` for single-host dev |
| `iceberg.storage.storageClassName` | local-path | Change for multi-node shared storage |
| `bridge.syncIntervalSeconds` | 30 | Partition gossip frequency |
| `trino.nodePort.port` | 30080 | External SQL access port |
