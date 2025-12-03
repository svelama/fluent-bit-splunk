# Lua Scripts Documentation

## Overview

This document explains the Lua scripts used by Fluent Bit to filter and enrich log records.

## Script Execution Order

1. **filter_namespace.lua** - Filters logs by namespace label
2. **filter_container.lua** - Filters out system containers
3. **enrich_splunk.lua** - Enriches logs with Splunk configuration

## filter_namespace.lua

### Purpose
Filters logs based on namespace labels. Only processes logs from namespaces with `fluent-bit-enabled: true`.

### Flow Diagram
```
Record arrives → Extract namespace → Fetch namespace labels (cached)
                                              ↓
                           Has label fluent-bit-enabled=true?
                                    ↓            ↓
                                   YES          NO
                                    ↓            ↓
                               Keep record   Drop record
```

### Key Functions

#### `execute_command(cmd)`
Executes shell commands and returns output.

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

#### `get_namespace_labels(namespace)`
Fetches namespace labels from Kubernetes API with caching.

**Parameters:**
- `namespace` (string): Namespace name

**Returns:**
- Table of labels or nil

**Caching:**
- TTL: 300 seconds (5 minutes)
- Key: namespace name
- Rationale: Namespace labels rarely change

**Example:**
```lua
local labels = get_namespace_labels("team-alpha")
-- Returns: { ["fluent-bit-enabled"] = "true" }
```

#### `filter_by_namespace_label(tag, timestamp, record)`
Main filter function called by Fluent Bit.

**Parameters:**
- `tag` (string): Log tag
- `timestamp` (number): Log timestamp
- `record` (table): Log record with Kubernetes metadata

**Returns:**
- `-1` to drop the record
- `1` to keep the record

**Logic:**
```lua
if no kubernetes metadata → DROP
if no namespace name → DROP
if namespace not labeled with fluent-bit-enabled=true → DROP
else → KEEP
```

### API Call Example

```bash
curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/team-alpha
```

Response:
```json
{
  "metadata": {
    "name": "team-alpha",
    "labels": {
      "fluent-bit-enabled": "true",
      "team": "alpha"
    }
  }
}
```

### Customization

To require additional labels:

```lua
function filter_by_namespace_label(tag, timestamp, record)
    -- ... existing code ...
    
    -- Check for additional label
    if not ns_labels["environment"] or ns_labels["environment"] ~= "production" then
        return -1, timestamp, record
    end
    
    return 1, timestamp, record
end
```

---

## filter_container.lua

### Purpose
Filters out system and sidecar containers, keeping only application container logs.

### Exclusion Lists

#### Exact Match Exclusions
```lua
local excluded_containers = {
    ["coredns"] = true,
    ["local-path-provisioner"] = true,
    ["metrics-server"] = true,
    ["traefik"] = true,
    ["istio-proxy"] = true,
    ["istio-init"] = true,
    ["linkerd-proxy"] = true,
    ["linkerd-init"] = true,
    -- Add more as needed
}
```

#### Prefix Exclusions
```lua
local excluded_prefixes = {
    "svclb-",      -- k3s service load balancer
    "init-",       -- Init containers
    "setup-",      -- Setup containers
}
```

### Key Functions

#### `is_excluded_container(container_name)`
Checks if a container should be excluded.

**Parameters:**
- `container_name` (string): Name of the container

**Returns:**
- `true` if container should be excluded
- `false` if container should be kept

**Logic:**
```lua
if container_name in excluded_containers → true
if container_name starts with excluded_prefix → true
else → false
```

#### `filter_application_containers(tag, timestamp, record)`
Main filter function.

**Returns:**
- `-1` to drop the record
- `1` to keep the record

**Logic:**
```lua
if no kubernetes metadata → DROP
if no container name → DROP
if container in exclusion list → DROP
if pod has label fluent-bit-exclude=true → DROP
else → KEEP
```

### Customization

#### Add Your Sidecar
```lua
local excluded_containers = {
    -- ... existing ...
    ["your-sidecar-name"] = true,
    ["monitoring-agent"] = true,
}
```

#### Add Label-based Inclusion
```lua
function filter_application_containers(tag, timestamp, record)
    -- ... existing checks ...
    
    -- Only include containers with specific label
    local labels = kubernetes["labels"]
    if not labels or labels["log-collection"] ~= "enabled" then
        return -1, timestamp, record
    end
    
    return 1, timestamp, record
end
```

---

## enrich_splunk.lua

### Purpose
Enriches log records with Splunk configuration (HEC token and index) fetched from Kubernetes secrets.

### Flow Diagram
```
Record arrives → Extract namespace → Determine secret name
                                              ↓
                           Fetch secret from K8s API (cached)
                                              ↓
                                    Decode base64 values
                                              ↓
                           Enrich record with token and index
```

### Key Functions

#### `get_k8s_secret(namespace, secret_name)`
Fetches and decodes secret from Kubernetes API.

**Parameters:**
- `namespace` (string): Namespace containing the secret
- `secret_name` (string): Name of the secret

**Returns:**
- Table: `{ token = "...", index = "..." }`
- nil, error_message: If fetch fails

**Caching:**
- TTL: 60 seconds (1 minute)
- Key: `namespace/secret_name`
- Rationale: Allows quick secret rotation

**Example:**
```lua
local secret, err = get_k8s_secret("team-alpha", "splunk-config")
-- Returns: { token = "ALPHA-TOKEN-12345", index = "team-alpha-logs" }
```

#### `enrich_with_splunk_config(tag, timestamp, record)`
Main enrichment function.

**Logic:**
1. Extract namespace from record
2. Determine secret name (from pod label or use default)
3. Fetch secret from Kubernetes API
4. Decode base64 values
5. Add `splunk_token` and `splunk_index` to record

**Returns:**
- `1, timestamp, record` with enriched fields
- `-1, timestamp, record` if critical error

### API Call Example

```bash
curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/team-alpha/secrets/splunk-config
```

Response:
```json
{
  "data": {
    "splunk-token": "QUxQSEEtVE9LRU4tMTIzNDU=",
    "splunk-index": "dGVhbS1hbHBoYS1sb2dz"
  }
}
```

Decoded:
```
splunk-token: ALPHA-TOKEN-12345
splunk-index: team-alpha-logs
```

### Secret Format

Required keys in the secret:
- `splunk-token`: Splunk HEC token
- `splunk-index`: Splunk index name

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: splunk-config
  namespace: team-alpha
type: Opaque
stringData:
  splunk-token: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  splunk-index: "team-alpha-logs"
```

### Error Handling

If secret fetch fails:
- Record is kept (not dropped)
- Error fields added:
  - `_secret_fetch_error`: Error message
  - `_secret_name`: Secret name that was attempted
  - `_namespace`: Namespace

This allows debugging without losing logs.

### Customization

#### Use Different Secret Name per Pod
```lua
function enrich_with_splunk_config(tag, timestamp, record)
    -- ... existing code ...
    
    local secret_name = default_secret_name
    
    -- Check pod annotation
    local annotations = kubernetes["annotations"]
    if annotations and annotations["splunk-secret"] then
        secret_name = annotations["splunk-secret"]
    end
    
    -- ... rest of code ...
end
```

#### Add Additional Secret Fields
```lua
-- In get_k8s_secret function, add:
local splunk_sourcetype_b64 = response:match('"splunk%-sourcetype"%s*:%s*"([^"]+)"')
if splunk_sourcetype_b64 then
    local splunk_sourcetype = execute_command(string.format('echo "%s" | base64 -d', splunk_sourcetype_b64))
    secret_data.sourcetype = splunk_sourcetype:gsub("\n", "")
end

-- In enrich_with_splunk_config function:
record["splunk_sourcetype"] = secret_data.sourcetype
```

---

## Performance Considerations

### Caching Strategy

**Namespace Labels:**
- Cache TTL: 300 seconds
- Reason: Labels change infrequently
- Impact: Reduces API calls by ~99%

**Secrets:**
- Cache TTL: 60 seconds
- Reason: Allows faster secret rotation
- Impact: New secrets effective within 1 minute

### Memory Usage

Each cached entry stores:
- Namespace cache: ~100 bytes per namespace
- Secret cache: ~200 bytes per secret

For 100 namespaces:
- Total cache size: ~30KB
- Negligible impact on Fluent Bit memory

### API Call Rate

Without caching:
- 1000 logs/sec × 2 API calls = 2000 API calls/sec

With caching:
- ~20 API calls/sec (cache misses only)
- 99% reduction in API load

---

## Debugging Lua Scripts

### Enable Debug Output

Add debug prints:
```lua
function filter_by_namespace_label(tag, timestamp, record)
    print("DEBUG: Processing record for namespace: " .. tostring(record["kubernetes"]["namespace_name"]))
    -- ... rest of function ...
end
```

View in Fluent Bit logs:
```bash
kubectl logs -n logging -l app=fluent-bit | grep DEBUG
```

### Test Script Locally

Create test harness:
```lua
-- test.lua
package.path = package.path .. ";/path/to/scripts/?.lua"
require("filter_namespace")

local test_record = {
    kubernetes = {
        namespace_name = "team-alpha",
        container_name = "app"
    }
}

local code, ts, result = filter_by_namespace_label("test", 0, test_record)
print("Result code:", code)
print("Record:", require("inspect")(result))
```

Run:
```bash
lua test.lua
```

### Common Issues

#### 1. API Call Fails
```lua
-- Check token is readable
local token_file = io.open("/var/run/secrets/kubernetes.io/serviceaccount/token", "r")
if not token_file then
    print("ERROR: Cannot read service account token")
    return nil
end
```

#### 2. Base64 Decode Fails
```lua
-- Add error handling
local splunk_token = execute_command(string.format('echo "%s" | base64 -d 2>&1', splunk_token_b64))
if splunk_token:match("invalid") then
    print("ERROR: Invalid base64 encoding")
    return nil, "base64 decode failed"
end
```

#### 3. Cache Not Working
```lua
-- Add cache hit logging
function get_k8s_secret(namespace, secret_name)
    local cache_key = namespace .. "/" .. secret_name
    local cached = secret_cache[cache_key]
    
    if cached and (os.time() - cached.timestamp) < cache_ttl then
        print("DEBUG: Cache hit for " .. cache_key)
        return cached.data
    end
    
    print("DEBUG: Cache miss for " .. cache_key)
    -- ... fetch from API ...
end
```

---

## Best Practices

1. **Always check for nil**
   ```lua
   if not record or not record["kubernetes"] then
       return -1, timestamp, record
   end
   ```

2. **Use caching aggressively**
   - Reduces API load
   - Improves performance
   - But balance with freshness requirements

3. **Handle errors gracefully**
   - Don't drop logs on errors
   - Add error fields for debugging
   - Log errors to stdout

4. **Keep functions small**
   - Easier to test
   - Easier to debug
   - Better performance

5. **Document your changes**
   - Add comments
   - Update this documentation
   - Include examples

---

## Testing

### Unit Tests

Test individual functions:
```bash
# Test namespace filter
kubectl exec -n logging -it $(kubectl get pod -n logging -l app=fluent-bit -o jsonpath='{.items[0].metadata.name}') -- sh
# Inside pod:
lua -e "dofile('/fluent-bit/scripts/filter_namespace.lua'); print(get_namespace_labels('team-alpha'))"
```

### Integration Tests

Test end-to-end:
```bash
# Create test pod
kubectl run test-pod --image=busybox -n team-alpha -- sh -c "while true; do echo test; sleep 5; done"

# Check if logs appear in Splunk
kubectl logs -n splunk-mock -l app=mock-splunk | grep "test-pod"
```

### Load Tests

Test under high load:
```bash
# Create multiple test pods
for i in {1..10}; do
  kubectl run test-pod-$i --image=busybox -n team-alpha -- sh -c "while true; do echo test-$i; sleep 1; done"
done

# Monitor Fluent Bit performance
kubectl top pods -n logging
```
