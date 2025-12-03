# Quick Start Guide

## Prerequisites

Before you begin, ensure you have the following installed:

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

### Step 1: Extract the Project

```bash
tar xzf fluent-bit-k3d-test.tar.gz
cd fluent-bit-k3d-test
```

### Step 2: Create k3d Cluster

```bash
./scripts/setup-k3d-cluster.sh
```

Expected output:
```
✅ k3d cluster created successfully!
```

### Step 3: Deploy Everything

```bash
./scripts/complete-deployment.sh
```

This will deploy:
- Namespaces (logging, team-alpha, team-beta, team-gamma, splunk-mock)
- RBAC configuration
- Secrets with Splunk configuration
- Lua filter scripts
- Fluent Bit DaemonSet
- Mock Splunk server
- Test applications

Expected output:
```
✅ Deployment Complete!
```

### Step 4: Validate

```bash
./scripts/validate-setup.sh
```

This checks:
- All pods are running
- RBAC is configured correctly
- Secrets exist and are readable
- Logs are flowing to Mock Splunk

### Step 5: Watch Logs

```bash
./scripts/watch-logs.sh
```

This opens multiple log streams (requires tmux for best experience).

## What to Expect

### Logs Should Appear

**team-alpha**:
- Token: `ALPHA-TOKEN-12345`
- Index: `team-alpha-logs`
- Logs should appear in Mock Splunk

**team-beta**:
- Token: `BETA-TOKEN-67890`
- Index: `team-beta-logs`
- Logs should appear in Mock Splunk

### Logs Should NOT Appear

**team-gamma**:
- Namespace not labeled with `fluent-bit-enabled: true`
- Logs should be filtered out

## Manual Verification

### Check Fluent Bit is Processing Logs

```bash
kubectl logs -n logging -l app=fluent-bit --tail=50
```

Look for:
- Kubernetes metadata enrichment
- Lua filter execution
- No errors fetching secrets

### Check Mock Splunk Received Logs

```bash
kubectl logs -n splunk-mock -l app=mock-splunk --tail=50
```

Look for:
- "Received log event" messages
- Authorization headers with correct tokens
- Log content from test applications

### Check Test Applications

```bash
# team-alpha
kubectl logs test-app-alpha -n team-alpha --tail=10

# team-beta
kubectl logs test-app-beta -n team-beta --tail=10

# team-gamma (these should NOT reach Splunk)
kubectl logs test-app-gamma -n team-gamma --tail=10
```

## Common Commands

```bash
# Get all pods
kubectl get pods -A

# Check Fluent Bit DaemonSet
kubectl get daemonset -n logging

# Check secrets
kubectl get secrets -n team-alpha
kubectl get secrets -n team-beta

# Describe a pod
kubectl describe pod test-app-alpha -n team-alpha

# Delete and recreate a pod
kubectl delete pod test-app-alpha -n team-alpha
kubectl apply -f manifests/test-apps/test-applications.yaml
```

## Troubleshooting

### Fluent Bit Pod Not Starting

```bash
# Check pod status
kubectl get pods -n logging

# Check events
kubectl describe daemonset fluent-bit -n logging

# Check logs
kubectl logs -n logging -l app=fluent-bit
```

### No Logs Reaching Mock Splunk

```bash
# Check if Mock Splunk is running
kubectl get pods -n splunk-mock

# Check Fluent Bit logs for errors
kubectl logs -n logging -l app=fluent-bit | grep -i error

# Check if secrets are readable
kubectl get secret splunk-config -n team-alpha -o yaml
```

### Namespace Filter Not Working

```bash
# Check namespace labels
kubectl get ns team-alpha,team-beta,team-gamma --show-labels

# Check Fluent Bit logs for filter execution
kubectl logs -n logging -l app=fluent-bit | grep namespace
```

## Next Steps

1. **Review the Architecture**: See `docs/ARCHITECTURE.md`
2. **Add Your Own Namespace**: Use `./scripts/setup-namespace.sh my-namespace`
3. **Configure Real Splunk**: Edit `manifests/base/05-fluent-bit-config.yaml`
4. **Customize Filters**: Edit Lua scripts in `manifests/base/04-lua-scripts.yaml`

## Cleanup

When you're done testing:

```bash
./scripts/cleanup.sh
```

This deletes the entire k3d cluster.

## Production Deployment

Before deploying to production:

1. Replace Mock Splunk with real Splunk HEC endpoint
2. Use real Splunk tokens in secrets
3. Adjust resource limits based on log volume
4. Configure TLS certificate verification
5. Set up monitoring and alerting
6. Review security and RBAC policies
7. Test secret rotation procedures

See `docs/PRODUCTION_CHECKLIST.md` for detailed guidance.
