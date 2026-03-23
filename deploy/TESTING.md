# Testing Guide

End-to-end test scenarios for **iceberg-decentralized**, covering every layer of the stack: infrastructure health, SQL queries, Iceberg features, bridge sync, IPFS data flow, Zenoh gossip, and failure/recovery.

All scenarios work against both [Docker Desktop](#running-the-tests-docker-desktop) and [K3s](#running-the-tests-k3s). Prerequisites and connection commands differ — see the setup section for each target.

---

## Table of Contents

- [Setup](#setup)
  - [Docker Desktop](#running-the-tests-docker-desktop)
  - [K3s](#running-the-tests-k3s)
- [Scenario 1 — Infrastructure Health](#scenario-1--infrastructure-health)
- [Scenario 2 — First SQL Query](#scenario-2--first-sql-query)
- [Scenario 3 — Iceberg Table Lifecycle](#scenario-3--iceberg-table-lifecycle)
- [Scenario 4 — Partitioning and Partition Pruning](#scenario-4--partitioning-and-partition-pruning)
- [Scenario 5 — Time-Travel Queries](#scenario-5--time-travel-queries)
- [Scenario 6 — Schema Evolution](#scenario-6--schema-evolution)
- [Scenario 7 — Bridge Sync and Zenoh Gossip](#scenario-7--bridge-sync-and-zenoh-gossip)
- [Scenario 8 — IPFS Content Addressing](#scenario-8--ipfs-content-addressing)
- [Scenario 9 — Concurrent Writes and ACID](#scenario-9--concurrent-writes-and-acid)
- [Scenario 10 — Worker Failure and Recovery](#scenario-10--worker-failure-and-recovery)
- [Scenario 11 — Coordinator Restart](#scenario-11--coordinator-restart)
- [Scenario 12 — Bridge Restart and Re-sync](#scenario-12--bridge-restart-and-re-sync)
- [Scenario 13 — Large Dataset Query](#scenario-13--large-dataset-query)
- [Scenario 14 — Bridge Metrics Validation](#scenario-14--bridge-metrics-validation)
- [Expected Outputs Reference](#expected-outputs-reference)

---

## Setup

### Running the tests — Docker Desktop

Start the stack if not already running:

```bash
# Bash (Mac/Linux/WSL)
cd deploy/docker-desktop && ./deploy-docker.sh

# PowerShell (Windows)
cd deploy\docker-desktop && .\deploy-docker.ps1
```

Open a Trino session. All SQL in this guide runs here:

```bash
# Option A — Trino CLI inside the container (recommended, no install needed)
docker exec -it iceberg-trino-coordinator trino

# Option B — Trino CLI installed locally
trino --server http://localhost:8080

# Option C — DBeaver
# Host: localhost  Port: 8080  Database: iceberg
```

Set helper variables for `curl` commands (run once per terminal session):

```bash
TRINO="http://localhost:8080"
CATALOG="http://localhost:8181"
IPFS="http://localhost:5001"
ZENOH="http://localhost:8000"
BRIDGE="http://localhost:9090"
```

### Running the tests — K3s

```bash
# Get the node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

TRINO="http://${NODE_IP}:30080"
CATALOG="http://localhost:8181"   # use port-forward for internal services
IPFS="http://localhost:5001"
ZENOH="http://localhost:8000"
BRIDGE="http://localhost:9090"

# Port-forward internal services (run in background terminals)
kubectl port-forward -n iceberg-decentralized svc/iceberg-rest-catalog 8181:8181 &
kubectl port-forward -n iceberg-decentralized svc/ipfs-node 5001:5001 &
kubectl port-forward -n iceberg-decentralized svc/zenoh 8000:8000 &
kubectl port-forward -n iceberg-decentralized svc/zenoh-iceberg-bridge 9090:9090 &

# Open Trino CLI
kubectl exec -n iceberg-decentralized -it deploy/trino-coordinator -- trino
```

---

## Scenario 1 — Infrastructure Health

**Goal:** Confirm every service is up and responding before running any tests.

**Expected duration:** 2 minutes

### 1.1 — Container / pod status

```bash
# Docker Desktop
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# K3s
kubectl get pods -n iceberg-decentralized -o wide
```

**Expected:** All 7 containers/pods show `healthy` or `Running (1/1 Ready)`. None in `Restarting` or `CrashLoopBackOff`.

### 1.2 — Trino coordinator

```bash
curl -s ${TRINO}/v1/info | python3 -m json.tool
```

**Expected:**
```json
{
  "nodeVersion": { "version": "435" },
  "environment": "production",
  "starting": false,
  "uptime": "..."
}
```

`"starting": false` confirms Trino has fully initialised.

### 1.3 — Trino workers registered

```bash
curl -s ${TRINO}/v1/node | python3 -m json.tool
```

**Expected:** A JSON array with **3 entries** — 1 coordinator + 2 workers. Each entry has `uri`, `recentRequests`, `recentFailures`.

### 1.4 — Iceberg REST catalog

```bash
curl -s ${CATALOG}/v1/config | python3 -m json.tool
```

**Expected:**
```json
{
  "defaults": {},
  "overrides": {}
}
```

HTTP 200 means the catalog is up and warehouse volume is mounted.

### 1.5 — IPFS node

```bash
curl -s -X POST ${IPFS}/api/v0/id | python3 -m json.tool
```

**Expected:** A JSON object with `ID` (a multihash), `PublicKey`, `Addresses`, `AgentVersion` containing `kubo`.

### 1.6 — Zenoh router

```bash
curl -s ${ZENOH}/@/router/local | python3 -m json.tool
```

**Expected:** JSON with `"whatami": "Router"`, a `zid` field, and `locators` array showing `tcp/...` addresses.

### 1.7 — Bridge health

```bash
curl -s ${BRIDGE}/healthz
```

**Expected:** `ok` (plain text, HTTP 200).

### 1.8 — Bridge metrics baseline

```bash
curl -s ${BRIDGE}/metrics
```

**Expected:** Prometheus text format with three counters, all at 0 on a fresh deployment:
```
bridge_partitions_published_total 0
bridge_partitions_registered_total 0
bridge_partitions_rejected_total 0
```

---

## Scenario 2 — First SQL Query

**Goal:** Confirm Trino can execute SQL end-to-end and the Iceberg catalog connector is wired correctly.

**Expected duration:** 3 minutes

### 2.1 — Show catalogs

```sql
SHOW CATALOGS;
```

**Expected:**
```
  Catalog
---------
 iceberg
 system
 tpcds
 tpch
(4 rows)
```

`iceberg` must be present — this confirms the REST catalog connector is loaded.

### 2.2 — Show schemas

```sql
SHOW SCHEMAS FROM iceberg;
```

**Expected:** At minimum `information_schema`. No error means the catalog REST endpoint is reachable from inside Trino.

### 2.3 — Create a test schema

```sql
CREATE SCHEMA IF NOT EXISTS iceberg.test
WITH (location = '/iceberg-warehouse/test');
```

**Expected:** `CREATE SCHEMA` — no error.

### 2.4 — Verify schema exists

```sql
SHOW SCHEMAS FROM iceberg;
```

**Expected:** `test` now appears in the list alongside `information_schema`.

### 2.5 — Drop the schema

```sql
DROP SCHEMA iceberg.test;
```

**Expected:** `DROP SCHEMA` — confirms write path to catalog and warehouse works.

---

## Scenario 3 — Iceberg Table Lifecycle

**Goal:** Create a table, insert data, query it, and drop it. This exercises the full Iceberg write and read path.

**Expected duration:** 5 minutes

### 3.1 — Setup

```sql
CREATE SCHEMA IF NOT EXISTS iceberg.energy
WITH (location = '/iceberg-warehouse/energy');
```

### 3.2 — Create table

```sql
CREATE TABLE iceberg.energy.readings (
    ts        TIMESTAMP(6),
    node_id   VARCHAR,
    metric    VARCHAR,
    value     DOUBLE
)
WITH (
    format       = 'PARQUET',
    partitioning = ARRAY['day(ts)']
);
```

**Expected:** `CREATE TABLE`

### 3.3 — Verify table metadata

```sql
DESCRIBE iceberg.energy.readings;
```

**Expected:** 4 columns — `ts`, `node_id`, `metric`, `value` with correct types.

```sql
SHOW CREATE TABLE iceberg.energy.readings;
```

**Expected:** DDL showing `format = 'PARQUET'` and `partitioning = ARRAY['day(ts)']`.

### 3.4 — Insert data

```sql
INSERT INTO iceberg.energy.readings VALUES
    (TIMESTAMP '2026-01-15 08:00:00.000000', 'node-1', 'solar_kw',   42.5),
    (TIMESTAMP '2026-01-15 09:00:00.000000', 'node-1', 'solar_kw',   51.2),
    (TIMESTAMP '2026-01-15 10:00:00.000000', 'node-2', 'wind_kw',    88.0),
    (TIMESTAMP '2026-01-16 08:00:00.000000', 'node-2', 'solar_kw',   35.1),
    (TIMESTAMP '2026-01-16 14:00:00.000000', 'node-3', 'battery_kwh', 120.0);
```

**Expected:** `INSERT: 5 rows`

### 3.5 — Full table scan

```sql
SELECT * FROM iceberg.energy.readings
ORDER BY ts;
```

**Expected:** All 5 rows returned, ordered by timestamp.

### 3.6 — Filtered query

```sql
SELECT node_id, metric, value
FROM iceberg.energy.readings
WHERE metric = 'solar_kw'
ORDER BY ts;
```

**Expected:** 3 rows — the three `solar_kw` entries.

### 3.7 — Aggregation

```sql
SELECT
    node_id,
    metric,
    ROUND(AVG(value), 2) AS avg_value,
    COUNT(*)             AS readings
FROM iceberg.energy.readings
GROUP BY node_id, metric
ORDER BY node_id;
```

**Expected:** One row per `(node_id, metric)` combination with correct averages.

### 3.8 — Update a row

```sql
UPDATE iceberg.energy.readings
SET value = 99.9
WHERE node_id = 'node-1'
  AND metric  = 'solar_kw'
  AND ts      = TIMESTAMP '2026-01-15 08:00:00.000000';
```

**Expected:** `UPDATE: 1 row` — confirms Iceberg ACID write-on-update (copy-on-write).

```sql
SELECT value FROM iceberg.energy.readings
WHERE node_id = 'node-1'
  AND ts      = TIMESTAMP '2026-01-15 08:00:00.000000';
```

**Expected:** `99.9`

### 3.9 — Delete a row

```sql
DELETE FROM iceberg.energy.readings
WHERE node_id = 'node-3';
```

**Expected:** `DELETE: 1 row`

```sql
SELECT COUNT(*) FROM iceberg.energy.readings;
```

**Expected:** `4` (5 inserted − 1 deleted)

---

## Scenario 4 — Partitioning and Partition Pruning

**Goal:** Confirm that day-based partitioning is working and Trino is skipping irrelevant partitions.

**Expected duration:** 5 minutes

### 4.1 — Check partition metadata

```sql
SELECT * FROM iceberg.energy."readings$partitions";
```

**Expected:** 2 rows — one for `2026-01-15`, one for `2026-01-16`. Each shows `record_count`, `file_count`, `total_size`.

### 4.2 — Single-partition query (should skip the other partition)

```sql
SELECT ts, node_id, value
FROM iceberg.energy.readings
WHERE ts >= TIMESTAMP '2026-01-15 00:00:00'
  AND ts <  TIMESTAMP '2026-01-16 00:00:00';
```

**Expected:** 3 rows (the Jan 15 entries only).

### 4.3 — Verify partition pruning in the query plan

```sql
EXPLAIN
SELECT * FROM iceberg.energy.readings
WHERE ts >= TIMESTAMP '2026-01-16 00:00:00';
```

**Expected output contains:**
```
- ScanFilter[table = iceberg:energy/readings ...]
    partitions: 1 of 2
```

The `1 of 2` confirms only one partition was scanned.

### 4.4 — Insert data for a new partition (new day)

```sql
INSERT INTO iceberg.energy.readings VALUES
    (TIMESTAMP '2026-01-17 07:00:00.000000', 'node-1', 'solar_kw', 60.0);
```

```sql
SELECT * FROM iceberg.energy."readings$partitions"
ORDER BY partition;
```

**Expected:** Now **3 partitions** — Jan 15, Jan 16, Jan 17.

---

## Scenario 5 — Time-Travel Queries

**Goal:** Verify Iceberg snapshot history and time-travel reads.

**Expected duration:** 5 minutes

### 5.1 — List all snapshots

```sql
SELECT
    snapshot_id,
    committed_at,
    operation,
    summary
FROM iceberg.energy."readings$snapshots"
ORDER BY committed_at;
```

**Expected:** Multiple rows — one per write operation (INSERT, UPDATE, DELETE from Scenario 3). Note the first snapshot_id.

### 5.2 — Time-travel to the first snapshot (original 5 rows)

```sql
-- Replace <first_snapshot_id> with the earliest snapshot_id from the query above
SELECT COUNT(*) FROM iceberg.energy.readings
FOR VERSION AS OF <first_snapshot_id>;
```

**Expected:** `5` — the original insert before the DELETE.

### 5.3 — Time-travel to see the deleted row

```sql
SELECT * FROM iceberg.energy.readings
FOR VERSION AS OF <first_snapshot_id>
WHERE node_id = 'node-3';
```

**Expected:** 1 row — `node-3`'s `battery_kwh` reading that was deleted in Scenario 3.

### 5.4 — Time-travel by timestamp

```sql
-- Use a timestamp just before you ran the DELETE
SELECT COUNT(*) FROM iceberg.energy.readings
FOR TIMESTAMP AS OF TIMESTAMP '2026-01-15 12:00:00';
```

**Expected:** Row count matches the state at that point in time (5 if before delete, 4 if after).

### 5.5 — Show file history

```sql
SELECT
    content,
    file_path,
    record_count,
    file_size_in_bytes
FROM iceberg.energy."readings$files"
ORDER BY file_path;
```

**Expected:** Multiple Parquet file entries — one per partition per write operation. File paths start with `/iceberg-warehouse/energy/readings/`.

---

## Scenario 6 — Schema Evolution

**Goal:** Add and drop columns without rewriting existing data.

**Expected duration:** 5 minutes

### 6.1 — Add a new column

```sql
ALTER TABLE iceberg.energy.readings
ADD COLUMN unit VARCHAR;
```

**Expected:** `ALTER TABLE`

### 6.2 — Verify existing rows show NULL for new column

```sql
SELECT ts, node_id, metric, value, unit
FROM iceberg.energy.readings
LIMIT 3;
```

**Expected:** 3 rows, all with `unit = NULL`. Existing Parquet files are **not** rewritten.

### 6.3 — Insert new data with the column populated

```sql
INSERT INTO iceberg.energy.readings VALUES
    (TIMESTAMP '2026-01-18 08:00:00.000000', 'node-1', 'solar_kw', 55.0, 'kW');
```

### 6.4 — Mixed-column query

```sql
SELECT node_id, metric, value, unit
FROM iceberg.energy.readings
ORDER BY ts DESC
LIMIT 3;
```

**Expected:** The new row shows `unit = 'kW'`, older rows show `unit = NULL`. Both are returned from the same query without errors — confirms schema evolution works across Parquet files with different schemas.

### 6.5 — Rename a column

```sql
ALTER TABLE iceberg.energy.readings
RENAME COLUMN unit TO unit_of_measure;
```

**Expected:** `ALTER TABLE`

```sql
DESCRIBE iceberg.energy.readings;
```

**Expected:** Column now named `unit_of_measure`, not `unit`.

### 6.6 — Drop the column

```sql
ALTER TABLE iceberg.energy.readings
DROP COLUMN unit_of_measure;
```

**Expected:** `ALTER TABLE` — column removed from metadata, data files untouched.

---

## Scenario 7 — Bridge Sync and Zenoh Gossip

**Goal:** Confirm the bridge is publishing partition announcements to Zenoh and the sync counters are incrementing.

**Expected duration:** 5 minutes

### 7.1 — Check bridge metrics before sync

```bash
curl -s ${BRIDGE}/metrics
```

Note the current value of `bridge_partitions_published_total`.

### 7.2 — Wait for a sync cycle (30 seconds)

```bash
# Watch the bridge log in real time
# Docker Desktop:
docker logs -f iceberg-bridge

# K3s:
kubectl logs -n iceberg-decentralized deploy/zenoh-iceberg-bridge -f
```

**Expected log lines within 30 seconds:**
```
[INFO] published energy.readings (snapshot 123456789...)
```

Press `Ctrl+C` to stop following.

### 7.3 — Check bridge metrics after sync

```bash
curl -s ${BRIDGE}/metrics
```

**Expected:** `bridge_partitions_published_total` is now greater than 0. Each table in each namespace increments it by 1 per cycle.

### 7.4 — Query Zenoh directly for published partition keys

```bash
curl -s "${ZENOH}/iceberg/partitions/**" | python3 -m json.tool
```

**Expected:** A JSON array of objects. Each contains:
```json
{
  "key": "iceberg/partitions/energy/readings/default/docker-desktop-node",
  "value": {
    "node_id": "docker-desktop-node",
    "namespace": "energy",
    "table": "readings",
    "partition_key": "default",
    "snapshot_id": 123456789,
    "published_at": "2026-01-15T..."
  }
}
```

### 7.5 — Manually trigger a sync via bridge restart

```bash
# Docker Desktop
docker restart iceberg-bridge

# K3s
kubectl rollout restart deployment/zenoh-iceberg-bridge -n iceberg-decentralized
```

```bash
# Watch logs — sync should run immediately on startup
docker logs -f iceberg-bridge
```

**Expected:** Sync runs within 5 seconds of restart (bridge syncs once on startup before entering the tick loop).

### 7.6 — Reduce sync interval for faster testing

```bash
# Docker Desktop — edit docker-compose.yml and change SYNC_INTERVAL_SECONDS to 5, then:
docker compose -f deploy/docker-desktop/docker-compose.yml up -d bridge

# K3s
kubectl set env deployment/zenoh-iceberg-bridge \
  -n iceberg-decentralized \
  SYNC_INTERVAL_SECONDS=5
kubectl rollout status deployment/zenoh-iceberg-bridge -n iceberg-decentralized
```

```bash
curl -s ${BRIDGE}/metrics
# Watch bridge_partitions_published_total increment every 5 seconds
```

---

## Scenario 8 — IPFS Content Addressing

**Goal:** Confirm data files are stored and retrievable via IPFS, and that the bridge CID reachability check works.

**Expected duration:** 5 minutes

### 8.1 — List files written by Iceberg

```sql
SELECT file_path, record_count, file_size_in_bytes
FROM iceberg.energy."readings$files"
ORDER BY file_path;
```

Note one of the `file_path` values — it will look like `/iceberg-warehouse/energy/readings/data/day=2026-01-15/...parquet`.

### 8.2 — Verify the IPFS node is running and has peers

```bash
curl -s -X POST "${IPFS}/api/v0/swarm/peers" | python3 -m json.tool
```

**Expected:** A `Peers` array. Empty is OK for a single-node deployment — IPFS is still functional without peers.

### 8.3 — Add a test file to IPFS and retrieve it by CID

```bash
# Add a small test file
echo "iceberg-decentralized test payload" | \
  curl -s -X POST -F "file=@-" "${IPFS}/api/v0/add" | python3 -m json.tool
```

**Expected output:**
```json
{
  "Name": "",
  "Hash": "QmXxx...",
  "Size": "..."
}
```

Copy the `Hash` value (the CID).

```bash
# Retrieve it back by CID
CID="QmXxx..."   # paste your hash here
curl -s "http://localhost:8888/ipfs/${CID}"
```

**Expected:** `iceberg-decentralized test payload` — the original content.

### 8.4 — Test the bridge CID reachability endpoint

```bash
# The bridge uses /api/v0/block/stat to check CIDs
# Test it directly with the CID from 8.3
curl -s -X POST "${IPFS}/api/v0/block/stat?arg=${CID}"
```

**Expected:**
```json
{
  "Key": "QmXxx...",
  "Size": 43
}
```

HTTP 200 = CID reachable. This is exactly what the bridge checks before registering a remote partition.

### 8.5 — Test with a fake CID (bridge rejection path)

```bash
# This CID does not exist
curl -s -X POST "${IPFS}/api/v0/block/stat?arg=bafyreifakecidthatdoesnotexist123&timeout=3s"
```

**Expected:** HTTP 500 or timeout — the block is not found. This is what causes `bridge_partitions_rejected_total` to increment when a remote announces an unreachable CID.

---

## Scenario 9 — Concurrent Writes and ACID

**Goal:** Confirm Iceberg's ACID guarantees — two concurrent inserts both succeed and no data is lost.

**Expected duration:** 5 minutes

### 9.1 — Get a row count baseline

```sql
SELECT COUNT(*) AS before FROM iceberg.energy.readings;
```

Note the count.

### 9.2 — Run two concurrent inserts (open two terminal sessions)

**Terminal 1:**
```sql
INSERT INTO iceberg.energy.readings
SELECT
    ts,
    'concurrent-node-A' AS node_id,
    'test_metric'       AS metric,
    CAST(sequence AS DOUBLE) AS value
FROM UNNEST(SEQUENCE(1, 100)) AS t(sequence)
CROSS JOIN (SELECT CURRENT_TIMESTAMP AS ts);
```

**Terminal 2 (immediately after starting Terminal 1):**
```sql
INSERT INTO iceberg.energy.readings
SELECT
    ts,
    'concurrent-node-B' AS node_id,
    'test_metric'       AS metric,
    CAST(sequence AS DOUBLE) AS value
FROM UNNEST(SEQUENCE(101, 200)) AS t(sequence)
CROSS JOIN (SELECT CURRENT_TIMESTAMP AS ts);
```

### 9.3 — Verify both inserts completed without data loss

```sql
SELECT COUNT(*) AS after FROM iceberg.energy.readings;
```

**Expected:** `before + 200` — all 200 rows from both inserts present.

```sql
SELECT node_id, COUNT(*) AS rows
FROM iceberg.energy.readings
WHERE node_id IN ('concurrent-node-A', 'concurrent-node-B')
GROUP BY node_id;
```

**Expected:**
```
      node_id      | rows
-------------------+------
 concurrent-node-A |  100
 concurrent-node-B |  100
```

### 9.4 — Verify snapshots show two separate commits

```sql
SELECT snapshot_id, operation, committed_at
FROM iceberg.energy."readings$snapshots"
ORDER BY committed_at DESC
LIMIT 5;
```

**Expected:** Two `append` operations with close but distinct `committed_at` timestamps — each insert created its own snapshot.

---

## Scenario 10 — Worker Failure and Recovery

**Goal:** Kill a Trino worker mid-query and confirm the query fails gracefully, then succeeds after the worker recovers.

**Expected duration:** 8 minutes

### 10.1 — Prepare a slow query (will run while we kill the worker)

In Trino, run a query that will take a few seconds:

```sql
SELECT node_id, COUNT(*), AVG(value)
FROM iceberg.energy.readings
CROSS JOIN UNNEST(SEQUENCE(1, 1000))
GROUP BY node_id;
```

### 10.2 — While the query runs, kill a worker

```bash
# Docker Desktop
docker stop iceberg-trino-worker-1

# K3s — delete the pod (Deployment will recreate it)
kubectl delete pod -n iceberg-decentralized \
  $(kubectl get pods -n iceberg-decentralized -l app=trino-worker -o name | head -1)
```

### 10.3 — Observe the query result

**Expected:** The query may fail with a message like:
```
Query failed: No nodes available to run query
```
or it may succeed if the coordinator routed all splits to the surviving worker. Both are valid Trino behaviours.

### 10.4 — Confirm worker recovers automatically

```bash
# Docker Desktop — watch it restart
docker ps | grep worker-1
# Status will show "health: starting" then "healthy"

# K3s — watch the pod come back
kubectl get pods -n iceberg-decentralized -l app=trino-worker -w
```

**Expected:** Worker returns to `Running (1/1 Ready)` within ~60 seconds.

### 10.5 — Re-run the query after recovery

```sql
SELECT COUNT(*) FROM iceberg.energy.readings;
```

**Expected:** Correct row count — query succeeds with both workers active.

### 10.6 — Verify both workers are registered again

```bash
curl -s ${TRINO}/v1/node | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
print(f'Active nodes: {len(nodes)}')
for n in nodes:
    print(f'  {n[\"uri\"]}')
"
```

**Expected:** 3 nodes (1 coordinator + 2 workers).

---

## Scenario 11 — Coordinator Restart

**Goal:** Restart the Trino coordinator and confirm data persists and queries resume normally.

**Expected duration:** 5 minutes

### 11.1 — Note the current snapshot ID

```sql
SELECT MAX(snapshot_id) AS latest_snapshot
FROM iceberg.energy."readings$snapshots";
```

### 11.2 — Restart the coordinator

```bash
# Docker Desktop
docker restart iceberg-trino-coordinator

# K3s
kubectl rollout restart deployment/trino-coordinator -n iceberg-decentralized
kubectl rollout status deployment/trino-coordinator -n iceberg-decentralized --timeout=120s
```

### 11.3 — Wait for Trino to come back

```bash
# Poll until Trino is ready (takes ~60 seconds)
until curl -sf ${TRINO}/v1/info | grep -q '"starting":false'; do
  echo "waiting for Trino..."
  sleep 5
done
echo "Trino ready"
```

### 11.4 — Verify data survived the restart

```sql
SELECT COUNT(*) FROM iceberg.energy.readings;
SELECT MAX(snapshot_id) AS latest_snapshot
FROM iceberg.energy."readings$snapshots";
```

**Expected:** Row count and latest snapshot ID are identical to before the restart. Data is stored in the Iceberg warehouse (PVC / Docker volume), not in Trino's memory.

### 11.5 — Run a query immediately

```sql
SELECT * FROM iceberg.energy.readings LIMIT 5;
```

**Expected:** Results return normally.

---

## Scenario 12 — Bridge Restart and Re-sync

**Goal:** Confirm the bridge re-publishes partition announcements to Zenoh after a restart, and the metrics counters reset cleanly.

**Expected duration:** 5 minutes

### 12.1 — Record current metrics

```bash
curl -s ${BRIDGE}/metrics
```

Note all three counter values.

### 12.2 — Insert new data to create a new partition

```sql
INSERT INTO iceberg.energy.readings VALUES
    (TIMESTAMP '2026-01-20 12:00:00.000000', 'node-restart-test', 'solar_kw', 77.7);
```

### 12.3 — Restart the bridge

```bash
# Docker Desktop
docker restart iceberg-bridge

# K3s
kubectl rollout restart deployment/zenoh-iceberg-bridge -n iceberg-decentralized
kubectl rollout status deployment/zenoh-iceberg-bridge -n iceberg-decentralized
```

### 12.4 — Watch the re-sync

```bash
docker logs -f iceberg-bridge
# or
kubectl logs -n iceberg-decentralized deploy/zenoh-iceberg-bridge -f
```

**Expected within 10 seconds of restart:**
```
[INFO] zenoh-iceberg-bridge starting
[INFO] node_id=... zenoh=tcp/zenoh:7447 ...
[INFO] published energy.readings (snapshot ...)
```

### 12.5 — Check metrics after restart

```bash
curl -s ${BRIDGE}/metrics
```

**Expected:** Counters reset to 0 and then increment from the first sync cycle — bridge is stateless and re-publishes everything on startup.

### 12.6 — Verify Zenoh still has the partition key

```bash
curl -s "${ZENOH}/iceberg/partitions/**" | python3 -m json.tool
```

**Expected:** The partition announcement is present with an updated `published_at` timestamp.

---

## Scenario 13 — Large Dataset Query

**Goal:** Stress-test the stack with a larger synthetic dataset to confirm query performance and worker distribution.

**Expected duration:** 10 minutes

### 13.1 — Generate a large synthetic table

```sql
CREATE TABLE iceberg.energy.synthetic_readings
WITH (
    format       = 'PARQUET',
    partitioning = ARRAY['day(ts)']
)
AS
SELECT
    CAST(DATE_ADD('hour', seq, TIMESTAMP '2026-01-01 00:00:00') AS TIMESTAMP(6)) AS ts,
    'node-' || CAST((seq % 5) + 1 AS VARCHAR)                                   AS node_id,
    CASE seq % 3
        WHEN 0 THEN 'solar_kw'
        WHEN 1 THEN 'wind_kw'
        ELSE        'battery_kwh'
    END                                                                           AS metric,
    CAST(RANDOM() * 100 AS DOUBLE)                                                AS value
FROM UNNEST(SEQUENCE(0, 8759)) AS t(seq);  -- 8760 hours = 1 full year
```

**Expected:** `CREATE TABLE: 8760 rows` — takes ~10–30 seconds.

### 13.2 — Verify partitions created

```sql
SELECT COUNT(*) AS partition_count
FROM iceberg.energy."synthetic_readings$partitions";
```

**Expected:** `365` — one partition per day of the year.

### 13.3 — Run an aggregation across the full year

```sql
SELECT
    node_id,
    metric,
    COUNT(*)             AS hours,
    ROUND(AVG(value), 2) AS avg_value,
    ROUND(MAX(value), 2) AS max_value
FROM iceberg.energy.synthetic_readings
GROUP BY node_id, metric
ORDER BY node_id, metric;
```

**Expected:** 15 rows (5 nodes × 3 metrics), each with `hours` ≈ 584. Runs in a few seconds with 2 workers.

### 13.4 — Single-month query with partition pruning

```sql
EXPLAIN
SELECT COUNT(*), AVG(value)
FROM iceberg.energy.synthetic_readings
WHERE ts >= TIMESTAMP '2026-06-01 00:00:00'
  AND ts <  TIMESTAMP '2026-07-01 00:00:00';
```

**Expected plan contains:** `partitions: 30 of 365` — only June scanned.

### 13.5 — Clean up

```sql
DROP TABLE iceberg.energy.synthetic_readings;
```

---

## Scenario 14 — Bridge Metrics Validation

**Goal:** Validate all three Prometheus counters behave correctly.

**Expected duration:** 5 minutes

### 14.1 — Validate `bridge_partitions_published_total`

```bash
# Reset by restarting bridge
docker restart iceberg-bridge   # or kubectl rollout restart ...

# Wait one sync cycle
sleep 35

# Check counter — should equal (number of tables × number of namespaces)
curl -s ${BRIDGE}/metrics | grep published_total
```

**Expected:** `bridge_partitions_published_total N` where N = number of Iceberg tables you have created.

### 14.2 — Create a new table and watch counter increase

```sql
CREATE TABLE iceberg.energy.metrics_test (id INTEGER, val DOUBLE);
INSERT INTO iceberg.energy.metrics_test VALUES (1, 1.0);
```

```bash
sleep 35
curl -s ${BRIDGE}/metrics | grep published_total
```

**Expected:** Counter increased by 1 (one more table to publish).

### 14.3 — Validate `bridge_partitions_rejected_total`

The rejected counter increments when a CID announced via Zenoh is not reachable via IPFS. We can simulate this by injecting a fake announcement directly into Zenoh:

```bash
# PUT a fake partition announcement with an unreachable CID
curl -s -X PUT "${ZENOH}/iceberg/partitions/energy/readings/fake-partition/fake-node" \
  -H "Content-Type: application/json" \
  -d '{
    "node_id": "fake-node",
    "namespace": "energy",
    "table": "readings",
    "partition_key": "fake-partition",
    "data_file_cid": "bafyreifakecidthatcannotberesolvedever",
    "snapshot_id": 999999,
    "published_at": "2026-01-15T00:00:00Z"
  }'
```

Wait for the next sync cycle:

```bash
sleep 35
curl -s ${BRIDGE}/metrics | grep rejected_total
```

**Expected:** `bridge_partitions_rejected_total 1` (or incremented by 1) — the bridge tried to reach the fake CID via IPFS block/stat, got an error, and rejected it.

### 14.4 — Validate `bridge_partitions_registered_total`

In a single-node deployment the registered counter stays at 0 (there are no remote nodes to sync from). To test it, simulate a valid remote announcement:

```bash
# First add a real file to IPFS to get a valid CID
CID=$(echo "test-partition-data" | curl -s -X POST -F "file=@-" "${IPFS}/api/v0/add" | python3 -c "import sys,json; print(json.load(sys.stdin)['Hash'])")

echo "CID: $CID"

# PUT a partition announcement with a VALID CID from a different node
curl -s -X PUT "${ZENOH}/iceberg/partitions/energy/readings/day=2026-01-19/simulated-remote-node" \
  -H "Content-Type: application/json" \
  -d "{
    \"node_id\": \"simulated-remote-node\",
    \"namespace\": \"energy\",
    \"table\": \"readings\",
    \"partition_key\": \"day=2026-01-19\",
    \"data_file_cid\": \"${CID}\",
    \"snapshot_id\": 111222333,
    \"published_at\": \"2026-01-19T00:00:00Z\"
  }"
```

```bash
sleep 35
curl -s ${BRIDGE}/metrics | grep registered_total
```

**Expected:** `bridge_partitions_registered_total 1` — the bridge found the announcement, verified the CID was reachable via IPFS block/stat, and registered it into the Iceberg catalog.

### 14.5 — Verify the simulated partition appears in the catalog

```sql
SELECT table_name, *
FROM iceberg.energy."readings$properties"
WHERE "key" LIKE 'remote.node.simulated-remote-node%';
```

**Expected:** At least one row showing the remote partition CID was registered as a table property.

### 14.6 — Clean up test tables

```sql
DROP TABLE IF EXISTS iceberg.energy.metrics_test;
DROP SCHEMA IF EXISTS iceberg.energy CASCADE;
```

---

## Expected Outputs Reference

| Test | Pass condition |
|------|---------------|
| `GET /v1/info` | `"starting": false` |
| `GET /v1/node` | Array with 3 nodes |
| `GET /v1/config` (catalog) | HTTP 200, `defaults` key present |
| `POST /api/v0/id` (IPFS) | JSON with `ID` field |
| `GET /@/router/local` (Zenoh) | `"whatami": "Router"` |
| `GET /healthz` (bridge) | `ok` |
| `SHOW CATALOGS` | `iceberg` in results |
| Partition pruning | `EXPLAIN` shows `N of M` partitions |
| Time-travel | Past row count matches snapshot |
| Schema evolution | No error on mixed-schema read |
| Concurrent inserts | Both 100-row batches present |
| Worker restart | Query resumes after ~60s |
| Coordinator restart | Row count unchanged |
| `bridge_partitions_published_total` | > 0 after first sync cycle |
| `bridge_partitions_rejected_total` | Increments on unreachable CID |
| `bridge_partitions_registered_total` | Increments on valid remote CID |
