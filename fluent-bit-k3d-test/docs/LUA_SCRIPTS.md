# Lua Scripts Documentation

## Overview

This document explains the Lua scripts used by Fluent Bit to classify and enrich log records based on pod labels and container names.

## Current Architecture

The system uses **two Lua scripts** for intelligent log routing:

1. **retag_logs.lua** - Classifies logs based on pod labels + container name
2. **enrich_splunk.lua** - Enriches consumer logs with Splunk tokens from secrets

## Script Execution Order

```
Container Logs
     ↓
Tail Input → Kubernetes Filter (adds metadata)
     ↓
Exclude Fluent Bit Logs (grep filter)
     ↓
[1] retag_logs.lua (classification)
     ↓
Rewrite Tag Filter (splits stream)
     ↓
     ├──→ consumer-logs → [2] enrich_splunk.lua (fetch secrets)
     │                          ↓
     │                    Consumer Splunk Output
     │
     └──→ tdp-infra → Modify Filter (static values)
                          ↓
                    Infrastructure Splunk Output
```

---

## 1. retag_logs.lua

### Purpose

Classifies logs into two categories based on pod metadata:
- **Consumer logs**: Pods with label `consumer-splunk-index` AND container name `app`
- **Infrastructure logs**: Everything else

### Location

`manifests/base/04-lua-scripts.yaml` → `retag_logs.lua`

### Flow Diagram

```
Record arrives
     ↓
Extract kubernetes metadata
     ↓
Check: labels["consumer-splunk-index"] exists?
     ↓              ↓
    YES            NO
     ↓              ↓
Check: container_name == "app"?    Set _log_type = "infrastructure"
     ↓              ↓               Set _new_tag = "tdp-infra"
    YES            NO
     ↓              ↓
Set _log_type = "consumer"
Set splunk_index from label value
Set _new_tag = "consumer-logs"
```

### Key Functions

#### `retag_by_label_and_container(tag, timestamp, record)`

Main classification function called by Fluent Bit.

**Parameters:**
- `tag` (string): Original log tag (e.g., `kube.var.log.containers...`)
- `timestamp` (number): Log timestamp
- `record` (table): Log record with Kubernetes metadata

**Returns:**
- `1` (always keeps record)
- Modified `record` with classification fields

**Logic:**

```lua
function retag_by_label_and_container(tag, timestamp, record)
    local kubernetes = record["kubernetes"]
    local new_tag = "tdp-infra"  -- Default to infrastructure

    if kubernetes then
        local labels = kubernetes["labels"]
        local container_name = kubernetes["container_name"]

        -- Check for consumer criteria
        if labels and labels["consumer-splunk-index"] and container_name == "app" then
            -- Consumer log
            record["splunk_index"] = labels["consumer-splunk-index"]
            record["_log_type"] = "consumer"
            new_tag = "consumer-logs"
        else
            -- Infrastructure log
            record["_log_type"] = "infrastructure"
            new_tag = "tdp-infra"
        end
    end

    record["_original_tag"] = tag
    record["_new_tag"] = new_tag

    return 1, timestamp, record
end
```

### Fields Added to Record

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `_log_type` | string | Classification type | `"consumer"` or `"infrastructure"` |
| `_new_tag` | string | Target tag for re-tagging | `"consumer-logs"` or `"tdp-infra"` |
| `_original_tag` | string | Original Fluent Bit tag | `kube.var.log.containers...` |
| `splunk_index` | string | Splunk index (consumer only) | `"alpha-consumer-index"` |

### Example Input/Output

**Input Record** (team-alpha pod):
```json
{
  "log": "Application log message",
  "kubernetes": {
    "pod_name": "test-app-alpha",
    "namespace_name": "team-alpha",
    "container_name": "app",
    "labels": {
      "consumer-splunk-index": "alpha-consumer-index",
      "team": "alpha"
    }
  }
}
```

**Output Record**:
```json
{
  "log": "Application log message",
  "_log_type": "consumer",
  "_new_tag": "consumer-logs",
  "_original_tag": "kube.var.log.containers.test-app-alpha_team-alpha_app-abc123.log",
  "splunk_index": "alpha-consumer-index",
  "kubernetes": { ... }
}
```

**Input Record** (infrastructure pod):
```json
{
  "log": "System log message",
  "kubernetes": {
    "pod_name": "test-app-gamma",
    "namespace_name": "team-gamma",
    "container_name": "app",
    "labels": {
      "team": "gamma"
      // No consumer-splunk-index label
    }
  }
}
```

**Output Record**:
```json
{
  "log": "System log message",
  "_log_type": "infrastructure",
  "_new_tag": "tdp-infra",
  "_original_tag": "kube.var.log.containers.test-app-gamma_team-gamma_app-xyz789.log",
  "kubernetes": { ... }
}
```

### Configuration

```yaml
[FILTER]
    Name    lua
    Match   kube.*
    script  /fluent-bit/scripts/retag_logs.lua
    call    retag_by_label_and_container
```

---

## 2. enrich_splunk.lua

### Purpose

Enriches consumer logs with Splunk HEC tokens fetched from Kubernetes secrets in the pod's namespace.

### Location

`manifests/base/04-lua-scripts.yaml` → `enrich_splunk.lua`

### Flow Diagram

```
Consumer log arrives (tag: consumer-logs)
     ↓
Extract namespace from kubernetes.namespace_name
     ↓
Check cache for secret (namespace key)
     ↓              ↓
  CACHED      NOT CACHED
     ↓              ↓
Return cached   Fetch from K8s API
token              ↓
                Parse JSON response
                   ↓
                Decode base64 token
                   ↓
                Cache result (30 min TTL)
     ↓              ↓
     └──────┬───────┘
            ↓
Add splunk_token to record
            ↓
Return enriched record
```

### Key Functions

#### `execute_command(cmd)`

Executes shell commands (curl, base64) and returns output.

```lua
function execute_command(cmd)
    local handle = io.popen(cmd)
    if not handle then
        return nil
    end
    local result = handle:read("*a")
    handle:close()
    return result
end
```

**Note**: Requires Fluent Bit debug image (`fluent/fluent-bit:2.2-debug`) which includes curl and base64 binaries.

#### `get_k8s_secret(namespace, secret_name)`

Fetches and decodes a Kubernetes secret using the Kubernetes API.

**Parameters:**
- `namespace` (string): Namespace containing the secret
- `secret_name` (string): Name of the secret (default: `"splunk-token"`)

**Returns:**
- `secret_data` (table): `{ token = "ALPHA-TOKEN-12345" }`
- `error_message` (string): Error if fetch failed

**Caching:**
- TTL: 1800 seconds (30 minutes)
- Key: `namespace:secret_name`
- Rationale: Reduces API calls, secrets change infrequently

**API Call:**
```bash
curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/team-alpha/secrets/splunk-token
```

**Response Example:**
```json
{
  "data": {
    "splunk-token": "QUxQSEEtVE9LRU4tMTIzNDU="  // base64 encoded
  }
}
```

**Decoding:**
```bash
echo "QUxQSEEtVE9LRU4tMTIzNDU=" | base64 -d
# Output: ALPHA-TOKEN-12345
```

#### `enrich_with_splunk_config(tag, timestamp, record)`

Main enrichment function called by Fluent Bit.

**Parameters:**
- `tag` (string): Log tag (should be `consumer-logs`)
- `timestamp` (number): Log timestamp
- `record` (table): Log record with Kubernetes metadata

**Returns:**
- `1` (always keeps record)
- Modified `record` with `splunk_token` field

**Logic:**

```lua
function enrich_with_splunk_config(tag, timestamp, record)
    local namespace = record["kubernetes"]["namespace_name"]
    local secret_name = "splunk-token"

    -- Fetch secret (cached)
    local secret_data, err = get_k8s_secret(namespace, secret_name)

    if not secret_data then
        -- Log error but keep record
        record["_secret_fetch_error"] = err or "unknown"
        record["_secret_name"] = secret_name
        record["_namespace"] = namespace
        return 1, timestamp, record
    end

    -- Add token to record
    record["splunk_token"] = secret_data.token
    record["_enriched"] = "true"

    return 1, timestamp, record
end
```

### Fields Added to Record

| Field | Type | Description | When Added |
|-------|------|-------------|------------|
| `splunk_token` | string | Splunk HEC token | Success |
| `_enriched` | string | Enrichment flag | Success |
| `_secret_fetch_error` | string | Error message | Failure |
| `_secret_name` | string | Secret name attempted | Failure |
| `_namespace` | string | Namespace attempted | Failure |

### Example Input/Output

**Input Record** (from retag_logs.lua):
```json
{
  "log": "Application log",
  "_log_type": "consumer",
  "splunk_index": "alpha-consumer-index",
  "kubernetes": {
    "namespace_name": "team-alpha",
    "pod_name": "test-app-alpha"
  }
}
```

**Output Record** (success):
```json
{
  "log": "Application log",
  "_log_type": "consumer",
  "splunk_index": "alpha-consumer-index",
  "splunk_token": "ALPHA-TOKEN-12345",
  "_enriched": "true",
  "kubernetes": {
    "namespace_name": "team-alpha",
    "pod_name": "test-app-alpha"
  }
}
```

**Output Record** (failure):
```json
{
  "log": "Application log",
  "_log_type": "consumer",
  "splunk_index": "alpha-consumer-index",
  "_secret_fetch_error": "Empty response",
  "_secret_name": "splunk-token",
  "_namespace": "team-alpha",
  "kubernetes": { ... }
}
```

### Configuration

```yaml
[FILTER]
    Name    lua
    Match   consumer-logs
    script  /fluent-bit/scripts/enrich_splunk.lua
    call    enrich_with_splunk_config
```

### RBAC Requirements

The Fluent Bit ServiceAccount needs permission to read secrets:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: fluent-bit-secret-reader
  namespace: team-alpha
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["splunk-token"]
  verbs: ["get"]
```

---

## Cache Implementation

Both scripts use a simple in-memory cache to reduce API calls.

### Cache Structure

```lua
local secret_cache = {}

-- Cache entry structure:
secret_cache["team-alpha:splunk-token"] = {
    data = { token = "ALPHA-TOKEN-12345" },
    timestamp = 1733512345
}
```

### Cache Lookup Logic

```lua
local cache_key = namespace .. ":" .. secret_name
local cached = secret_cache[cache_key]

if cached and (os.time() - cached.timestamp) < cache_ttl then
    -- Cache hit - return cached data
    return cached.data
else
    -- Cache miss or expired - fetch from API
    -- ...
end
```

### Cache Tuning

**Default TTL**: 1800 seconds (30 minutes)

**Increase for production** (less API load):
```lua
local cache_ttl = 3600  -- 60 minutes
```

**Decrease for testing** (faster secret rotation):
```lua
local cache_ttl = 60  -- 1 minute
```

**Cache Invalidation**:
- Cache is per Fluent Bit pod instance
- Restarting Fluent Bit clears the cache
- No manual invalidation mechanism

---

## Performance Considerations

### API Call Frequency

**Without caching** (assuming 10 consumer pods, 1 log/sec each):
- 10 pods × 1 log/sec = 10 API calls/sec
- = 600 API calls/minute per Fluent Bit pod

**With 30-minute caching**:
- Initial: 1 API call per namespace
- Ongoing: 1 API call per namespace every 30 minutes
- = ~0.033 API calls/minute per namespace

**Reduction**: 99.99% fewer API calls

### Memory Usage

**Per cache entry**: ~100 bytes
- Key: ~30 bytes
- Token: ~30 bytes
- Timestamp: 8 bytes
- Overhead: ~32 bytes

**Total cache size** (100 namespaces): ~10 KB

### CPU Usage

**Lua execution time**: <1ms per log record
- Label lookup: O(1) hash table access
- String operations: Negligible
- Cache lookup: O(1) hash table access

---

## Debugging

### Enable Lua Debug Logging

Edit Fluent Bit configuration:
```ini
[SERVICE]
    Log_Level debug
```

### Check for Errors

**Secret fetch errors**:
```bash
kubectl logs -n logging -l app=fluent-bit | grep "_secret_fetch_error"
```

**General Lua errors**:
```bash
kubectl logs -n logging -l app=fluent-bit | grep -i "lua error"
```

### Verify Classification

Check Fluent Bit stdout to see classification fields:
```bash
kubectl logs -n logging -l app=fluent-bit --tail=50 | jq ._log_type
```

Expected output:
```
"consumer"
"consumer"
"infrastructure"
"consumer"
...
```

### Test Secret Fetching Manually

From inside Fluent Bit pod:
```bash
kubectl exec -it -n logging fluent-bit-xxxxx -- sh

# Inside pod:
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/team-alpha/secrets/splunk-token \
  | jq -r '.data."splunk-token"' | base64 -d

# Expected: ALPHA-TOKEN-12345
```

---

## Security Considerations

### Least Privilege

- ServiceAccount only has `get` permission on specific secret names
- Cannot list all secrets
- Cannot modify secrets
- Scoped per namespace via Role (not ClusterRole)

### Secret Exposure

- Tokens are in memory only (cache)
- Tokens logged to stdout in debug fields (not recommended for production)
- Consider removing `_enriched` and token fields before final output in production

### Container Requirements

Requires **debug image** for curl and base64:
```yaml
image: fluent/fluent-bit:2.2-debug
```

**Production alternative**: Use official image + install curl/base64 via init container

---

## Common Issues

### Issue: `_secret_fetch_error: "Empty response"`

**Cause**: RBAC permissions not configured

**Fix**:
```bash
kubectl auth can-i get secret/splunk-token -n team-alpha \
  --as=system:serviceaccount:logging:fluent-bit

# Should return: yes
```

### Issue: `_secret_fetch_error: "Missing splunk-token in secret"`

**Cause**: Secret exists but doesn't have `splunk-token` key

**Fix**: Check secret structure:
```bash
kubectl get secret splunk-token -n team-alpha -o yaml
```

Expected:
```yaml
data:
  splunk-token: QUxQSEEtVE9LRU4tMTIzNDU=
```

### Issue: Logs classified as infrastructure instead of consumer

**Cause**: Pod missing label or wrong container name

**Fix**: Verify pod configuration:
```bash
# Check label
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.metadata.labels.consumer-splunk-index}'

# Check container name
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.containers[*].name}'
```

Both must be present:
- Label: `consumer-splunk-index` with a value
- Container: named exactly `app`

---

## Related Documentation

- [LOG_PIPELINE_FLOW.md](LOG_PIPELINE_FLOW.md) - Complete pipeline walkthrough
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Troubleshooting guide
- [PRODUCTION_CHECKLIST.md](PRODUCTION_CHECKLIST.md) - Production deployment
