# Troubleshooting Guide

## Common Issues and Solutions

### 1. Fluent Bit Pods Not Starting

#### Symptoms
```bash
kubectl get pods -n logging
# Output shows CrashLoopBackOff or ImagePullBackOff
```

#### Solutions

**Check pod status:**
```bash
kubectl describe pod -n logging -l app=fluent-bit
```

**Common causes:**

1. **Volume mount issues (k3d specific)**
   - k3d uses `/var/lib/rancher/k3s/agent/containerd` instead of `/var/lib/docker/containers`
   - Verify the volume mount in the DaemonSet matches your cluster

2. **RBAC issues**
   ```bash
   # Check if ServiceAccount exists
   kubectl get sa fluent-bit -n logging
   
   # Check RBAC bindings
   kubectl get clusterrolebinding fluent-bit-cluster-reader
   ```

3. **ConfigMap issues**
   ```bash
   # Verify ConfigMaps exist
   kubectl get configmap -n logging
   
   # Check ConfigMap content
   kubectl get configmap fluent-bit-config -n logging -o yaml
   ```

---

### 2. No Logs Reaching Splunk/Mock Splunk

#### Symptoms
Mock Splunk shows no "Received log event" messages

#### Diagnostic Steps

```bash
# 1. Check if Mock Splunk is running
kubectl get pods -n splunk-mock
kubectl logs -n splunk-mock -l app=mock-splunk

# 2. Check Fluent Bit logs
kubectl logs -n logging -l app=fluent-bit --tail=100

# 3. Check if test apps are generating logs
kubectl logs test-app-alpha -n team-alpha
```

#### Common Causes

1. **Namespace filtering**
   - Namespace missing `fluent-bit-enabled: true` label
   ```bash
   kubectl get ns team-alpha --show-labels
   kubectl label namespace team-alpha fluent-bit-enabled=true
   ```

2. **Container filtering**
   - Container name in exclusion list
   - Check `filter_container.lua` script

3. **Secret fetch failure**
   ```bash
   # Check if secrets exist
   kubectl get secret splunk-config -n team-alpha
   
   # Check Fluent Bit logs for secret errors
   kubectl logs -n logging -l app=fluent-bit | grep secret_fetch_error
   ```

4. **Network connectivity**
   ```bash
   # Test connectivity from Fluent Bit to Mock Splunk
   kubectl exec -n logging -it $(kubectl get pod -n logging -l app=fluent-bit -o jsonpath='{.items[0].metadata.name}') -- sh
   # Inside the pod:
   wget -O- http://mock-splunk.splunk-mock.svc.cluster.local:8088
   ```

---

### 3. Secret Fetch Errors

#### Symptoms
```bash
kubectl logs -n logging -l app=fluent-bit | grep "_secret_fetch_error"
```

#### Solutions

1. **Check secret exists**
   ```bash
   kubectl get secret splunk-config -n team-alpha
   ```

2. **Check RBAC permissions**
   ```bash
   # Verify Role exists
   kubectl get role fluent-bit-secret-reader -n team-alpha
   
   # Verify RoleBinding exists
   kubectl get rolebinding fluent-bit-secret-reader -n team-alpha
   ```

3. **Check secret format**
   ```bash
   kubectl get secret splunk-config -n team-alpha -o yaml
   ```
   
   Ensure it has both keys:
   - `splunk-token`
   - `splunk-index`

4. **Test secret access manually**
   ```bash
   # Get a shell in Fluent Bit pod
   kubectl exec -n logging -it $(kubectl get pod -n logging -l app=fluent-bit -o jsonpath='{.items[0].metadata.name}') -- sh
   
   # Try to fetch the secret
   TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
   curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     -H "Authorization: Bearer $TOKEN" \
     https://kubernetes.default.svc/api/v1/namespaces/team-alpha/secrets/splunk-config
   ```

---

### 4. Logs from team-gamma Appearing (Should Be Filtered)

#### Symptoms
Logs from team-gamma appear in Mock Splunk, but they shouldn't

#### Solutions

1. **Check namespace label**
   ```bash
   kubectl get ns team-gamma --show-labels
   ```
   
   Should NOT have `fluent-bit-enabled: true`
   
   If it does:
   ```bash
   kubectl label namespace team-gamma fluent-bit-enabled-
   ```

2. **Check Lua filter execution**
   ```bash
   kubectl logs -n logging -l app=fluent-bit | grep "filter_namespace"
   ```

3. **Verify filter is configured**
   ```bash
   kubectl get configmap fluent-bit-config -n logging -o yaml | grep filter_namespace
   ```

---

### 5. High CPU/Memory Usage

#### Symptoms
```bash
kubectl top pods -n logging
# Shows high resource usage
```

#### Solutions

1. **Check log volume**
   ```bash
   # Count log events being processed
   kubectl logs -n logging -l app=fluent-bit | wc -l
   ```

2. **Increase cache TTL** to reduce API calls
   Edit `manifests/base/04-lua-scripts.yaml`:
   ```lua
   local cache_ttl = 600  -- Increase from 300 to 600 seconds
   ```

3. **Adjust resource limits**
   Edit `manifests/base/06-fluent-bit-daemonset.yaml`:
   ```yaml
   resources:
     limits:
       memory: 400Mi  # Increase if needed
     requests:
       cpu: 200m      # Increase if needed
       memory: 200Mi
   ```

4. **Add more aggressive filtering**
   - Filter at INPUT level instead of FILTER level
   - Exclude more container types
   - Use regex patterns for log exclusion

---

### 6. Kubernetes API Rate Limiting

#### Symptoms
```bash
kubectl logs -n logging -l app=fluent-bit | grep "429\|rate limit"
```

#### Solutions

1. **Increase cache TTL**
   ```lua
   local cache_ttl = 600  -- Higher value = fewer API calls
   ```

2. **Implement request throttling**
   Add delay between API calls in Lua scripts

3. **Use local caching**
   Lua scripts already implement caching, ensure it's working:
   ```bash
   kubectl logs -n logging -l app=fluent-bit | grep "cache"
   ```

---

### 7. Logs Missing Required Fields

#### Symptoms
Logs in Splunk missing `splunk_token` or `splunk_index` fields

#### Solutions

1. **Check Lua script execution**
   ```bash
   kubectl logs -n logging -l app=fluent-bit | grep "enrich_with_splunk_config"
   ```

2. **Verify filter order**
   Ensure filters are in correct order in `fluent-bit.conf`:
   1. kubernetes filter
   2. filter_namespace
   3. filter_container
   4. enrich_splunk_config

3. **Check for errors in Lua scripts**
   ```bash
   kubectl logs -n logging -l app=fluent-bit | grep -i "lua\|script"
   ```

---

### 8. DaemonSet Not Scheduling on All Nodes

#### Symptoms
```bash
kubectl get daemonset fluent-bit -n logging
# Shows: DESIRED: 3, READY: 1
```

#### Solutions

1. **Check node taints**
   ```bash
   kubectl get nodes -o json | jq '.items[].spec.taints'
   ```

2. **Add tolerations to DaemonSet**
   ```yaml
   spec:
     template:
       spec:
         tolerations:
         - key: node-role.kubernetes.io/master
           effect: NoSchedule
   ```

3. **Check node selectors**
   Remove or adjust node selectors if present

---

### 9. Curl/Base64 Commands Failing in Lua Scripts

#### Symptoms
```bash
kubectl logs -n logging -l app=fluent-bit | grep "sh: curl: not found"
```

#### Solutions

This shouldn't happen with the official Fluent Bit image, but if it does:

1. **Use a different Fluent Bit image** with curl/base64:
   ```yaml
   image: fluent/fluent-bit:2.2-debug
   ```

2. **Or install tools in init container**
   ```yaml
   initContainers:
   - name: install-tools
     image: busybox
     command: ['sh', '-c', 'cp /bin/sh /tools/']
     volumeMounts:
     - name: tools
       mountPath: /tools
   ```

---

## Debugging Commands

### Check Fluent Bit Configuration

```bash
# View current configuration
kubectl exec -n logging -it $(kubectl get pod -n logging -l app=fluent-bit -o jsonpath='{.items[0].metadata.name}') -- cat /fluent-bit/etc/fluent-bit.conf

# View Lua scripts
kubectl exec -n logging -it $(kubectl get pod -n logging -l app=fluent-bit -o jsonpath='{.items[0].metadata.name}') -- ls -la /fluent-bit/scripts/
```

### Test Kubernetes API Access

```bash
# Get a shell in Fluent Bit pod
kubectl exec -n logging -it $(kubectl get pod -n logging -l app=fluent-bit -o jsonpath='{.items[0].metadata.name}') -- sh

# Inside the pod:
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Test namespace access
curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/team-alpha

# Test secret access
curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/team-alpha/secrets/splunk-config
```

### Enable Debug Logging

Edit `manifests/base/05-fluent-bit-config.yaml`:

```ini
[SERVICE]
    Log_Level    debug  # Change from 'info' to 'debug'
```

Then restart Fluent Bit:
```bash
kubectl rollout restart daemonset fluent-bit -n logging
```

### Tail Multiple Logs Simultaneously

```bash
# In separate terminals:
kubectl logs -f -n logging -l app=fluent-bit
kubectl logs -f -n splunk-mock -l app=mock-splunk
kubectl logs -f test-app-alpha -n team-alpha
```

## Getting Help

If you're still stuck:

1. **Collect diagnostic information**:
   ```bash
   # Save to a file
   kubectl get all -A > diagnostics.txt
   kubectl logs -n logging -l app=fluent-bit --tail=500 >> diagnostics.txt
   kubectl get events -A >> diagnostics.txt
   ```

2. **Check GitHub Issues** (if applicable)

3. **Review documentation**:
   - [Fluent Bit Documentation](https://docs.fluentbit.io/)
   - [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

4. **Community Support**:
   - Fluent Bit Slack
   - Kubernetes Slack (#fluent-bit channel)
