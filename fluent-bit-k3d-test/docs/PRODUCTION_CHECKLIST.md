# Production Deployment Checklist

## Pre-Deployment

### 1. Infrastructure Assessment

- [ ] Determine cluster size and node count
- [ ] Calculate expected log volume (GB/day)
- [ ] Identify all namespaces that will send logs
- [ ] Map teams/namespaces to Splunk indexes
- [ ] Verify Splunk HEC endpoint availability
- [ ] Check network connectivity from cluster to Splunk
- [ ] Assess if dedicated nodes for logging are needed

### 2. Security Review

- [ ] Review RBAC policies with security team
- [ ] Ensure secrets are encrypted at rest
- [ ] Plan secret rotation strategy
- [ ] Review service account permissions
- [ ] Implement network policies if required
- [ ] Enable audit logging for secret access
- [ ] Document who has access to logging namespace

### 3. Splunk Configuration

- [ ] Create Splunk HEC tokens for each team/namespace
- [ ] Create/verify Splunk indexes exist
- [ ] Configure index retention policies
- [ ] Set up index permissions and access control
- [ ] Test HEC endpoints with curl
- [ ] Document token-to-index mappings
- [ ] Plan token rotation schedule

## Deployment Configuration

### 1. Update Fluent Bit Configuration

**File: `manifests/base/05-fluent-bit-config.yaml`**

```ini
[OUTPUT]
    Name        http
    Match       *
    Host        your-splunk-hec.example.com  # ← Update this
    Port        8088
    URI         /services/collector/event
    Format      json
    TLS         On                            # ← Enable TLS
    TLS.Verify  On                            # ← Verify certificates
    Header      Authorization Splunk ${splunk_token}
    Retry_Limit 3
    net.keepalive on
```

### 2. Resource Sizing

**File: `manifests/base/06-fluent-bit-daemonset.yaml`**

Adjust based on log volume:

```yaml
resources:
  limits:
    cpu: 500m      # Increase for high volume
    memory: 512Mi  # Increase for high volume
  requests:
    cpu: 200m
    memory: 256Mi
```

**Formula**: ~100MB memory per 10K logs/second

### 3. Update Container Exclusions

**File: `manifests/base/04-lua-scripts.yaml`**

Add your sidecar containers:

```lua
local excluded_containers = {
    ["your-sidecar-name"] = true,
    ["monitoring-agent"] = true,
    -- Add all non-application containers
}
```

### 4. Adjust Cache TTL

Balance between API load and freshness:

```lua
-- For frequent secret changes
local cache_ttl = 60  -- 1 minute

-- For stable environments
local cache_ttl = 600  -- 10 minutes
```

## Namespace Setup

### For Each Consumer Namespace

Consumer logs are routed based on **pod labels** and **container names**, not namespace labels.

1. **Create Splunk token secret**:
   ```bash
   kubectl create secret generic splunk-token \
     --from-literal=splunk-token='<HEC-TOKEN>' \
     --namespace=<namespace>
   ```

2. **Apply RBAC** (create Role and RoleBinding):
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: fluent-bit-secret-reader
     namespace: <namespace>
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
     namespace: <namespace>
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: fluent-bit-secret-reader
   subjects:
   - kind: ServiceAccount
     name: fluent-bit
     namespace: logging
   EOF
   ```

3. **Label your pods** (in pod manifests):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: my-app
     namespace: <namespace>
     labels:
       consumer-splunk-index: "prod-api-logs"  # Your Splunk index
   spec:
     containers:
     - name: app  # Must be exactly "app"
       image: myapp:latest
   ```

4. **Document configuration**:
   ```
   Namespace: production-api
   Token: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   Index: prod-api-logs (via pod label consumer-splunk-index)
   Retention: 90 days
   Owner: API Team
   Container Name: app (required for consumer routing)
   ```

## Deployment Steps

### 1. Deploy to Staging/Test Environment

```bash
# Create namespace
kubectl create namespace logging

# Apply RBAC
kubectl apply -f manifests/base/02-rbac.yaml

# Apply ConfigMaps
kubectl apply -f manifests/base/04-lua-scripts.yaml
kubectl apply -f manifests/base/05-fluent-bit-config.yaml

# Deploy DaemonSet
kubectl apply -f manifests/base/06-fluent-bit-daemonset.yaml
```

### 2. Verify Staging Deployment

```bash
# Check pods are running
kubectl get pods -n logging

# Check logs for errors
kubectl logs -n logging -l app=fluent-bit | grep -i error

# Verify logs reaching Splunk
# Search in Splunk: index=* source=kubernetes
```

### 3. Gradual Production Rollout

**Option A: Pod by Pod**
```bash
# Start with one pod in a namespace
# Add label to pod manifest
kubectl apply -f pod-with-consumer-label.yaml

# Monitor for 24 hours
# Check log volume, errors, latency

# Roll out to more pods
kubectl apply -f deployment-with-consumer-labels.yaml
```

**Option B: Node by Node** (DaemonSet rollout)
```yaml
spec:
  template:
    spec:
      nodeSelector:
        logging-enabled: "true"
```

```bash
# Label nodes gradually
kubectl label node node-1 logging-enabled=true
kubectl label node node-2 logging-enabled=true
# etc.
```

## Post-Deployment

### 1. Monitoring Setup

**Prometheus Metrics** (if using Fluent Bit metrics):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: fluent-bit-metrics
  namespace: logging
  labels:
    app: fluent-bit
spec:
  ports:
  - port: 2020
    targetPort: 2020
    name: metrics
  selector:
    app: fluent-bit
```

**Key Metrics to Monitor**:
- Log ingestion rate
- Filter drop rate
- API call failures
- Memory/CPU usage
- Buffer utilization

### 2. Alerting Rules

Set up alerts for:

```yaml
# High error rate
- alert: FluentBitHighErrorRate
  expr: rate(fluentbit_output_errors_total[5m]) > 0.1
  
# Memory usage
- alert: FluentBitHighMemory
  expr: container_memory_usage_bytes{pod=~"fluent-bit.*"} > 400000000

# Pod restarts
- alert: FluentBitRestarting
  expr: rate(kube_pod_container_status_restarts_total{pod=~"fluent-bit.*"}[15m]) > 0
```

### 3. Verification Checklist

- [ ] All expected consumer pods are sending logs (check pod labels)
- [ ] No errors in Fluent Bit logs
- [ ] Consumer logs appearing in correct Splunk indexes
- [ ] Infrastructure logs routing correctly
- [ ] Log latency is acceptable (< 30 seconds)
- [ ] Resource usage is within limits
- [ ] No RBAC permission errors
- [ ] Secret access is working for all consumer namespaces
- [ ] Fluent Bit's own logs are excluded (no recursion)

### 4. Documentation

Document the following:

1. **Architecture Diagram**
   - Show log flow
   - Include all components
   - Document network paths

2. **Runbook**
   - How to add new namespace
   - How to rotate secrets
   - How to troubleshoot common issues
   - Emergency contact list

3. **Secret Management**
   - Location of secrets
   - Rotation schedule
   - Who has access
   - Backup/recovery procedure

4. **Monitoring Dashboard**
   - Link to Grafana/monitoring
   - Key metrics to watch
   - Alert escalation path

## Operational Procedures

### Adding a New Consumer Namespace

```bash
#!/bin/bash
# add-consumer-namespace.sh

NAMESPACE=$1
HEC_TOKEN=$2

# 1. Create secret
kubectl create secret generic splunk-token \
  --from-literal=splunk-token="$HEC_TOKEN" \
  --namespace=$NAMESPACE

# 2. Setup RBAC
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: fluent-bit-secret-reader
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: fluent-bit-secret-reader
subjects:
- kind: ServiceAccount
  name: fluent-bit
  namespace: logging
EOF

echo "✅ Namespace $NAMESPACE configured with Splunk token"
echo ""
echo "📝 Next steps:"
echo "   1. Add label 'consumer-splunk-index: <your-index>' to your pods"
echo "   2. Ensure container name is 'app'"
echo "   3. Example:"
echo "      labels:"
echo "        consumer-splunk-index: \"my-index\""
echo "      spec:"
echo "        containers:"
echo "        - name: app"
```

### Rotating Splunk Tokens

```bash
#!/bin/bash
# rotate-token.sh

NAMESPACE=$1
NEW_TOKEN=$2

# Update secret
kubectl create secret generic splunk-token \
  --from-literal=splunk-token="$NEW_TOKEN" \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Token rotated for namespace $NAMESPACE"
echo "⏳ New token will be used within 30 minutes (cache TTL)"
```

### Disabling Consumer Logging for Pods

Remove the `consumer-splunk-index` label from your pods:

```bash
# For a deployment
kubectl patch deployment <deployment-name> -n <namespace> \
  --type=json -p='[{"op": "remove", "path": "/spec/template/metadata/labels/consumer-splunk-index"}]'
```

Logs will route to infrastructure Splunk instead.

## Performance Tuning

### High Log Volume (> 100K logs/second)

1. **Increase buffer size**:
   ```ini
   [INPUT]
       Mem_Buf_Limit     50MB  # Increase from 5MB
   ```

2. **Increase flush interval**:
   ```ini
   [SERVICE]
       Flush        10  # Increase from 5 seconds
   ```

3. **Use multiple workers**:
   ```ini
   [OUTPUT]
       Workers      4
   ```

4. **Dedicated nodes**:
   ```yaml
   nodeSelector:
     node-role: logging
   tolerations:
   - key: logging
     operator: Equal
     value: "true"
     effect: NoSchedule
   ```

### Low Latency Requirements (< 5 seconds)

1. **Reduce flush interval**:
   ```ini
   [SERVICE]
       Flush        1  # Reduce to 1 second
   ```

2. **Disable buffering**:
   ```ini
   [OUTPUT]
       Retry_Limit  False
   ```

## Security Hardening

### 1. Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: fluent-bit-network-policy
  namespace: logging
spec:
  podSelector:
    matchLabels:
      app: fluent-bit
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}  # Allow Kubernetes API access
    ports:
    - protocol: TCP
      port: 443
  - to:  # Splunk HEC
    - ipBlock:
        cidr: <SPLUNK-IP>/32
    ports:
    - protocol: TCP
      port: 8088
```

### 2. Pod Security Standards

```yaml
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: fluent-bit-psp
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
    - ALL
  volumes:
    - 'configMap'
    - 'secret'
    - 'hostPath'
  hostNetwork: false
  hostIPC: false
  hostPID: false
  runAsUser:
    rule: 'MustRunAsNonRoot'
  seLinux:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'
```

## Backup and Disaster Recovery

### 1. Backup Configuration

```bash
# Backup all manifests
kubectl get all,secrets,configmaps,roles,rolebindings -n logging -o yaml > fluent-bit-backup.yaml

# Backup consumer namespace secrets
for ns in $(kubectl get secrets --all-namespaces -o json | jq -r '.items[] | select(.metadata.name=="splunk-token") | .metadata.namespace'); do
  kubectl get secret splunk-token -n $ns -o yaml > backup-$ns-secret.yaml
done
```

### 2. Recovery Procedure

```bash
# Restore logging namespace
kubectl apply -f fluent-bit-backup.yaml

# Restore namespace secrets
kubectl apply -f backup-*-secret.yaml
```

## Compliance and Audit

- [ ] Document data retention policies
- [ ] Ensure logs don't contain PII (or redact)
- [ ] Implement log access controls in Splunk
- [ ] Set up audit logging for secret access
- [ ] Review and approve all RBAC changes
- [ ] Maintain change log for configuration

## Sign-off

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Engineer | | | |
| Security | | | |
| Operations | | | |
| Team Lead | | | |

## Rollback Plan

If issues occur:

```bash
# 1. Scale down DaemonSet
kubectl scale daemonset fluent-bit -n logging --replicas=0

# 2. Fix issues

# 3. Scale back up
kubectl scale daemonset fluent-bit -n logging --replicas=<node-count>
```

Or:

```bash
# Complete removal
kubectl delete namespace logging
```

Logs will remain in Splunk; collection can be restored from backup.
