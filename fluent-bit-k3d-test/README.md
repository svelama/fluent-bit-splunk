# Fluent Bit with Kubernetes Secret-based Splunk Configuration

## Overview

This project demonstrates how to deploy Fluent Bit on a Kubernetes cluster (k3d for local testing) with the following features:

- **Dynamic Splunk Configuration**: Fetches Splunk HEC tokens and indexes from Kubernetes secrets
- **Namespace Filtering**: Only collects logs from namespaces labeled with `fluent-bit-enabled: true`
- **Container Filtering**: Excludes system/sidecar containers, only logs application containers
- **Multi-tenant Support**: Different namespaces can have different Splunk configurations
- **Security**: RBAC configured with least-privilege access to specific secrets

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Application Namespaces                       │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                │
│  │ team-alpha │  │ team-beta  │  │ team-gamma │                │
│  │ (labeled)  │  │ (labeled)  │  │ (no label) │                │
│  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘                │
│        │                │                │                        │
│   [app pods]       [app pods]      [app pods]                   │
│        │                │                │                        │
│        └────────────────┴────────────────┘                       │
│                         │                                         │
│                    [log files]                                   │
│                         │                                         │
└─────────────────────────┼─────────────────────────────────────────┘
                          │
                          ▼
           ┌──────────────────────────────┐
           │   Fluent Bit DaemonSet       │
           │   (logging namespace)         │
           │                               │
           │  1. Read pod metadata         │
           │  2. Filter by namespace label │
           │  3. Filter containers         │
           │  4. Fetch K8s secret          │
           │  5. Enrich with Splunk config │
           └──────────────┬────────────────┘
                          │
                          ▼
           ┌──────────────────────────────┐
           │      Splunk HEC / Mock       │
           │  (receives enriched logs)    │
           └──────────────────────────────┘
```

## Project Structure

```
fluent-bit-k3d-test/
├── README.md                          # This file
├── ARCHITECTURE.md                    # Detailed architecture documentation
├── TROUBLESHOOTING.md                 # Common issues and solutions
│
├── scripts/
│   ├── setup-k3d-cluster.sh          # Create k3d cluster
│   ├── complete-deployment.sh         # Deploy all components
│   ├── validate-setup.sh              # Validate deployment
│   ├── setup-namespace.sh             # Add new namespace to Fluent Bit
│   ├── watch-logs.sh                  # Watch all relevant logs
│   └── cleanup.sh                     # Cleanup resources
│
├── manifests/
│   ├── base/
│   │   ├── 01-namespaces.yaml         # All namespaces
│   │   ├── 02-rbac.yaml               # RBAC configuration
│   │   ├── 03-secrets.yaml            # Splunk config secrets
│   │   ├── 04-lua-scripts.yaml        # Lua scripts ConfigMap
│   │   ├── 05-fluent-bit-config.yaml  # Fluent Bit configuration
│   │   ├── 06-fluent-bit-daemonset.yaml # Fluent Bit DaemonSet
│   │   └── 07-mock-splunk.yaml        # Mock Splunk server
│   │
│   └── test-apps/
│       └── test-applications.yaml      # Test pods
│
└── docs/
    ├── LUA_SCRIPTS.md                  # Lua script documentation
    └── PRODUCTION_CHECKLIST.md         # Production deployment guide
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
kubectl get pods -n team-alpha
kubectl get pods -n team-beta
kubectl get pods -n team-gamma

# Check logs are being collected (only from team-alpha and team-beta)
kubectl logs -n splunk-mock -l app=mock-splunk --tail=50
```

## How It Works

### 1. Namespace Filtering

Only namespaces with the label `fluent-bit-enabled: true` have their logs collected:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha
  labels:
    fluent-bit-enabled: "true"  # Required for log collection
```

### 2. Container Filtering

System containers (istio-proxy, init containers, etc.) are automatically filtered out. Only application containers are logged.

### 3. Secret-based Configuration

Each namespace has its own Splunk configuration stored in a Kubernetes secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: splunk-config
  namespace: team-alpha
type: Opaque
stringData:
  splunk-token: "YOUR-SPLUNK-HEC-TOKEN"
  splunk-index: "team-alpha-logs"
```

### 4. Dynamic Enrichment

Fluent Bit's Lua filter:
1. Reads the pod's namespace
2. Fetches the `splunk-config` secret from that namespace
3. Enriches log records with the token and index
4. Sends logs to Splunk with the correct configuration

## Key Features

### Security

- **RBAC**: ServiceAccount with minimal permissions
- **Secret Access**: Limited to specific secret names per namespace
- **Namespace Isolation**: Each team controls their own secrets

### Performance

- **Caching**: Secrets and namespace metadata cached with TTL
- **Filtering**: Early filtering reduces processing overhead
- **Efficient Lua**: Optimized scripts for minimal CPU usage

### Flexibility

- **Per-namespace Configuration**: Each namespace can have unique Splunk settings
- **Label-based Control**: Easy to enable/disable log collection
- **Customizable Filters**: Easy to modify container exclusion rules

## Adding a New Namespace

To add log collection for a new namespace:

```bash
./scripts/setup-namespace.sh my-new-namespace
```

This will:
1. Label the namespace
2. Create RBAC Role and RoleBinding
3. Provide instructions for creating the secret

## Configuration

### Environment Variables

In `manifests/base/05-fluent-bit-config.yaml`, you can configure:

- `Flush`: How often to flush records (default: 5 seconds)
- `Log_Level`: Fluent Bit log level (debug, info, warn, error)
- `cache_ttl`: Secret cache TTL in Lua scripts (default: 300 seconds)

### Excluding Additional Containers

Edit `manifests/base/04-lua-scripts.yaml` and add to the `excluded_containers` table:

```lua
local excluded_containers = {
    ["your-sidecar-name"] = true,
    -- add more here
}
```

### Using a Real Splunk Instance

Edit `manifests/base/05-fluent-bit-config.yaml` and update the OUTPUT section:

```ini
[OUTPUT]
    Name        http
    Match       *
    Host        your-splunk-hec.example.com
    Port        8088
    URI         /services/collector/event
    Format      json
    TLS         On
    TLS.Verify  On
```

## Monitoring

### Check Fluent Bit Status

```bash
# Check DaemonSet status
kubectl get daemonset -n logging

# Check pod logs for errors
kubectl logs -n logging -l app=fluent-bit --tail=100

# Check secret fetch errors
kubectl logs -n logging -l app=fluent-bit | grep "secret_fetch_error"
```

### Metrics

Fluent Bit exposes metrics on port 2020:

```bash
kubectl port-forward -n logging ds/fluent-bit 2020:2020
curl http://localhost:2020/api/v1/metrics
```

## Troubleshooting

See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common issues and solutions.

## Cleanup

```bash
./scripts/cleanup.sh
```

This will delete the k3d cluster and all resources.

## Production Considerations

Before deploying to production:

1. Review [PRODUCTION_CHECKLIST.md](docs/PRODUCTION_CHECKLIST.md)
2. Use real Splunk HEC endpoints
3. Configure TLS certificate verification
4. Set up monitoring and alerting
5. Adjust resource limits based on log volume
6. Implement log rotation policies
7. Set up backup for Fluent Bit configuration

## License

MIT

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## Support

For issues and questions, please refer to:
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- GitHub Issues (if applicable)
