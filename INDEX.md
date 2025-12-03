# Fluent Bit K3D Test - Complete Package

## 📦 Package Contents

You have downloaded a complete Fluent Bit setup for Kubernetes with dynamic Splunk configuration.

## 🎯 What You Get

### Complete Test Environment
- ✅ k3d cluster setup
- ✅ Fluent Bit DaemonSet with Lua filters
- ✅ Mock Splunk server for testing
- ✅ Test applications in multiple namespaces
- ✅ Full RBAC configuration
- ✅ Automation scripts
- ✅ Comprehensive documentation

### Production-Ready Components
- ✅ Namespace-based log filtering
- ✅ Container-based log filtering
- ✅ Dynamic secret-based Splunk configuration
- ✅ Caching for performance
- ✅ Error handling and logging
- ✅ Security best practices

## 📚 Files Included

### 1. Archive: `fluent-bit-k3d-test.tar.gz` (24KB)
Contains the complete project with:
- 6 executable scripts
- 8 Kubernetes manifests
- 5 documentation files
- Main README

### 2. Summary: `PROJECT_SUMMARY.md` (6KB)
Quick overview of the project structure and features

## 🚀 Getting Started

### Option 1: Quick Start (5 minutes)

```bash
# Extract the archive
tar xzf fluent-bit-k3d-test.tar.gz
cd fluent-bit-k3d-test

# Read the quick start guide
cat QUICKSTART.md

# Or jump right in:
./scripts/setup-k3d-cluster.sh
./scripts/complete-deployment.sh
./scripts/validate-setup.sh
```

### Option 2: Thorough Review

```bash
# Extract
tar xzf fluent-bit-k3d-test.tar.gz
cd fluent-bit-k3d-test

# Read documentation in order:
1. cat README.md                        # Overview
2. cat QUICKSTART.md                    # Setup guide
3. cat docs/ARCHITECTURE.md             # How it works
4. cat docs/LUA_SCRIPTS.md              # Script details
5. cat docs/TROUBLESHOOTING.md          # Common issues
6. cat docs/PRODUCTION_CHECKLIST.md     # Production guide

# Then proceed with setup
```

## 📖 Documentation Map

### For Quick Testing
→ **QUICKSTART.md** - Follow this for immediate results

### For Understanding
→ **README.md** - Overview and architecture
→ **docs/ARCHITECTURE.md** - Detailed data flow

### For Customization
→ **docs/LUA_SCRIPTS.md** - Modify filtering logic
→ **manifests/base/** - Kubernetes resources

### For Troubleshooting
→ **docs/TROUBLESHOOTING.md** - Common issues and fixes

### For Production
→ **docs/PRODUCTION_CHECKLIST.md** - Complete deployment guide

## 🎓 Learning Path

### Beginners
1. Read PROJECT_SUMMARY.md (this file)
2. Read QUICKSTART.md
3. Run the scripts
4. Watch logs with `./scripts/watch-logs.sh`

### Intermediate
1. Read README.md
2. Review docs/ARCHITECTURE.md
3. Examine Kubernetes manifests
4. Customize for your environment

### Advanced
1. Study docs/LUA_SCRIPTS.md
2. Review docs/PRODUCTION_CHECKLIST.md
3. Modify Lua scripts for your use case
4. Deploy to production

## 🔧 Key Scripts

| Script | Purpose | Time |
|--------|---------|------|
| `setup-k3d-cluster.sh` | Create local test cluster | 2 min |
| `complete-deployment.sh` | Deploy all components | 3 min |
| `validate-setup.sh` | Verify everything works | 1 min |
| `setup-namespace.sh` | Add new namespace | 1 min |
| `watch-logs.sh` | Monitor log flow | - |
| `cleanup.sh` | Remove everything | 1 min |

## 📋 Key Manifests

| File | Purpose |
|------|---------|
| `01-namespaces.yaml` | Create namespaces |
| `02-rbac.yaml` | Configure permissions |
| `03-secrets.yaml` | Splunk configuration |
| `04-lua-scripts.yaml` | Filtering logic |
| `05-fluent-bit-config.yaml` | Fluent Bit setup |
| `06-fluent-bit-daemonset.yaml` | Deploy Fluent Bit |
| `07-mock-splunk.yaml` | Test Splunk server |
| `test-applications.yaml` | Test pods |

## 💡 Common Use Cases

### 1. Local Testing
```bash
./scripts/setup-k3d-cluster.sh
./scripts/complete-deployment.sh
./scripts/watch-logs.sh
```

### 2. Understanding the Flow
```bash
# In separate terminals:
kubectl logs -f -n logging -l app=fluent-bit
kubectl logs -f -n splunk-mock -l app=mock-splunk
kubectl logs -f test-app-alpha -n team-alpha
```

### 3. Adding Your Application
```bash
./scripts/setup-namespace.sh my-app-namespace
kubectl create secret generic splunk-config \
  --from-literal=splunk-token='YOUR-TOKEN' \
  --from-literal=splunk-index='your-index' \
  --namespace=my-app-namespace
```

### 4. Production Deployment
1. Read docs/PRODUCTION_CHECKLIST.md
2. Customize manifests for your cluster
3. Update Splunk endpoints
4. Deploy to staging first
5. Gradual production rollout

## ✅ Verification Checklist

After deployment, verify:

- [ ] All pods are running
  ```bash
  kubectl get pods -A
  ```

- [ ] Fluent Bit has no errors
  ```bash
  kubectl logs -n logging -l app=fluent-bit | grep -i error
  ```

- [ ] Mock Splunk is receiving logs
  ```bash
  kubectl logs -n splunk-mock -l app=mock-splunk | grep "Received"
  ```

- [ ] team-alpha logs appear (should ✓)
- [ ] team-beta logs appear (should ✓)
- [ ] team-gamma logs DO NOT appear (should ✗)

## 🎯 Expected Behavior

### What Should Happen

**team-alpha namespace:**
- Has label: `fluent-bit-enabled: true`
- Logs collected ✅
- Sent with token: `ALPHA-TOKEN-12345`
- Sent to index: `team-alpha-logs`

**team-beta namespace:**
- Has label: `fluent-bit-enabled: true`
- Logs collected ✅
- Sent with token: `BETA-TOKEN-67890`
- Sent to index: `team-beta-logs`

**team-gamma namespace:**
- NO label
- Logs filtered out ❌
- Should NOT appear in Mock Splunk

### What You'll See

Mock Splunk logs will show:
```
===============================================
[2024-12-03T...] Received log event
Authorization: Splunk ALPHA-TOKEN-12345
Body: {"timestamp":"...","message":"Log from team-alpha..."}
===============================================
```

## 🔄 Next Steps

1. **Test It**: Run through QUICKSTART.md
2. **Understand It**: Read ARCHITECTURE.md
3. **Customize It**: Modify for your needs
4. **Deploy It**: Follow PRODUCTION_CHECKLIST.md

## 📞 Need Help?

1. **First**: Check docs/TROUBLESHOOTING.md
2. **Then**: Review relevant documentation section
3. **Finally**: Check Fluent Bit logs for errors

## 🎉 You're Ready!

Everything you need is in this package. Start with:

```bash
tar xzf fluent-bit-k3d-test.tar.gz
cd fluent-bit-k3d-test
cat QUICKSTART.md
```

Happy logging! 🚀
