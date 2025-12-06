# Fluent Bit Scalability: Handling 100 Containers in 100 Namespaces

## Table of Contents
1. [High-Level Overview](#high-level-overview)
2. [How Log Scraping Works at Scale](#how-log-scraping-works-at-scale)
3. [Concurrency Model](#concurrency-model)
4. [Lua Script Execution](#lua-script-execution)
5. [Performance Analysis](#performance-analysis)
6. [Bottlenecks and Optimization](#bottlenecks-and-optimization)

---

## High-Level Overview

### Scenario: 100 Containers in 100 Namespaces on One Node

```
┌──────────────────────────────────────────────────────────────┐
│                      Kubernetes Node                          │
│                                                                │
│  Namespace 1    Namespace 2    ...    Namespace 100          │
│  ┌─────────┐   ┌─────────┐          ┌─────────┐             │
│  │ Pod 1   │   │ Pod 2   │          │ Pod 100 │             │
│  │  app ─┐ │   │  app ─┐ │          │  app ─┐ │             │
│  └───────┼─┘   └───────┼─┘          └───────┼─┘             │
│          │             │                     │                │
│          └─────────────┼─────────────────────┘                │
│                        ↓                                      │
│              /var/log/containers/                             │
│              ├── pod1_ns1_app.log                            │
│              ├── pod2_ns2_app.log                            │
│              ├── ...                                          │
│              └── pod100_ns100_app.log                        │
│                        ↓                                      │
│              ┌─────────────────────┐                         │
│              │   FLUENT BIT        │                         │
│              │   Single Process    │                         │
│              │   Multiple Threads  │                         │
│              └─────────────────────┘                         │
└──────────────────────────────────────────────────────────────┘
```

---

## How Log Scraping Works at Scale

### 1. File Discovery and Management

Fluent Bit's tail plugin discovers and manages all log files:

```c
// Pseudocode of tail plugin initialization
tail_plugin_init() {
    // Scan directory for matching patterns
    glob_pattern = "/var/log/containers/*.log";
    files = glob(glob_pattern);
    
    // For each file found:
    for (file in files) {
        file_info = {
            .path = file,
            .fd = open(file, O_RDONLY),
            .inotify_wd = inotify_add_watch(inotify_fd, file, IN_MODIFY),
            .offset = 0,
            .rotated = false
        };
        
        // Add to watched files list
        watched_files.append(file_info);
    }
    
    // Also watch directory for new files
    inotify_add_watch(inotify_fd, "/var/log/containers/", IN_CREATE);
}
```

**Result**: One inotify file descriptor watches ALL 100 log files simultaneously.

### 2. Single inotify Instance Watches Multiple Files

```
┌─────────────────────────────────────────────────────────┐
│             Single inotify File Descriptor              │
│                                                          │
│  Watching:                                              │
│  ├── /var/log/containers/pod1_ns1_app.log (wd=1)      │
│  ├── /var/log/containers/pod2_ns2_app.log (wd=2)      │
│  ├── /var/log/containers/pod3_ns3_app.log (wd=3)      │
│  ├── ...                                                │
│  └── /var/log/containers/pod100_ns100_app.log (wd=100)│
│                                                          │
│  Directory watch:                                       │
│  └── /var/log/containers/ (for new files)             │
└─────────────────────────────────────────────────────────┘
```

**Key Point**: This is **extremely efficient** - the kernel notifies Fluent Bit whenever ANY of these files is modified.

### 3. Event Loop Processing

```c
// Simplified event loop (pseudocode)
main_loop() {
    while (running) {
        // Block until any watched file has an event
        // This is NON-BLOCKING for individual files!
        events = read_inotify_events(inotify_fd);
        
        for (event in events) {
            if (event.mask & IN_MODIFY) {
                // File was modified - read new lines
                file = find_file_by_watch_descriptor(event.wd);
                
                // Read all new lines from this file
                while ((line = read_line(file.fd)) != NULL) {
                    record = create_record(line, file);
                    
                    // Add to input buffer
                    flb_input_chunk_append(record);
                }
            }
            else if (event.mask & IN_CREATE) {
                // New file created in directory
                new_file = event.name;
                watch_new_file(new_file);
            }
        }
        
        // Process buffered records (filters, output)
        process_buffered_records();
    }
}
```

**This means:**
- When pod1 logs → inotify event → read pod1 log
- When pod47 logs → inotify event → read pod47 log
- When multiple pods log at once → multiple events → process in sequence
- **All in ONE event loop**, very efficient!

---

## Concurrency Model

### Fluent Bit Architecture

```
┌────────────────────────────────────────────────────────────┐
│              FLUENT BIT PROCESS                             │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Main Thread (Event Loop)                            │  │
│  │                                                       │  │
│  │  while (running):                                    │  │
│  │    inotify_events = read(inotify_fd)  ← BLOCKS HERE │  │
│  │    for event in inotify_events:                      │  │
│  │      file = event.file                               │  │
│  │      lines = read_new_lines(file)                    │  │
│  │      for line in lines:                              │  │
│  │        record = parse(line)                          │  │
│  │        chunk.append(record)                          │  │
│  └──────────────────────┬───────────────────────────────┘  │
│                         │                                   │
│                         ↓                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Chunk Queue (Thread-Safe)                           │  │
│  │  [Chunk 1] [Chunk 2] [Chunk 3] ... [Chunk N]       │  │
│  └──────────────────────┬───────────────────────────────┘  │
│                         │                                   │
│                         ↓                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Filter Thread(s)                                     │  │
│  │                                                       │  │
│  │  Process chunks sequentially:                        │  │
│  │  for record in chunk:                                │  │
│  │    record = kubernetes_filter(record)                │  │
│  │    record = lua_filter_1(record)                     │  │
│  │    record = lua_filter_2(record)                     │  │
│  │    record = lua_filter_3(record)                     │  │
│  └──────────────────────┬───────────────────────────────┘  │
│                         │                                   │
│                         ↓                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Output Thread(s) - Can be parallel!                 │  │
│  │                                                       │  │
│  │  Thread 1:          Thread 2:          Thread N:     │  │
│  │  Send chunk 1       Send chunk 2       Send chunk N  │  │
│  │  to Splunk          to Splunk          to Splunk     │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

### Key Characteristics

1. **Input (Tail Plugin)**: Single-threaded event loop
   - Uses **epoll/inotify** (efficient I/O multiplexing)
   - Processes files sequentially as events arrive
   - Very fast: just reading lines from files

2. **Filters**: Single-threaded per chunk
   - Records processed sequentially
   - **Lua scripts run SEQUENTIALLY**, one record at a time
   - Cannot run in parallel (Lua state is single-threaded)

3. **Output**: **Can be multi-threaded!**
   - Configurable with `Workers` setting
   - Multiple HTTP connections in parallel

---

## Lua Script Execution

### Sequential Processing (Not Parallel)

```c
// How Fluent Bit processes records through Lua filters
process_chunk_through_filters(chunk) {
    for (record in chunk.records) {
        // Filter 1: Kubernetes
        record = kubernetes_filter(record);
        if (record == NULL) continue;  // Dropped
        
        // Filter 2: Lua namespace filter
        record = lua_filter_namespace(record);
        if (record == NULL) continue;  // Dropped
        
        // Filter 3: Lua container filter
        record = lua_filter_container(record);
        if (record == NULL) continue;  // Dropped
        
        // Filter 4: Lua enrichment
        record = lua_filter_enrich(record);
        
        // Add to output queue
        output_queue.append(record);
    }
}
```

**Important**: For a chunk with 1000 records, Lua filter runs **1000 times sequentially**.

### Why Not Parallel?

```
┌─────────────────────────────────────────────────────────┐
│  Lua State (lua_State*) is NOT thread-safe             │
│                                                          │
│  ┌────────────────────────────────────────┐            │
│  │  Lua VM                                │            │
│  │  ┌──────────────────────────────┐     │            │
│  │  │  Global State                │     │            │
│  │  │  - Variables                 │     │            │
│  │  │  - Functions                 │     │            │
│  │  │  - Stack                     │     │            │
│  │  │  - Garbage Collector         │     │            │
│  │  └──────────────────────────────┘     │            │
│  │                                        │            │
│  │  Only ONE thread can access at a time │            │
│  └────────────────────────────────────────┘            │
│                                                          │
│  To parallelize, would need:                            │
│  - One Lua state per thread (high memory cost)         │
│  - OR Lua Lanes (complex, not used by Fluent Bit)     │
└─────────────────────────────────────────────────────────┘
```

### Performance of Sequential Processing

**Question**: Can it handle 100 containers logging at once?

**Answer**: Yes! Here's why:

```
Typical Lua Filter Performance:
- Simple filter (namespace check): ~0.1ms per record
- Medium filter (API call with cache): ~0.2ms per record
- Complex filter (multiple API calls): ~1ms per record

With caching (which we use):
- Namespace filter: ~0.1ms per record
- Container filter: ~0.1ms per record
- Enrichment filter: ~0.2ms per record
Total: ~0.4ms per record

For 100 containers each logging 10 lines/second:
= 1000 records/second
= 1000 * 0.4ms = 400ms of processing time per second
= 40% of one CPU core

This is EASILY handled by a single thread!
```

---

## Performance Analysis

### Scenario: 100 Containers, Various Log Rates

#### Low Rate: 1 log/second per container
```
Total: 100 logs/second
Processing time: 100 * 0.4ms = 40ms/second
CPU usage: ~4%
Memory: ~100MB
Verdict: ✅ No problem
```

#### Medium Rate: 10 logs/second per container
```
Total: 1,000 logs/second
Processing time: 1000 * 0.4ms = 400ms/second
CPU usage: ~40%
Memory: ~150MB
Verdict: ✅ Easy
```

#### High Rate: 100 logs/second per container
```
Total: 10,000 logs/second
Processing time: 10000 * 0.4ms = 4000ms/second = 4 seconds
CPU usage: ~400% (needs 4 cores!)
Memory: ~500MB-1GB
Verdict: ⚠️ Getting stressed, but manageable
```

#### Very High Rate: 1000 logs/second per container
```
Total: 100,000 logs/second
Processing time: 100000 * 0.4ms = 40 seconds/second
CPU usage: ~4000% (needs 40 cores!)
Memory: Several GB
Verdict: ❌ Will fall behind, need optimization
```

### Real-World Observations

Most production workloads:
- **Average**: 1-10 logs/second per container
- **Burst**: 50-100 logs/second per container (brief periods)
- **Sustained high**: Rare, usually indicates issues

**Fluent Bit can handle**:
- **Sustained**: 10,000-50,000 logs/second per node
- **Burst**: 100,000+ logs/second per node (buffered)

---

## How Fluent Bit Stays Fast

### 1. Efficient I/O Multiplexing

```
Traditional approach (BAD):
for file in files:
    if file.has_new_data():  # Check each file
        read_data(file)      # Would need to poll each file

inotify approach (GOOD):
events = wait_for_any_file_to_change()  # Kernel tells us!
for event in events:
    read_data(event.file)
```

**Benefit**: No wasted CPU checking files that haven't changed.

### 2. Batch Processing (Chunks)

```
Without batching:
for record in all_records:
    send_http_request(record)  # 1000 HTTP requests!

With batching (chunks):
chunk = collect_records(max_size=64KB)
send_http_request(chunk)  # 1 HTTP request for many records
```

**Benefit**: Reduces network overhead by 100-1000x.

### 3. Caching

```lua
-- WITHOUT caching (SLOW)
function get_namespace_labels(namespace)
    response = call_k8s_api(namespace)  -- 10-50ms API call
    return parse(response)
end
-- Would make API call for EVERY record!
-- 100 containers × 10 logs/sec = 1000 API calls/second
-- 1000 × 20ms = 20 seconds of API call time per second!

-- WITH caching (FAST)
local cache = {}
function get_namespace_labels(namespace)
    if cache[namespace] and not_expired(cache[namespace]) then
        return cache[namespace].data  -- < 0.001ms!
    end
    response = call_k8s_api(namespace)  -- Only once every 5 minutes
    cache[namespace] = {data: response, time: now()}
    return response
end
-- 100 namespaces × 1 API call / 300 seconds = 0.33 API calls/second
-- Reduction: 1000 calls/sec → 0.33 calls/sec (3000x improvement!)
```

### 4. Early Filtering

```
100 containers logging
    ↓
Filter by namespace label (50% dropped)
    ↓
50 containers remaining
    ↓
Filter by container name (10% dropped)
    ↓
45 containers remaining
    ↓
Enrich with Splunk config (expensive operation)
    ↓
Send to output

By filtering early, we process fewer records through expensive operations!
```

---

## Detailed Timing Breakdown

### Processing 100 Containers (10 logs/sec each = 1000 logs/sec)

```
┌─────────────────────────────────────────────────────────┐
│  Operation                  Time/Record    Total/Second  │
├─────────────────────────────────────────────────────────┤
│  inotify event              0.001ms       1ms           │
│  Read line from file        0.01ms        10ms          │
│  Parse JSON                 0.05ms        50ms          │
│  Create record              0.01ms        10ms          │
│  ─────────────────────────────────────────────────────  │
│  Kubernetes filter          0.1ms         100ms         │
│    (with caching)                                       │
│  ─────────────────────────────────────────────────────  │
│  Lua filter 1 (namespace)   0.1ms         100ms         │
│    - Check cache            0.001ms                     │
│    - API call (cache miss)  20ms (rare)                 │
│  ─────────────────────────────────────────────────────  │
│  Lua filter 2 (container)   0.05ms        50ms          │
│    - String comparison                                  │
│  ─────────────────────────────────────────────────────  │
│  Lua filter 3 (enrichment)  0.15ms        150ms         │
│    - Check cache            0.001ms                     │
│    - API call (cache miss)  30ms (rare)                 │
│    - Base64 decode          0.01ms                      │
│  ─────────────────────────────────────────────────────  │
│  Add to output queue        0.01ms        10ms          │
│  ─────────────────────────────────────────────────────  │
│  TOTAL PER SECOND                         480ms         │
│  CPU Usage                                ~48%          │
└─────────────────────────────────────────────────────────┘
```

**Conclusion**: With good caching, Fluent Bit uses less than 50% of one CPU core for 1000 logs/second.

---

## Bottlenecks and Optimization

### Potential Bottlenecks

#### 1. Kubernetes API Rate Limiting

**Problem**:
```
100 namespaces × No caching = 100 API calls on first run
If cache expires: 100 API calls every 5 minutes = 0.33 calls/sec (OK)
But if cache too short: 100 API calls every 10 seconds = 10 calls/sec (RATE LIMITED)
```

**Solution**:
```lua
-- Increase cache TTL
local cache_ttl = 600  -- 10 minutes instead of 60 seconds
```

#### 2. Lua Script Complexity

**Problem**:
```lua
-- BAD: Complex operation in hot path
function enrich(tag, timestamp, record)
    -- This runs for EVERY record
    for i = 1, 1000000 do
        math.sqrt(i)  -- Expensive!
    end
    return 1, timestamp, record
end
```

**Solution**:
```lua
-- GOOD: Do expensive work once, cache result
local precomputed_values = nil

function enrich(tag, timestamp, record)
    if precomputed_values == nil then
        precomputed_values = expensive_computation()
    end
    record["value"] = precomputed_values[record.key]
    return 1, timestamp, record
end
```

#### 3. Output Throughput

**Problem**: Output plugin can't keep up with input rate

**Solution 1**: Increase workers
```ini
[OUTPUT]
    Name     http
    Match    *
    Workers  4  # Use 4 parallel connections
```

**Solution 2**: Use buffering
```ini
[SERVICE]
    storage.type      filesystem
    storage.path      /var/log/flb-storage/
    storage.max_chunks_up  128  # Buffer more chunks
```

#### 4. Memory Pressure

**Problem**: Too many records buffered in memory

**Solution**:
```ini
[INPUT]
    Mem_Buf_Limit    10MB  # Increase buffer size

[SERVICE]
    storage.type     filesystem  # Use disk when memory full
```

---

## Optimization Strategies

### 1. Aggressive Filtering

```lua
-- Filter as early as possible
-- Drop ~50% of records before expensive operations

function filter_namespace(tag, timestamp, record)
    local namespace = record.kubernetes.namespace_name
    
    -- Quick check without API call
    if namespace == "kube-system" or 
       namespace == "kube-public" or 
       namespace:match("^istio-") then
        return -1, timestamp, record  -- DROP immediately
    end
    
    -- Only do expensive API call for remaining records
    local labels = get_namespace_labels(namespace)
    if not labels or labels["fluent-bit-enabled"] ~= "true" then
        return -1, timestamp, record
    end
    
    return 1, timestamp, record
end
```

### 2. Optimal Cache Configuration

```lua
-- Balance between freshness and API load
-- For stable environments: longer TTL
local namespace_cache_ttl = 600  -- 10 minutes
local secret_cache_ttl = 120     -- 2 minutes (secrets change more often)

-- For dynamic environments: shorter TTL
local namespace_cache_ttl = 180  -- 3 minutes
local secret_cache_ttl = 60      -- 1 minute
```

### 3. Sampling for Debug Logs

```lua
-- Don't send ALL debug logs, just sample
local debug_sample_rate = 0.01  -- 1%

function filter_debug_logs(tag, timestamp, record)
    if record.log:match("DEBUG") then
        -- Only keep 1% of debug logs
        if math.random() > debug_sample_rate then
            return -1, timestamp, record  -- DROP 99%
        end
    end
    return 1, timestamp, record
end
```

### 4. Batch Size Tuning

```ini
[SERVICE]
    Flush        5     # Seconds between flushes
                       # Lower = lower latency, higher CPU
                       # Higher = better throughput, higher latency

[INPUT]
    Mem_Buf_Limit  5MB  # Chunk size
                        # Larger = fewer flushes, better throughput
```

---

## Real-World Scaling Example

### Production Node with 100 Containers

```
Characteristics:
- 100 containers across 100 namespaces
- Average 5 logs/second per container
- Burst up to 50 logs/second per container
- Total sustained: 500 logs/second
- Total burst: 5000 logs/second

Fluent Bit Configuration:
- Memory buffer: 10MB
- Flush interval: 5 seconds
- Workers: 2
- Cache TTL: 300 seconds

Resource Usage:
- CPU: 10-20% (normal), 50-80% (burst)
- Memory: 200-400MB
- Network: 50-200 KB/sec

Performance:
✅ Handles sustained load easily
✅ Handles burst with buffering
✅ No API rate limiting issues (0.33 calls/sec)
✅ Logs delivered within 5-10 seconds
```

### High-Volume Node (Worst Case)

```
Characteristics:
- 100 containers
- Sustained 100 logs/second per container
- Total: 10,000 logs/second

Optimizations Applied:
- Aggressive early filtering (70% dropped)
- Effective: 3,000 logs/second to process
- Workers: 8
- Flush: 1 second
- Cache TTL: 600 seconds

Resource Usage:
- CPU: 200-300% (2-3 cores)
- Memory: 1-2GB
- Network: 500KB-1MB/sec

Performance:
✅ Can handle the load
⚠️  High resource usage
💡 Consider moving to dedicated logging nodes
```

---

## Summary

### How Fluent Bit Handles 100 Containers

1. **Single inotify instance** watches all 100 log files efficiently
2. **Event-driven I/O** processes files only when they have new data
3. **Sequential processing** through filters (Lua runs one record at a time)
4. **Caching** reduces API calls from thousands/sec to < 1/sec
5. **Batching** reduces network overhead by 100-1000x
6. **Parallel output** (optional) for faster network sends

### Lua Scripts Are NOT Parallel

- Lua scripts run **sequentially** on each record
- This is **not a problem** because:
  - Each record processes in ~0.4ms
  - 1000 logs/second only uses ~40% of one CPU core
  - Caching makes it even faster

### When Does It Struggle?

- **> 10,000 logs/second per node** (sustained)
- Poor caching (cache misses cause API call delays)
- Complex Lua scripts without optimization
- Output destination is slow (Splunk can't keep up)

### Best Practices for Scale

1. **Filter early** - Drop unwanted logs before expensive operations
2. **Cache aggressively** - Long TTL for stable data
3. **Batch effectively** - Balance latency vs throughput
4. **Monitor performance** - Watch CPU, memory, and dropped records
5. **Use multiple workers** - Parallel output connections
6. **Consider node dedication** - For very high volume, use dedicated logging nodes

The beauty of Fluent Bit's design is that it's **single-threaded where it matters** (simple, predictable) and **multi-threaded where it helps** (parallel output). Combined with caching and batching, it can easily handle 100 containers on a typical node.
