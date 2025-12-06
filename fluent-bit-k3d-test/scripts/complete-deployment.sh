#!/bin/bash
# complete-deployment.sh
# Deploys all Fluent Bit components and test applications

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "🚀 Starting Fluent Bit Test Deployment"
echo "======================================"

# Check if cluster exists
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ No Kubernetes cluster found. Run ./scripts/setup-k3d-cluster.sh first"
    exit 1
fi

# Deploy in order
echo ""
echo "1️⃣  Creating Namespaces..."
kubectl apply -f "${PROJECT_ROOT}/manifests/base/01-namespaces.yaml"

echo ""
echo "2️⃣  Deploying Mock Splunk Servers..."
kubectl apply -f "${PROJECT_ROOT}/manifests/base/07-mock-splunk.yaml"
echo "   Waiting for Mock Splunk Consumer to be ready..."
kubectl wait --for=condition=Ready pod -l app=mock-splunk-consumer -n splunk-mock --timeout=120s
echo "   Waiting for Mock Splunk Infrastructure to be ready..."
kubectl wait --for=condition=Ready pod -l app=mock-splunk-infra -n splunk-mock --timeout=120s

echo ""
echo "3️⃣  Deploying RBAC Configuration..."
kubectl apply -f "${PROJECT_ROOT}/manifests/base/02-rbac.yaml"

echo ""
echo "4️⃣  Creating Splunk Configuration Secrets..."
kubectl apply -f "${PROJECT_ROOT}/manifests/base/03-secrets.yaml"

echo ""
echo "5️⃣  Deploying Lua Scripts ConfigMap..."
kubectl apply -f "${PROJECT_ROOT}/manifests/base/04-lua-scripts.yaml"

echo ""
echo "6️⃣  Deploying Fluent Bit Configuration..."
kubectl apply -f "${PROJECT_ROOT}/manifests/base/05-fluent-bit-config.yaml"

echo ""
echo "7️⃣  Deploying Fluent Bit DaemonSet..."
kubectl apply -f "${PROJECT_ROOT}/manifests/base/06-fluent-bit-daemonset.yaml"
echo "   Waiting for Fluent Bit to be ready..."
sleep 10
kubectl wait --for=condition=Ready pod -l app=fluent-bit -n logging --timeout=120s

echo ""
echo "8️⃣  Deploying Test Applications..."
kubectl apply -f "${PROJECT_ROOT}/manifests/test-apps/test-applications.yaml"
echo "   Waiting for test apps to be ready..."
sleep 5
kubectl wait --for=condition=Ready pod test-app-alpha -n team-alpha --timeout=60s || true
kubectl wait --for=condition=Ready pod test-app-beta -n team-beta --timeout=60s || true
kubectl wait --for=condition=Ready pod test-app-gamma -n team-gamma --timeout=60s || true

echo ""
echo "✅ Deployment Complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Deployment Status:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Namespaces:"
kubectl get ns | grep -E 'logging|team-|splunk-mock'
echo ""
echo "Fluent Bit Pods:"
kubectl get pods -n logging
echo ""
echo "Test Application Pods:"
kubectl get pods -n team-alpha,team-beta,team-gamma
echo ""
echo "Mock Splunk:"
kubectl get pods -n splunk-mock
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💡 Next Steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Validate the setup:"
echo "   ./scripts/validate-setup.sh"
echo ""
echo "2. Watch logs in real-time:"
echo "   ./scripts/watch-logs.sh"
echo ""
echo "3. Manual log inspection:"
echo "   # Watch Fluent Bit logs:"
echo "   kubectl logs -f -n logging -l app=fluent-bit"
echo ""
echo "   # Watch Mock Splunk Consumer (consumer-logs):"
echo "   kubectl logs -f -n splunk-mock -l app=mock-splunk-consumer"
echo ""
echo "   # Watch Mock Splunk Infrastructure (tdp-infra):"
echo "   kubectl logs -f -n splunk-mock -l app=mock-splunk-infra"
echo ""
echo "   # Check individual test apps:"
echo "   kubectl logs -f test-app-alpha -n team-alpha"
echo "   kubectl logs -f test-app-beta -n team-beta"
echo "   kubectl logs -f test-app-gamma -n team-gamma"
echo ""
echo "Expected Behavior:"
echo "  ✓ Consumer logs (pods with label 'consumer-splunk-index' + container 'app')"
echo "    → Mock Splunk Consumer"
echo "  ✓ Infrastructure logs (all other logs)"
echo "    → Mock Splunk Infrastructure"
echo ""
