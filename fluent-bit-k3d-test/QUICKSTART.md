# Quick Start Guide

> **Note**: This is a streamlined quick start. For detailed documentation, see:
> - [README.md](README.md) - Complete overview and architecture
> - [docs/LOG_PIPELINE_FLOW.md](docs/LOG_PIPELINE_FLOW.md) - Detailed pipeline flow

## Prerequisites

Ensure you have the following installed:

```bash
# Check if tools are installed
docker --version
kubectl version --client
k3d version
```

If any are missing:

```bash
# Install Docker (Ubuntu/Debian)
curl -fsSL https://get.docker.com | sh

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Install k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

## 5-Minute Setup

### Step 1: Create k3d Cluster

```bash
cd fluent-bit-k3d-test
./scripts/setup-k3d-cluster.sh
```

Expected output:
```
✅ k3d cluster created successfully!
```

### Step 2: Deploy Everything

```bash
./scripts/complete-deployment.sh
```

This will:
1. Create namespaces (logging, splunk-mock, team-alpha, team-beta, team-gamma)
2. Deploy mock Splunk servers
3. Configure RBAC
4. Create secrets
5. Deploy Fluent Bit
6. Deploy test applications

### Step 3: Validate

```bash
./scripts/validate-setup.sh
```

Expected: All checks should pass ✅

## Verify Log Flow

### Check Consumer Logs (team-alpha, team-beta)

```bash
kubectl logs -n splunk-mock -l app=mock-splunk-consumer --tail=50 | grep "Token from body"
```

Expected output:
```
Token from body: ALPHA-TOKEN-12345
Token from body: BETA-TOKEN-67890
```

### Check Infrastructure Logs (team-gamma, system pods)

```bash
kubectl logs -n splunk-mock -l app=mock-splunk-infra --tail=30 | grep "Authorization"
```

Expected output:
```
Authorization: Splunk INFRA-TOKEN-STATIC
```

## Watch Logs in Real-Time

```bash
./scripts/watch-logs.sh
```

This opens a tmux session with 4 panes:
- Fluent Bit logs
- Mock Splunk Consumer
- Team Alpha app
- Team Beta app

## Understanding the Routing

The system routes logs based on **pod labels** and **container names**:

### Consumer Logs → mock-splunk-consumer

**Criteria**: Pod has label `consumer-splunk-index` **AND** container name is `app`

Example:
```yaml
metadata:
  labels:
    consumer-splunk-index: "alpha-consumer-index"
spec:
  containers:
  - name: app  # Must be exactly "app"
```

**Logs from**: team-alpha, team-beta (both have the label + container)

### Infrastructure Logs → mock-splunk-infra

**Criteria**: Everything else (no label OR container name != "app")

**Logs from**: team-gamma, system pods, Fluent Bit itself (excluded)

## What's Deployed

| Namespace | Pods | Purpose |
|-----------|------|---------|
| `logging` | fluent-bit (DaemonSet) | Log collection and routing |
| `splunk-mock` | mock-splunk-consumer, mock-splunk-infra | Mock Splunk HEC endpoints |
| `team-alpha` | test-app-alpha | Consumer app (routes to consumer Splunk) |
| `team-beta` | test-app-beta | Consumer app (routes to consumer Splunk) |
| `team-gamma` | test-app-gamma | Infrastructure app (routes to infra Splunk) |

## Adding Your Own Application

### For Consumer Logs

1. **Add label to pod**:
```yaml
metadata:
  labels:
    consumer-splunk-index: "my-index-name"
```

2. **Name container `app`**:
```yaml
spec:
  containers:
  - name: app
    image: myapp:latest
```

3. **Create secret** in your namespace:
```bash
kubectl create secret generic splunk-token \
  --from-literal=splunk-token="YOUR-SPLUNK-TOKEN" \
  -n your-namespace
```

4. **Add RBAC** (see [README.md](README.md) for RBAC configuration)

### For Infrastructure Logs

No special configuration needed! Logs automatically route to infrastructure Splunk if:
- Pod doesn't have `consumer-splunk-index` label, OR
- Container name is not `app`

## Troubleshooting

### No Logs Appearing

```bash
# Check Fluent Bit is running
kubectl get pods -n logging

# Check for errors
kubectl logs -n logging -l app=fluent-bit | grep -i error
```

### Only Alpha Logs, No Beta

```bash
# Verify beta pod labels
kubectl get pod test-app-beta -n team-beta -o jsonpath='{.metadata.labels}'

# Should include: "consumer-splunk-index":"beta-consumer-index"

# Verify container name
kubectl get pod test-app-beta -n team-beta -o jsonpath='{.spec.containers[*].name}'

# Should be: app
```

### Secret Fetch Errors

```bash
# Check RBAC
kubectl auth can-i get secret/splunk-token -n team-alpha \
  --as=system:serviceaccount:logging:fluent-bit

# Should return: yes
```

For more troubleshooting, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Cleanup

```bash
./scripts/cleanup.sh
```

This deletes the entire k3d cluster.

## Next Steps

- **Read the architecture**: [README.md](README.md)
- **Understand the pipeline**: [docs/LOG_PIPELINE_FLOW.md](docs/LOG_PIPELINE_FLOW.md)
- **Learn about Lua scripts**: [docs/LUA_SCRIPTS.md](docs/LUA_SCRIPTS.md)
- **Production deployment**: [docs/PRODUCTION_CHECKLIST.md](docs/PRODUCTION_CHECKLIST.md)

## Key Concepts

### Dual Routing

Logs are routed to one of two destinations:

1. **Consumer Splunk**: Application logs from labeled pods
   - Dynamic tokens (from secrets)
   - Dynamic indexes (from labels)
   - Per-namespace configuration

2. **Infrastructure Splunk**: System logs and unlabeled pods
   - Static token
   - Static index
   - Centralized configuration

### Secret Management

Each consumer namespace manages its own Splunk token:

```bash
# team-alpha has its own token
kubectl get secret splunk-token -n team-alpha

# team-beta has its own token
kubectl get secret splunk-token -n team-beta
```

### No Recursive Processing

Fluent Bit automatically excludes its own logs to prevent infinite loops:

```ini
[FILTER]
    Name    grep
    Match   kube.*
    Exclude kubernetes.namespace_name logging
```

## Architecture Summary

```
Application Pods
     ↓
Container Logs → Fluent Bit DaemonSet
     ↓
Classification (pod label + container name)
     ├──→ Consumer → Fetch Secret → Consumer Splunk
     └──→ Infrastructure → Static Config → Infrastructure Splunk
```

For the complete pipeline flow with detailed stages, see [docs/LOG_PIPELINE_FLOW.md](docs/LOG_PIPELINE_FLOW.md).
