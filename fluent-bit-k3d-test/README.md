# Fluent Bit Multi-Tenant Log Routing for Kubernetes

## Overview

This project demonstrates a production-ready Fluent Bit deployment on Kubernetes with intelligent log routing based on pod labels and container names. It supports:

- **Dual Routing Paths**: Consumer logs vs Infrastructure logs
- **Dynamic Token Management**: Per-namespace Kubernetes secrets for Splunk HEC tokens
- **Label-based Classification**: Routes logs based on pod labels and container names
- **Namespace Isolation**: Each team manages their own Splunk credentials
- **Security**: RBAC with least-privilege access to specific secrets
- **No Recursive Processing**: Automatically excludes Fluent Bit's own logs

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                    APPLICATION NAMESPACES                             │
│                                                                       │
│  team-alpha (consumer)     team-beta (consumer)    team-gamma (infra)│
│  ┌──────────────┐          ┌──────────────┐       ┌──────────────┐  │
│  │ Pod Labels:  │          │ Pod Labels:  │       │ Pod Labels:  │  │
│  │ consumer-    │          │ consumer-    │       │ (no consumer │  │
│  │ splunk-index │          │ splunk-index │       │  label)      │  │
│  │              │          │              │       │              │  │
│  │ Container:   │          │ Container:   │       │ Container:   │  │
│  │ name: app    │          │ name: app    │       │ name: app    │  │
│  └──────┬───────┘          └──────┬───────┘       └──────┬───────┘  │
│         │                         │                      │           │
│    [app logs]               [app logs]             [app logs]       │
└─────────┼─────────────────────────┼──────────────────────┼───────────┘
          │                         │                      │
          └─────────────────────────┴──────────────────────┘
                                    │
                            [container logs]
                      /var/log/containers/*.log
                                    │
                                    ▼
          ┌────────────────────────────────────────────────┐
          │         Fluent Bit DaemonSet                   │
          │         (logging namespace)                     │
          │                                                 │
          │  1. Tail container logs                        │
          │  2. Enrich with Kubernetes metadata            │
          │  3. Exclude Fluent Bit's own logs              │
          │  4. Classify: consumer vs infrastructure       │
          │  5. Re-tag based on classification             │
          │  6. Fetch secrets (consumer only)              │
          │  7. Route to correct Splunk endpoint           │
          └────────────┬────────────────┬──────────────────┘
                       │                │
            ┌──────────┘                └──────────┐
            ▼                                      ▼
┌──────────────────────────┐      ┌──────────────────────────┐
│  Splunk Consumer Logs    │      │  Splunk Infrastructure   │
│  - team-alpha logs       │      │  - team-gamma logs       │
│  - team-beta logs        │      │  - system logs           │
│  - Dynamic tokens        │      │  - Static token          │
│  - Dynamic indexes       │      │  - Static index          │
└──────────────────────────┘      └──────────────────────────┘
```

## Routing Logic

### Consumer Logs (Dynamic Routing)
**Criteria**: Pod has label `consumer-splunk-index` **AND** container name is `app`

**Flow**:
1. Extract `splunk_index` from pod label value
2. Fetch `splunk-token` secret from pod's namespace
3. Route to consumer Splunk endpoint
4. Each namespace has its own token

**Example Pod**:
```yaml
metadata:
  labels:
    consumer-splunk-index: "alpha-consumer-index"
spec:
  containers:
  - name: app  # Must be exactly "app"
    image: myapp:latest
```

### Infrastructure Logs (Static Routing)
**Criteria**: Everything else (no label OR container name != "app")

**Flow**:
1. Add static `splunk_index` field
2. Add static `splunk_token` field
3. Route to infrastructure Splunk endpoint

## Project Structure

```
fluent-bit-k3d-test/
├── README.md                          # This file
├── QUICKSTART.md                      # Quick start guide
│
├── docs/
│   ├── LOG_PIPELINE_FLOW.md          # Detailed pipeline documentation
│   ├── LUA_SCRIPTS.md                 # Lua script documentation
│   ├── TROUBLESHOOTING.md             # Common issues and solutions
│   └── PRODUCTION_CHECKLIST.md        # Production deployment guide
│
├── scripts/
│   ├── setup-k3d-cluster.sh          # Create k3d cluster
│   ├── complete-deployment.sh         # Deploy all components
│   ├── validate-setup.sh              # Validate deployment
│   ├── watch-logs.sh                  # Watch all relevant logs
│   └── cleanup.sh                     # Cleanup resources
│
└── manifests/
    ├── base/
    │   ├── 01-namespaces.yaml         # All namespaces
    │   ├── 02-rbac.yaml               # RBAC configuration
    │   ├── 03-secrets.yaml            # Splunk token secrets
    │   ├── 04-lua-scripts.yaml        # Lua scripts ConfigMap
    │   ├── 05-fluent-bit-config.yaml  # Fluent Bit configuration
    │   ├── 06-fluent-bit-daemonset.yaml # Fluent Bit DaemonSet
    │   └── 07-mock-splunk.yaml        # Mock Splunk servers
    │
    └── test-apps/
        └── test-applications.yaml      # Test pods
```

## Quick Start

### Prerequisites

- Docker installed
- kubectl installed
- k3d installed (v5.0.0+)

### Installation

```bash
# 1. Clone/download this project
cd fluent-bit-k3d-test

# 2. Make scripts executable
chmod +x scripts/*.sh

# 3. Create k3d cluster
./scripts/setup-k3d-cluster.sh

# 4. Deploy everything
./scripts/complete-deployment.sh

# 5. Validate deployment
./scripts/validate-setup.sh

# 6. Watch logs (in separate terminal)
./scripts/watch-logs.sh
```

### Verification

After deployment, verify the setup:

```bash
# Check Fluent Bit is running
kubectl get pods -n logging

# Check test applications are running
kubectl get pods -n team-alpha,team-beta,team-gamma

# Check consumer logs are being received
kubectl logs -n splunk-mock -l app=mock-splunk-consumer --tail=50 | grep "Token from body"
# Expected: ALPHA-TOKEN-12345, BETA-TOKEN-67890

# Check infrastructure logs are being received
kubectl logs -n splunk-mock -l app=mock-splunk-infra --tail=30 | grep "Authorization"
# Expected: Splunk INFRA-TOKEN-STATIC
```

## How It Works

See [docs/LOG_PIPELINE_FLOW.md](docs/LOG_PIPELINE_FLOW.md) for a detailed stage-by-stage walkthrough of the log processing pipeline.

### High-Level Flow

1. **Input**: Tail plugin reads `/var/log/containers/*.log`
2. **Kubernetes Enrichment**: Adds pod metadata (labels, namespace, container name, etc.)
3. **Exclusion Filter**: Removes Fluent Bit's own logs to prevent recursion
4. **Lua Classification**: Checks pod label + container name → tags as `consumer` or `infrastructure`
5. **Rewrite Tag**: Splits stream into `consumer-logs` and `tdp-infra` tags
6. **Enrichment**:
   - Consumer: Lua script fetches secret from Kubernetes API
   - Infrastructure: Static modify filter adds fixed values
7. **Output**: Routes to appropriate Splunk HEC endpoint

### Secret Structure

Each consumer namespace has its own token secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: splunk-token
  namespace: team-alpha
type: Opaque
stringData:
  splunk-token: "ALPHA-TOKEN-12345"
```

The `splunk_index` comes from the pod label, not the secret:

```yaml
metadata:
  labels:
    consumer-splunk-index: "alpha-consumer-index"
```

## Key Features

### Intelligent Routing

- **Label + Container Based**: Routes based on BOTH pod label AND container name
- **Namespace Aware**: Automatically fetches secrets from correct namespace
- **No Cross-Namespace Access**: team-alpha cannot access team-beta's tokens

### Security

- **RBAC**: ServiceAccount with minimal permissions
  - ClusterRole: Read-only access to namespaces and pods
  - Namespace Roles: `get` only on specific secret `splunk-token`
- **Secret Isolation**: Each namespace controls their own credentials
- **No Hardcoded Tokens**: All sensitive data in Kubernetes secrets

### Performance

- **Secret Caching**: 30-minute TTL reduces Kubernetes API calls
- **Early Filtering**: Excludes Fluent Bit logs before processing
- **Efficient Stream Splitting**: rewrite_tag for optimized routing
- **Tag-Based Matching**: Filters only match relevant logs

### Operational Excellence

- **Self-Healing**: Caching with fallback for secret fetch failures
- **Debug Fields**: `_log_type`, `_new_tag`, `_enriched` for troubleshooting
- **No Recursive Loops**: Grep filter prevents processing own logs
- **Clear Error Messages**: Lua errors logged with context

## Configuration

### Consumer Pod Requirements

For a pod's logs to route to the consumer Splunk endpoint:

1. **Label**: Must have `consumer-splunk-index` label with index value
2. **Container Name**: Container must be named `app`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  namespace: team-alpha
  labels:
    consumer-splunk-index: "my-index"  # Required
spec:
  containers:
  - name: app  # Must be exactly "app"
    image: myapp:latest
```

### Adding a New Consumer Namespace

1. **Create namespace**:
```bash
kubectl create namespace team-charlie
```

2. **Create secret**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: splunk-token
  namespace: team-charlie
type: Opaque
stringData:
  splunk-token: "CHARLIE-TOKEN-XXXXX"
```

3. **Create RBAC** (add to `manifests/base/02-rbac.yaml`):
```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: fluent-bit-secret-reader
  namespace: team-charlie
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["splunk-token"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: fluent-bit-secret-reader
  namespace: team-charlie
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: fluent-bit-secret-reader
subjects:
- kind: ServiceAccount
  name: fluent-bit
  namespace: logging
```

4. **Deploy pod** with correct label and container name

### Using Real Splunk Endpoints

Edit `manifests/base/05-fluent-bit-config.yaml`:

```ini
# Consumer logs output
[OUTPUT]
    Name        http
    Match       consumer-logs
    Host        consumer-splunk.example.com
    Port        8088
    URI         /services/collector/event
    Format      json
    Header      Authorization Splunk ${splunk_token}
    TLS         On
    TLS.Verify  On

# Infrastructure logs output
[OUTPUT]
    Name        http
    Match       tdp-infra
    Host        infra-splunk.example.com
    Port        8088
    URI         /services/collector/event
    Format      json
    Header      Authorization Splunk YOUR-INFRA-TOKEN
    TLS         On
    TLS.Verify  On
```

### Adjusting Secret Cache TTL

Edit `manifests/base/04-lua-scripts.yaml`:

```lua
local cache_ttl = 1800  -- 30 minutes (default)
-- Increase for production: local cache_ttl = 3600  -- 60 minutes
-- Decrease for testing: local cache_ttl = 60  -- 1 minute
```

## Monitoring

### Check Log Flow

```bash
# Consumer logs
kubectl logs -n splunk-mock -l app=mock-splunk-consumer --tail=100 | grep "Token from body"

# Infrastructure logs
kubectl logs -n splunk-mock -l app=mock-splunk-infra --tail=100 | grep "Authorization"

# Fluent Bit processing
kubectl logs -n logging -l app=fluent-bit --tail=100
```

### Check for Errors

```bash
# Secret fetch errors
kubectl logs -n logging -l app=fluent-bit | grep "_secret_fetch_error"

# General errors
kubectl logs -n logging -l app=fluent-bit | grep -i error
```

### Fluent Bit Metrics

Fluent Bit exposes Prometheus metrics on port 2020:

```bash
kubectl port-forward -n logging ds/fluent-bit 2020:2020
curl http://localhost:2020/api/v1/metrics
```

## Troubleshooting

### No Logs Reaching Splunk

**Check Fluent Bit is running**:
```bash
kubectl get pods -n logging
```

**Check for errors**:
```bash
kubectl logs -n logging -l app=fluent-bit | grep -i error
```

### Only Alpha Logs, No Beta Logs

**Verify pod labels**:
```bash
kubectl get pod test-app-beta -n team-beta -o jsonpath='{.metadata.labels}'
```

Expected: `{"consumer-splunk-index":"beta-consumer-index",...}`

**Verify container name**:
```bash
kubectl get pod test-app-beta -n team-beta -o jsonpath='{.spec.containers[*].name}'
```

Expected: `app`

### Secret Fetch Failures

**Check RBAC permissions**:
```bash
kubectl auth can-i get secret/splunk-token -n team-alpha \
  --as=system:serviceaccount:logging:fluent-bit
```

Expected: `yes`

**Check secret exists**:
```bash
kubectl get secret splunk-token -n team-alpha
```

**Check Lua errors**:
```bash
kubectl logs -n logging -l app=fluent-bit | grep _secret_fetch_error
```

### Recursive Log Processing

If you see nested Fluent Bit logs in Splunk, verify the exclusion filter:

```bash
kubectl get cm fluent-bit-config -n logging -o yaml | grep -A 3 "Exclude"
```

Expected:
```yaml
Name: grep
Match: kube.*
Exclude: kubernetes.namespace_name logging
```

For more troubleshooting, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Documentation

- **[LOG_PIPELINE_FLOW.md](docs/LOG_PIPELINE_FLOW.md)**: Detailed pipeline diagram and stage-by-stage flow
- **[LUA_SCRIPTS.md](docs/LUA_SCRIPTS.md)**: Lua script documentation
- **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**: Common issues and solutions
- **[PRODUCTION_CHECKLIST.md](docs/PRODUCTION_CHECKLIST.md)**: Production deployment guide
- **[QUICKSTART.md](QUICKSTART.md)**: Quick start tutorial

## Production Considerations

Before deploying to production:

1. ✅ Use real Splunk HEC endpoints with TLS
2. ✅ Configure proper TLS certificate verification
3. ✅ Adjust resource limits based on log volume
4. ✅ Set up monitoring and alerting for Fluent Bit pods
5. ✅ Implement secret rotation procedures
6. ✅ Review and adjust secret cache TTL
7. ✅ Configure network policies for Fluent Bit
8. ✅ Set up log retention policies in Splunk
9. ✅ Test failover scenarios
10. ✅ Document team-specific procedures

See [docs/PRODUCTION_CHECKLIST.md](docs/PRODUCTION_CHECKLIST.md) for complete checklist.

## Cleanup

```bash
./scripts/cleanup.sh
```

This will delete the k3d cluster and all resources.

## Known Limitations

1. **HTTP Header Variable Substitution**: Fluent Bit HTTP plugin doesn't support `${field}` in headers
   - **Workaround**: Token is included in JSON body, mock Splunk extracts it
   - **Production**: Use a real Splunk HEC that accepts tokens in request body

2. **Container Name Requirement**: Consumer pods must use container name `app`
   - **Reason**: Allows filtering out sidecar containers
   - **Alternative**: Modify Lua script to use different container name pattern

3. **Single Container Support**: Only processes logs from container named `app`
   - **Reason**: Simplifies multi-container pod handling
   - **Alternative**: Modify Lua script for multi-container support

## License

MIT

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## Support

For issues and questions:
- Review [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Check [docs/LOG_PIPELINE_FLOW.md](docs/LOG_PIPELINE_FLOW.md)
- Open a GitHub issue

## Changelog

### v2.0 (Current)
- Added dual routing (consumer vs infrastructure)
- Implemented label-based classification
- Added exclusion filter for Fluent Bit logs
- Updated to use `splunk-token` secret name
- Added comprehensive pipeline documentation
- Improved error handling and debugging

### v1.0 (Previous)
- Basic namespace filtering
- Dynamic secret fetching
- Container filtering
