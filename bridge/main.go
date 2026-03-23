// zenoh-iceberg-bridge
// Bridges Zenoh peer discovery with the Iceberg REST catalog so that
// Trino can plan queries across data held on remote IPFS-backed nodes.
//
// Flow:
//   1. On startup, read local Iceberg catalog → publish partition map to Zenoh
//   2. On timer, query Zenoh for remote partition announcements
//   3. For each remote partition, verify IPFS CID reachability
//   4. Register verified remote partitions into local Iceberg REST catalog
//
// Build:  go build -o bridge ./cmd/bridge
// Run:    ZENOH_ENDPOINT=tcp/zenoh:7447 CATALOG_ENDPOINT=http://iceberg-rest-catalog:8181 \
//         IPFS_API=http://ipfs-node:5001 SYNC_INTERVAL_SECONDS=30 ./bridge

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

// ──────────────────────────────────────────────
// Configuration
// ──────────────────────────────────────────────

type Config struct {
	ZenohEndpoint       string
	CatalogEndpoint     string
	IPFSApi             string
	SyncIntervalSeconds int
	NodeID              string
	MetricsPort         string
}

func configFromEnv() Config {
	interval, _ := strconv.Atoi(getEnvOrDefault("SYNC_INTERVAL_SECONDS", "30"))
	return Config{
		ZenohEndpoint:       getEnvOrDefault("ZENOH_ENDPOINT", "tcp/zenoh:7447"),
		CatalogEndpoint:     getEnvOrDefault("CATALOG_ENDPOINT", "http://iceberg-rest-catalog:8181"),
		IPFSApi:             getEnvOrDefault("IPFS_API", "http://ipfs-node:5001"),
		SyncIntervalSeconds: interval,
		NodeID:              getEnvOrDefault("NODE_ID", "unknown-node"),
		MetricsPort:         getEnvOrDefault("METRICS_PORT", "9090"),
	}
}

func getEnvOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// ──────────────────────────────────────────────
// Iceberg REST catalog types
// ──────────────────────────────────────────────

type IcebergNamespace struct {
	Namespace []string `json:"namespace"`
}

type IcebergTable struct {
	Identifier struct {
		Namespace []string `json:"namespace"`
		Name      string   `json:"name"`
	} `json:"identifier"`
	Metadata struct {
		CurrentSnapshotID int64         `json:"current-snapshot-id"`
		Snapshots         []interface{} `json:"snapshots"`
		PartitionSpecs    []struct {
			Fields []struct {
				Name      string `json:"name"`
				Transform string `json:"transform"`
				SourceID  int    `json:"source-id"`
			} `json:"fields"`
		} `json:"partition-specs"`
	} `json:"metadata"`
}

// PartitionAnnouncement is the structure published to Zenoh
// under key: iceberg/partitions/<namespace>/<table>/<partition_key>
type PartitionAnnouncement struct {
	NodeID      string `json:"node_id"`
	Namespace   string `json:"namespace"`
	Table       string `json:"table"`
	PartitionKey string `json:"partition_key"`
	// IPFS CID of the data file for this partition
	DataFileCID string `json:"data_file_cid"`
	// Schema version (Iceberg snapshot ID)
	SnapshotID  int64  `json:"snapshot_id"`
	PublishedAt string `json:"published_at"`
}

// ──────────────────────────────────────────────
// Iceberg REST catalog client
// ──────────────────────────────────────────────

type CatalogClient struct {
	baseURL string
	http    *http.Client
}

func NewCatalogClient(baseURL string) *CatalogClient {
	return &CatalogClient{
		baseURL: baseURL,
		http:    &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *CatalogClient) ListNamespaces() ([]string, error) {
	resp, err := c.http.Get(c.baseURL + "/v1/namespaces")
	if err != nil {
		return nil, fmt.Errorf("list namespaces: %w", err)
	}
	defer resp.Body.Close()
	var result struct {
		Namespaces [][]string `json:"namespaces"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	names := make([]string, 0, len(result.Namespaces))
	for _, ns := range result.Namespaces {
		if len(ns) > 0 {
			names = append(names, ns[0])
		}
	}
	return names, nil
}

func (c *CatalogClient) ListTables(namespace string) ([]string, error) {
	url := fmt.Sprintf("%s/v1/namespaces/%s/tables", c.baseURL, namespace)
	resp, err := c.http.Get(url)
	if err != nil {
		return nil, fmt.Errorf("list tables in %s: %w", namespace, err)
	}
	defer resp.Body.Close()
	var result struct {
		Identifiers []struct {
			Name string `json:"name"`
		} `json:"identifiers"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	tables := make([]string, 0, len(result.Identifiers))
	for _, id := range result.Identifiers {
		tables = append(tables, id.Name)
	}
	return tables, nil
}

func (c *CatalogClient) GetTable(namespace, table string) (*IcebergTable, error) {
	url := fmt.Sprintf("%s/v1/namespaces/%s/tables/%s", c.baseURL, namespace, table)
	resp, err := c.http.Get(url)
	if err != nil {
		return nil, fmt.Errorf("get table %s.%s: %w", namespace, table, err)
	}
	defer resp.Body.Close()
	var t IcebergTable
	if err := json.NewDecoder(resp.Body).Decode(&t); err != nil {
		return nil, err
	}
	return &t, nil
}

// RegisterRemotePartition registers a remote partition CID into the local
// Iceberg catalog via a table property update (catalog-specific extension).
func (c *CatalogClient) RegisterRemotePartition(ann PartitionAnnouncement) error {
	url := fmt.Sprintf("%s/v1/namespaces/%s/tables/%s/properties",
		c.baseURL, ann.Namespace, ann.Table)
	payload := map[string]interface{}{
		"updates": []map[string]interface{}{
			{
				"action": "set-properties",
				"updates": map[string]string{
					fmt.Sprintf("remote.node.%s.partition.%s.cid", ann.NodeID, ann.PartitionKey): ann.DataFileCID,
					fmt.Sprintf("remote.node.%s.partition.%s.snapshot", ann.NodeID, ann.PartitionKey): strconv.FormatInt(ann.SnapshotID, 10),
				},
			},
		},
	}
	body, _ := json.Marshal(payload)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("register remote partition: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("catalog rejected registration (HTTP %d): %s", resp.StatusCode, string(b))
	}
	return nil
}

// ──────────────────────────────────────────────
// IPFS client (CID reachability check)
// ──────────────────────────────────────────────

type IPFSClient struct {
	apiURL string
	http   *http.Client
}

func NewIPFSClient(apiURL string) *IPFSClient {
	return &IPFSClient{
		apiURL: apiURL,
		http:   &http.Client{Timeout: 10 * time.Second},
	}
}

// IsCIDReachable checks whether a CID is resolvable via the local IPFS node.
// It uses the /api/v0/block/stat endpoint with a short timeout so that
// phantom CIDs from unreachable peers don't block the sync loop.
func (c *IPFSClient) IsCIDReachable(cid string) bool {
	url := fmt.Sprintf("%s/api/v0/block/stat?arg=%s&timeout=5s", c.apiURL, cid)
	resp, err := c.http.Post(url, "application/json", nil)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// ──────────────────────────────────────────────
// Zenoh REST client
// Zenoh 0.11+ exposes a REST API on port 8000 for get/put/delete/queryable.
// We use it to avoid CGo dependencies (no native Zenoh Go SDK needed).
// ──────────────────────────────────────────────

type ZenohClient struct {
	restURL string
	http    *http.Client
}

func NewZenohClient(endpoint string) *ZenohClient {
	// endpoint: "tcp/zenoh:7447" → REST is on zenoh:8000
	restURL := "http://zenoh:8000"
	return &ZenohClient{
		restURL: restURL,
		http:    &http.Client{Timeout: 10 * time.Second},
	}
}

// Publish writes a partition announcement to Zenoh under the key
// iceberg/partitions/<namespace>/<table>/<partition_key>/<node_id>
func (z *ZenohClient) Publish(ann PartitionAnnouncement) error {
	key := fmt.Sprintf("iceberg/partitions/%s/%s/%s/%s",
		ann.Namespace, ann.Table, ann.PartitionKey, ann.NodeID)
	body, _ := json.Marshal(ann)
	url := fmt.Sprintf("%s/%s", z.restURL, key)
	req, _ := http.NewRequest(http.MethodPut, url, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := z.http.Do(req)
	if err != nil {
		return fmt.Errorf("zenoh publish: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("zenoh rejected put (HTTP %d): %s", resp.StatusCode, string(b))
	}
	return nil
}

// QueryRemotePartitions fetches all partition announcements from the mesh
// for a given namespace and table (wildcard on partition and node).
func (z *ZenohClient) QueryRemotePartitions(namespace, table string) ([]PartitionAnnouncement, error) {
	key := fmt.Sprintf("iceberg/partitions/%s/%s/**", namespace, table)
	url := fmt.Sprintf("%s/%s", z.restURL, key)
	resp, err := z.http.Get(url)
	if err != nil {
		return nil, fmt.Errorf("zenoh query: %w", err)
	}
	defer resp.Body.Close()
	var items []struct {
		Key   string          `json:"key"`
		Value json.RawMessage `json:"value"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&items); err != nil {
		return nil, err
	}
	anns := make([]PartitionAnnouncement, 0, len(items))
	for _, item := range items {
		var ann PartitionAnnouncement
		if err := json.Unmarshal(item.Value, &ann); err == nil {
			anns = append(anns, ann)
		}
	}
	return anns, nil
}

// ──────────────────────────────────────────────
// Bridge core logic
// ──────────────────────────────────────────────

type Bridge struct {
	cfg     Config
	catalog *CatalogClient
	zenoh   *ZenohClient
	ipfs    *IPFSClient

	// simple in-memory counter for Prometheus metrics
	publishedCount  int64
	registeredCount int64
	rejectedCount   int64
}

func NewBridge(cfg Config) *Bridge {
	return &Bridge{
		cfg:     cfg,
		catalog: NewCatalogClient(cfg.CatalogEndpoint),
		zenoh:   NewZenohClient(cfg.ZenohEndpoint),
		ipfs:    NewIPFSClient(cfg.IPFSApi),
	}
}

// PublishLocalPartitions reads all local Iceberg tables and announces
// their partition metadata into the Zenoh mesh.
func (b *Bridge) PublishLocalPartitions(ctx context.Context) error {
	namespaces, err := b.catalog.ListNamespaces()
	if err != nil {
		return fmt.Errorf("list namespaces: %w", err)
	}
	for _, ns := range namespaces {
		tables, err := b.catalog.ListTables(ns)
		if err != nil {
			log.Printf("[WARN] list tables in %s: %v", ns, err)
			continue
		}
		for _, tbl := range tables {
			t, err := b.catalog.GetTable(ns, tbl)
			if err != nil {
				log.Printf("[WARN] get table %s.%s: %v", ns, tbl, err)
				continue
			}
			ann := PartitionAnnouncement{
				NodeID:      b.cfg.NodeID,
				Namespace:   ns,
				Table:       tbl,
				PartitionKey: "default",
				SnapshotID:  t.Metadata.CurrentSnapshotID,
				// DataFileCID would be populated by the Iceberg FileIO layer
				// when using IPFS-backed storage. Placeholder here.
				DataFileCID: fmt.Sprintf("bafyreicid-placeholder-%s-%s", ns, tbl),
				PublishedAt: time.Now().UTC().Format(time.RFC3339),
			}
			if err := b.zenoh.Publish(ann); err != nil {
				log.Printf("[WARN] publish %s.%s: %v", ns, tbl, err)
			} else {
				b.publishedCount++
				log.Printf("[INFO] published %s.%s (snapshot %d)", ns, tbl, ann.SnapshotID)
			}
		}
	}
	return nil
}

// SyncRemotePartitions queries Zenoh for announcements from other nodes,
// verifies IPFS reachability, and registers valid ones into the local catalog.
func (b *Bridge) SyncRemotePartitions(ctx context.Context) error {
	namespaces, err := b.catalog.ListNamespaces()
	if err != nil {
		return fmt.Errorf("list namespaces for sync: %w", err)
	}
	for _, ns := range namespaces {
		tables, err := b.catalog.ListTables(ns)
		if err != nil {
			continue
		}
		for _, tbl := range tables {
			anns, err := b.zenoh.QueryRemotePartitions(ns, tbl)
			if err != nil {
				log.Printf("[WARN] zenoh query %s.%s: %v", ns, tbl, err)
				continue
			}
			for _, ann := range anns {
				// Skip our own announcements
				if ann.NodeID == b.cfg.NodeID {
					continue
				}
				// Verify the CID is reachable via local IPFS before registering
				if !b.ipfs.IsCIDReachable(ann.DataFileCID) {
					log.Printf("[WARN] CID %s from node %s is unreachable — skipping",
						ann.DataFileCID, ann.NodeID)
					b.rejectedCount++
					continue
				}
				if err := b.catalog.RegisterRemotePartition(ann); err != nil {
					log.Printf("[WARN] register partition %s.%s from %s: %v",
						ns, tbl, ann.NodeID, err)
				} else {
					b.registeredCount++
					log.Printf("[INFO] registered remote partition %s.%s from node %s (CID: %s)",
						ns, tbl, ann.NodeID, ann.DataFileCID)
				}
			}
		}
	}
	return nil
}

// ──────────────────────────────────────────────
// Metrics & health (simple Prometheus text format)
// ──────────────────────────────────────────────

func (b *Bridge) metricsHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "# HELP bridge_partitions_published_total Partition announcements sent to Zenoh\n")
	fmt.Fprintf(w, "# TYPE bridge_partitions_published_total counter\n")
	fmt.Fprintf(w, "bridge_partitions_published_total %d\n", b.publishedCount)

	fmt.Fprintf(w, "# HELP bridge_partitions_registered_total Remote partitions registered into catalog\n")
	fmt.Fprintf(w, "# TYPE bridge_partitions_registered_total counter\n")
	fmt.Fprintf(w, "bridge_partitions_registered_total %d\n", b.registeredCount)

	fmt.Fprintf(w, "# HELP bridge_partitions_rejected_total Remote partitions rejected (CID unreachable)\n")
	fmt.Fprintf(w, "# TYPE bridge_partitions_rejected_total counter\n")
	fmt.Fprintf(w, "bridge_partitions_rejected_total %d\n", b.rejectedCount)
}

func (b *Bridge) healthzHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "ok")
}

// ──────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────

func main() {
	cfg := configFromEnv()
	log.Printf("[INFO] zenoh-iceberg-bridge starting")
	log.Printf("[INFO] node_id=%s zenoh=%s catalog=%s ipfs=%s interval=%ds",
		cfg.NodeID, cfg.ZenohEndpoint, cfg.CatalogEndpoint, cfg.IPFSApi, cfg.SyncIntervalSeconds)

	bridge := NewBridge(cfg)

	// HTTP server for metrics and healthz
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", bridge.metricsHandler)
	mux.HandleFunc("/healthz", bridge.healthzHandler)
	go func() {
		addr := ":" + cfg.MetricsPort
		log.Printf("[INFO] metrics server on %s", addr)
		if err := http.ListenAndServe(addr, mux); err != nil {
			log.Fatalf("metrics server: %v", err)
		}
	}()

	ctx := context.Background()
	ticker := time.NewTicker(time.Duration(cfg.SyncIntervalSeconds) * time.Second)
	defer ticker.Stop()

	// Run immediately on start
	if err := bridge.PublishLocalPartitions(ctx); err != nil {
		log.Printf("[WARN] initial publish: %v", err)
	}
	if err := bridge.SyncRemotePartitions(ctx); err != nil {
		log.Printf("[WARN] initial sync: %v", err)
	}

	for {
		select {
		case <-ticker.C:
			if err := bridge.PublishLocalPartitions(ctx); err != nil {
				log.Printf("[WARN] publish cycle: %v", err)
			}
			if err := bridge.SyncRemotePartitions(ctx); err != nil {
				log.Printf("[WARN] sync cycle: %v", err)
			}
		case <-ctx.Done():
			log.Println("[INFO] shutting down")
			return
		}
	}
}
