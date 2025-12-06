# Fluent Bit Log Pipeline Flow

This document provides a detailed walkthrough of how log events are processed through the Fluent Bit pipeline, from container logs to Splunk endpoints.

## Pipeline Overview Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CONTAINER LOG FILES                                │
│  /var/log/containers/test-app-alpha_team-alpha_app-<id>.log                │
│  /var/log/containers/test-app-beta_team-beta_app-<id>.log                  │
│  /var/log/containers/test-app-gamma_team-gamma_app-<id>.log                │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           INPUT: TAIL PLUGIN                                 │
│  - Path: /var/log/containers/*.log                                          │
│  - Parser: docker (JSON)                                                     │
│  - Tag: kube.*                                                               │
│  - Output: Raw log with 'log' field                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    FILTER 1: KUBERNETES ENRICHMENT                           │
│  - Match: kube.*                                                             │
│  - Queries Kubernetes API for metadata                                      │
│  - Adds: pod_name, namespace_name, container_name, labels, etc.            │
│  - Merge_Log: On (parses JSON logs)                                        │
│  - Keep_Log: Off (removes original 'log' field after merge)                │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    FILTER 2: EXCLUDE FLUENT BIT LOGS                        │
│  - Match: kube.*                                                             │
│  - Exclude: kubernetes.namespace_name = logging                             │
│  - Prevents recursive log processing                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│              FILTER 3: LUA CLASSIFICATION (retag_logs.lua)                  │
│  - Match: kube.*                                                             │
│  - Logic: Check if pod has label "consumer-splunk-index" AND                │
│           container name == "app"                                            │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ IF consumer-splunk-index label EXISTS AND container == "app":       │  │
│  │   - Set _log_type = "consumer"                                       │  │
│  │   - Set splunk_index = <value from label>                            │  │
│  │   - Set _new_tag = "consumer-logs"                                   │  │
│  │                                                                        │  │
│  │ ELSE:                                                                  │  │
│  │   - Set _log_type = "infrastructure"                                  │  │
│  │   - Set _new_tag = "tdp-infra"                                        │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                    ┌─────────────────┴──────────────────┐
                    │                                    │
                    ▼                                    ▼
    ┌───────────────────────────────┐  ┌───────────────────────────────┐
    │  FILTER 4a: REWRITE_TAG       │  │  FILTER 4b: REWRITE_TAG       │
    │  - Match: kube.*              │  │  - Match: kube.*              │
    │  - Rule: $_log_type ^consumer$│  │  - Rule: $_log_type ^infra.*$ │
    │  - New Tag: consumer-logs     │  │  - New Tag: tdp-infra         │
    │  - Keep_Record: true          │  │  - Keep_Record: true          │
    └───────────────────────────────┘  └───────────────────────────────┘
                    │                                    │
                    ▼                                    ▼
    ┌───────────────────────────────┐  ┌───────────────────────────────┐
    │  FILTER 5a: LUA ENRICHMENT    │  │  FILTER 5b: MODIFY            │
    │  (enrich_splunk.lua)          │  │  - Match: tdp-infra           │
    │  - Match: consumer-logs       │  │  - Add: splunk_index =        │
    │  - Fetch secret from K8s API  │  │    tdp-infrastructure-index   │
    │  - Secret: splunk-token       │  │  - Add: splunk_token =        │
    │  - Namespace: from k8s meta   │  │    INFRA-TOKEN-STATIC         │
    │  - Add: splunk_token          │  └───────────────────────────────┘
    │  - Add: _enriched = "true"    │                  │
    └───────────────────────────────┘                  │
                    │                                    │
                    ▼                                    ▼
    ┌───────────────────────────────┐  ┌───────────────────────────────┐
    │  OUTPUT 1: HTTP (Consumer)    │  │  OUTPUT 2: HTTP (Infra)       │
    │  - Match: consumer-logs       │  │  - Match: tdp-infra           │
    │  - Host: mock-splunk-consumer │  │  - Host: mock-splunk-infra    │
    │  - Port: 8088                 │  │  - Port: 8088                 │
    │  - URI: /services/collector/  │  │  - URI: /services/collector/  │
    │         event                 │  │         event                 │
    │  - Header: Authorization      │  │  - Header: Authorization      │
    │    Splunk ${splunk_token}     │  │    Splunk INFRA-TOKEN-STATIC  │
    │    (token in body as          │  │                               │
    │     workaround)               │  │                               │
    └───────────────────────────────┘  └───────────────────────────────┘
                    │                                    │
                    ▼                                    ▼
    ┌───────────────────────────────┐  ┌───────────────────────────────┐
    │  MOCK SPLUNK CONSUMER         │  │  MOCK SPLUNK INFRASTRUCTURE   │
    │  - Receives consumer logs     │  │  - Receives infrastructure    │
    │  - Token from JSON body:      │  │    logs                       │
    │    ALPHA-TOKEN-12345          │  │  - Token: INFRA-TOKEN-STATIC  │
    │    BETA-TOKEN-67890           │  │                               │
    │  - Index from label:          │  │  - Index:                     │
    │    alpha-consumer-index       │  │    tdp-infrastructure-index   │
    │    beta-consumer-index        │  │                               │
    └───────────────────────────────┘  └───────────────────────────────┘
```

## Detailed Stage-by-Stage Flow

### Stage 1: Container Log Files

**Location**: `/var/log/containers/`

Container logs are written by Kubernetes in JSON format:

```json
{
  "log": "{\"timestamp\":\"2025-12-06T20:54:33+00:00\",\"level\":\"INFO\",\"message\":\"Log from team-alpha consumer application\",\"counter\":966,\"team\":\"alpha\"}\n",
  "stream": "stdout",
  "time": "2025-12-06T20:54:33.316697086Z"
}
```

**File naming**: `<pod-name>_<namespace>_<container-name>-<container-id>.log`

Example: `test-app-alpha_team-alpha_app-4b6bcda6d710df18938f5458e4ba17fd.log`

---

### Stage 2: INPUT - Tail Plugin

**Configuration**:
```ini
[INPUT]
    Name              tail
    Path              /var/log/containers/*.log
    Parser            docker
    Tag               kube.*
    Refresh_Interval  5
    Mem_Buf_Limit     5MB
    Skip_Long_Lines   On
```

**Actions**:
1. Monitors all files matching `/var/log/containers/*.log`
2. Parses each line with `docker` parser (JSON format)
3. Tags all logs with prefix `kube.*`
4. Extracts filename to create specific tag

**Output**:
```json
{
  "log": "{\"timestamp\":\"2025-12-06T20:54:33+00:00\",\"level\":\"INFO\",...}",
  "stream": "stdout",
  "time": "2025-12-06T20:54:33.316697086Z"
}
```

**Tag**: `kube.var.log.containers.test-app-alpha_team-alpha_app-4b6bcda6d710df18938f5458e4ba17fd.log`

---

### Stage 3: FILTER 1 - Kubernetes Enrichment

**Configuration**:
```ini
[FILTER]
    Name                kubernetes
    Match               kube.*
    Kube_URL            https://kubernetes.default.svc:443
    Merge_Log           On
    Keep_Log            Off
    Labels              On
```

**Actions**:
1. Extracts pod/namespace/container info from tag
2. Queries Kubernetes API for metadata
3. Merges JSON `log` field into top-level record
4. Removes original `log` field (Keep_Log: Off)
5. Adds `kubernetes` object with metadata

**Output**:
```json
{
  "timestamp": "2025-12-06T20:54:33+00:00",
  "level": "INFO",
  "message": "Log from team-alpha consumer application",
  "counter": 966,
  "team": "alpha",
  "stream": "stdout",
  "time": "2025-12-06T20:54:33.316697086Z",
  "kubernetes": {
    "pod_name": "test-app-alpha",
    "namespace_name": "team-alpha",
    "container_name": "app",
    "labels": {
      "consumer-splunk-index": "alpha-consumer-index",
      "team": "alpha",
      "app": "test-app",
      "environment": "test"
    },
    "pod_id": "...",
    "host": "k3d-fluent-bit-test-agent-1",
    "container_image": "docker.io/library/busybox:latest"
  }
}
```

---

### Stage 4: FILTER 2 - Exclude Fluent Bit Logs

**Configuration**:
```ini
[FILTER]
    Name    grep
    Match   kube.*
    Exclude kubernetes.namespace_name logging
```

**Purpose**: Prevents recursive log processing

**Actions**:
1. Filters out all logs where `kubernetes.namespace_name == "logging"`
2. This excludes Fluent Bit's own logs from being processed
3. **Critical fix**: Without this, Fluent Bit would read its own stdout logs from `/var/log/containers/`, creating an infinite loop

**Result**: Only application logs proceed to next stage

---

### Stage 5: FILTER 3 - Lua Classification (retag_logs.lua)

**Configuration**:
```ini
[FILTER]
    Name    lua
    Match   kube.*
    script  /fluent-bit/scripts/retag_logs.lua
    call    retag_by_label_and_container
```

**Lua Logic**:
```lua
function retag_by_label_and_container(tag, timestamp, record)
    local kubernetes = record["kubernetes"]
    local new_tag = "tdp-infra"  -- Default

    if kubernetes then
        local labels = kubernetes["labels"]
        local container_name = kubernetes["container_name"]

        -- Check for consumer criteria
        if labels and labels["consumer-splunk-index"] and container_name == "app" then
            record["splunk_index"] = labels["consumer-splunk-index"]
            record["_log_type"] = "consumer"
            new_tag = "consumer-logs"
        else
            record["_log_type"] = "infrastructure"
            new_tag = "tdp-infra"
        end
    end

    record["_original_tag"] = tag
    record["_new_tag"] = new_tag

    return 1, timestamp, record
end
```

**Decision Logic**:

**Consumer Route** (when BOTH conditions are true):
- Pod has label `consumer-splunk-index` with a value
- Container name is exactly `"app"`

**Infrastructure Route** (all other cases):
- No `consumer-splunk-index` label
- Container name is not `"app"`
- System pods (kube-system, logging, etc.)

**Output Examples**:

Consumer log (team-alpha):
```json
{
  ...,
  "_log_type": "consumer",
  "_new_tag": "consumer-logs",
  "splunk_index": "alpha-consumer-index",
  "_original_tag": "kube.var.log.containers.test-app-alpha_team-alpha_app-...",
  "kubernetes": { "namespace_name": "team-alpha", ... }
}
```

Infrastructure log (team-gamma):
```json
{
  ...,
  "_log_type": "infrastructure",
  "_new_tag": "tdp-infra",
  "_original_tag": "kube.var.log.containers.test-app-gamma_team-gamma_app-...",
  "kubernetes": { "namespace_name": "team-gamma", ... }
}
```

---

### Stage 6: FILTER 4 - Rewrite Tag Filters

Two parallel rewrite_tag filters split the log stream:

#### FILTER 4a: Consumer Logs
```ini
[FILTER]
    Name                rewrite_tag
    Match               kube.*
    Rule                $_log_type ^consumer$ consumer-logs true
    Emitter_Name        re_emitted_consumer
```

**Actions**:
- Matches records where `_log_type == "consumer"`
- Re-emits with new tag: `consumer-logs`
- `Keep_Record: true` - keeps original record in `kube.*` stream (gets dropped later)

#### FILTER 4b: Infrastructure Logs
```ini
[FILTER]
    Name                rewrite_tag
    Match               kube.*
    Rule                $_log_type ^infrastructure$ tdp-infra true
    Emitter_Name        re_emitted_infra
```

**Actions**:
- Matches records where `_log_type == "infrastructure"`
- Re-emits with new tag: `tdp-infra`
- `Keep_Record: true` - keeps original record

**Result**: Log stream is now split into two tagged streams:
- `consumer-logs` - for consumer application logs
- `tdp-infra` - for infrastructure logs

---

### Stage 7a: FILTER 5a - Lua Enrichment for Consumer Logs

**Configuration**:
```ini
[FILTER]
    Name    lua
    Match   consumer-logs
    script  /fluent-bit/scripts/enrich_splunk.lua
    call    enrich_with_splunk_config
```

**Lua Logic** (simplified):
```lua
function enrich_with_splunk_config(tag, timestamp, record)
    local namespace = record["kubernetes"]["namespace_name"]
    local secret_name = "splunk-token"

    -- Fetch secret from Kubernetes API
    local secret_data, err = get_k8s_secret(namespace, secret_name)

    if not secret_data then
        record["_secret_fetch_error"] = err
        return 1, timestamp, record
    end

    -- Add token to record
    record["splunk_token"] = secret_data.token
    record["_enriched"] = "true"

    return 1, timestamp, record
end
```

**Actions**:
1. Extracts namespace from `kubernetes.namespace_name`
2. Fetches secret `splunk-token` from that namespace using curl + K8s API
3. Caches secret for 30 minutes to reduce API calls
4. Adds `splunk_token` field to record
5. **Note**: `splunk_index` was already added in Stage 5 from pod label

**Output** (team-alpha example):
```json
{
  ...,
  "splunk_token": "ALPHA-TOKEN-12345",
  "splunk_index": "alpha-consumer-index",
  "_enriched": "true",
  "kubernetes": {
    "namespace_name": "team-alpha",
    ...
  }
}
```

**RBAC Requirements**:
- ServiceAccount `fluent-bit` in namespace `logging`
- Role in each consumer namespace (`team-alpha`, `team-beta`) allowing:
  - `get` on secret `splunk-token`

---

### Stage 7b: FILTER 5b - Modify Filter for Infrastructure Logs

**Configuration**:
```ini
[FILTER]
    Name    modify
    Match   tdp-infra
    Add     splunk_index tdp-infrastructure-index
    Add     splunk_token INFRA-TOKEN-STATIC
```

**Actions**:
1. Adds static `splunk_index` field
2. Adds static `splunk_token` field
3. No Kubernetes API calls needed

**Output**:
```json
{
  ...,
  "splunk_token": "INFRA-TOKEN-STATIC",
  "splunk_index": "tdp-infrastructure-index",
  "kubernetes": { ... }
}
```

---

### Stage 8a: OUTPUT 1 - HTTP to Consumer Splunk

**Configuration**:
```ini
[OUTPUT]
    Name        http
    Match       consumer-logs
    Host        mock-splunk-consumer.splunk-mock.svc.cluster.local
    Port        8088
    URI         /services/collector/event
    Format      json
    Header      Authorization Splunk ${splunk_token}
    json_date_key timestamp
    json_date_format iso8601
```

**Actions**:
1. Matches logs with tag `consumer-logs`
2. Sends HTTP POST to mock Splunk consumer endpoint
3. Formats as JSON array
4. Attempts to set Authorization header (NOTE: `${splunk_token}` variable substitution doesn't work in Fluent Bit HTTP plugin)
5. **Workaround**: Token is included in JSON body, mock Splunk extracts it

**HTTP Request**:
```http
POST /services/collector/event HTTP/1.1
Host: mock-splunk-consumer.splunk-mock.svc.cluster.local:8088
Content-Type: application/json
Authorization: Splunk

[
  {
    "timestamp": "2025-12-06T20:54:33+00:00",
    "level": "INFO",
    "message": "Log from team-alpha consumer application",
    "splunk_token": "ALPHA-TOKEN-12345",
    "splunk_index": "alpha-consumer-index",
    "kubernetes": { ... }
  }
]
```

---

### Stage 8b: OUTPUT 2 - HTTP to Infrastructure Splunk

**Configuration**:
```ini
[OUTPUT]
    Name        http
    Match       tdp-infra
    Host        mock-splunk-infra.splunk-mock.svc.cluster.local
    Port        8088
    URI         /services/collector/event
    Format      json
    Header      Authorization Splunk INFRA-TOKEN-STATIC
    json_date_key timestamp
    json_date_format iso8601
```

**Actions**:
1. Matches logs with tag `tdp-infra`
2. Sends HTTP POST to mock Splunk infrastructure endpoint
3. Static token works in header (no variable substitution needed)

**HTTP Request**:
```http
POST /services/collector/event HTTP/1.1
Host: mock-splunk-infra.splunk-mock.svc.cluster.local:8088
Content-Type: application/json
Authorization: Splunk INFRA-TOKEN-STATIC

[
  {
    "timestamp": "2025-12-06T20:54:33+00:00",
    "level": "INFO",
    "message": "Log from team-gamma infrastructure application",
    "splunk_token": "INFRA-TOKEN-STATIC",
    "splunk_index": "tdp-infrastructure-index",
    "kubernetes": { ... }
  }
]
```

---

### Stage 9: Mock Splunk Endpoints

#### Mock Splunk Consumer
- Receives consumer logs from team-alpha and team-beta
- Extracts token from JSON body: `body_json[0].get('splunk_token')`
- Logs received tokens:
  - `ALPHA-TOKEN-12345` (from team-alpha namespace)
  - `BETA-TOKEN-67890` (from team-beta namespace)
- Logs received indexes:
  - `alpha-consumer-index`
  - `beta-consumer-index`

#### Mock Splunk Infrastructure
- Receives infrastructure logs from all non-consumer pods
- Token: `INFRA-TOKEN-STATIC` (from Authorization header)
- Index: `tdp-infrastructure-index`

---

## Complete Example: team-alpha Log Journey

### 1. Container Output
```json
{"timestamp":"2025-12-06T20:54:33+00:00","level":"INFO","message":"Log from team-alpha consumer application","counter":966,"team":"alpha"}
```

### 2. Written to File
`/var/log/containers/test-app-alpha_team-alpha_app-4b6bcda6d710df18938f5458e4ba17fd.log`:
```json
{"log":"{\"timestamp\":\"2025-12-06T20:54:33+00:00\",\"level\":\"INFO\",\"message\":\"Log from team-alpha consumer application\",\"counter\":966,\"team\":\"alpha\"}\n","stream":"stdout","time":"2025-12-06T20:54:33.316697086Z"}
```

### 3. Tail Input (Tag: `kube.*`)
```json
{
  "log": "{\"timestamp\":\"2025-12-06T20:54:33+00:00\",...}",
  "stream": "stdout",
  "time": "2025-12-06T20:54:33.316697086Z"
}
```

### 4. Kubernetes Filter
```json
{
  "timestamp": "2025-12-06T20:54:33+00:00",
  "level": "INFO",
  "message": "Log from team-alpha consumer application",
  "counter": 966,
  "team": "alpha",
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

### 5. Lua Classification
```json
{
  ...,
  "_log_type": "consumer",
  "_new_tag": "consumer-logs",
  "splunk_index": "alpha-consumer-index",
  "kubernetes": { ... }
}
```

### 6. Rewrite Tag (Tag: `consumer-logs`)
Same record, now tagged as `consumer-logs`

### 7. Lua Enrichment
```json
{
  ...,
  "splunk_token": "ALPHA-TOKEN-12345",
  "splunk_index": "alpha-consumer-index",
  "_enriched": "true",
  "kubernetes": { ... }
}
```

### 8. HTTP Output to mock-splunk-consumer
Sent as JSON to Splunk HEC endpoint

### 9. Mock Splunk Receives
Logs: `[CONSUMER-LOGS] Token from body: ALPHA-TOKEN-12345`

---

## Key Design Decisions

### 1. Why Exclude Fluent Bit's Own Logs?
**Problem**: Fluent Bit outputs logs to stdout → written to `/var/log/containers/` → Fluent Bit reads them → infinite loop

**Solution**: Grep filter excludes `namespace_name == "logging"`

### 2. Why Two-Stage Tagging (Lua + rewrite_tag)?
**Reason**: Lua filters can't change tags, only record content. The rewrite_tag filter is needed to actually split the stream.

**Flow**:
1. Lua adds `_log_type` and `_new_tag` fields
2. rewrite_tag uses these fields to re-emit with new tags
3. Subsequent filters can match on specific tags (`consumer-logs` vs `tdp-infra`)

### 3. Why Dynamic Secret Fetching?
**Goal**: Each team manages their own Splunk token as a Kubernetes secret

**Benefits**:
- Teams can rotate tokens independently
- No central token management
- Namespace isolation via RBAC

### 4. Why Keep_Record: true?
**Reason**: Prevents record loss during re-tagging

**Without it**: Original record would be dropped when re-emitted with new tag

### 5. Why Token in JSON Body (Workaround)?
**Problem**: Fluent Bit HTTP plugin doesn't support `${field}` variable substitution in headers

**Attempted**: `Header Authorization Splunk ${splunk_token}`

**Result**: Header shows `Authorization: Splunk ` (empty)

**Workaround**: Token is in JSON body, mock Splunk extracts it

---

## Verification Commands

### Check Consumer Logs Reaching Splunk
```bash
kubectl logs -n splunk-mock -l app=mock-splunk-consumer --tail=50 | grep "Token from body"
```

Expected output:
```
Token from body: ALPHA-TOKEN-12345
Token from body: BETA-TOKEN-67890
```

### Check Infrastructure Logs
```bash
kubectl logs -n splunk-mock -l app=mock-splunk-infra --tail=30 | grep "Authorization"
```

Expected output:
```
Authorization: Splunk INFRA-TOKEN-STATIC
```

### Debug Fluent Bit Processing
```bash
kubectl logs -n logging -l app=fluent-bit --tail=100 | grep "test-app-alpha"
```

### Check Secrets
```bash
kubectl get secret splunk-token -n team-alpha -o jsonpath='{.data.splunk-token}' | base64 -d
# Output: ALPHA-TOKEN-12345

kubectl get secret splunk-token -n team-beta -o jsonpath='{.data.splunk-token}' | base64 -d
# Output: BETA-TOKEN-67890
```

---

## Performance Considerations

### Secret Caching
- Lua script caches secrets for **30 minutes** (`cache_ttl = 1800`)
- Reduces Kubernetes API calls from ~12/min to ~0.033/min per namespace
- Cache is per Fluent Bit pod instance

### Tag Matching Efficiency
- Filters match on specific tags (`consumer-logs`, `tdp-infra`)
- Avoids processing all logs through all filters
- rewrite_tag enables efficient stream splitting

### Memory Management
- `Mem_Buf_Limit: 5MB` per tail input
- Prevents unbounded memory growth for large log files
- `Skip_Long_Lines: On` skips lines > 2000 chars

---

## Security Considerations

### RBAC Least Privilege
- Fluent Bit ServiceAccount has minimal permissions:
  - **ClusterRole**: `get`, `list`, `watch` on namespaces and pods (read-only)
  - **Role** (per namespace): `get` on specific secret `splunk-token` only

### Secret Isolation
- Each namespace has its own `splunk-token` secret
- team-alpha cannot access team-beta's token
- Fluent Bit fetches from correct namespace based on log metadata

### Network Isolation (Production)
- Use NetworkPolicies to restrict Fluent Bit → Splunk communication
- TLS for Splunk HEC endpoints
- Consider pod security policies for Fluent Bit DaemonSet

---

## Troubleshooting Pipeline Issues

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

**Check pod labels**:
```bash
kubectl get pod test-app-beta -n team-beta -o jsonpath='{.metadata.labels}'
```

Expected: `{"consumer-splunk-index":"beta-consumer-index",...}`

**Check container name**:
```bash
kubectl get pod test-app-beta -n team-beta -o jsonpath='{.spec.containers[*].name}'
```

Expected: `app`

### Logs Appear in Wrong Splunk Instance

**Check Fluent Bit stdout to see tags**:
```bash
kubectl logs -n logging -l app=fluent-bit --tail=50 | jq ._new_tag
```

Expected: `"consumer-logs"` or `"tdp-infra"`

### Secret Fetch Errors

**Check RBAC permissions**:
```bash
kubectl auth can-i get secret/splunk-token -n team-alpha --as=system:serviceaccount:logging:fluent-bit
```

Expected: `yes`

**Check secret exists**:
```bash
kubectl get secret splunk-token -n team-alpha
```

**Check Lua error in logs**:
```bash
kubectl logs -n logging -l app=fluent-bit | grep _secret_fetch_error
```
