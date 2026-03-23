# Contributing

## Development setup

```bash
git clone https://github.com/optimusdb/iceberg-decentralized.git
cd iceberg-decentralized
```

### Bridge (Go)

```bash
cd bridge
go build ./...
go vet ./...
```

No external dependencies — stdlib only.

### Chart (Helm)

Validate templates render cleanly:

```bash
helm template iceberg-decentralized . --debug | kubectl apply --dry-run=client -f -
```

## Pull request checklist

- [ ] `helm template` renders without errors
- [ ] Bridge builds with `go build ./...` and passes `go vet`
- [ ] `values.yaml` updated if new config keys added
- [ ] README updated if architecture changes
- [ ] Mermaid diagrams updated if flow changes

## Reporting issues

Please include:
- `kubectl version`
- `helm version`
- `kubectl get pods -n iceberg-decentralized` output
- Relevant pod logs (`kubectl logs ...`)
