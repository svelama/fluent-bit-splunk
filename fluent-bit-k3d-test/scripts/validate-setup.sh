#!/bin/bash
# validate-setup.sh
# Validates that Fluent Bit setup is working correctly

set -e

echo "🔍 Validating Fluent Bit Setup"
echo "==============================="

ERRORS=0

# Function to check and report
check_resource() {
    local resource=$1
    local namespace=$2
    local name=$3
    
    if [ -z "$namespace" ]; then
        if kubectl get $resource $name &> /dev/null; then
            echo "  ✅ $resource/$name"
        else
            echo "  ❌ $resource/$name NOT FOUND"
            ((ERRORS++))
        fi
    else
        if kubectl get $resource $name -n $namespace &> /dev/null; then
            echo "  ✅ $resource/$name (namespace: $namespace)"
        else
            echo "  ❌ $resource/$name NOT FOUND in namespace $namespace"
            ((ERRORS++))
        fi
    fi
}

# 1. Check Namespaces
echo ""
echo "1️⃣  Checking Namespaces:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━"
check_resource "namespace" "" "logging"
check_resource "namespace" "" "team-alpha"
check_resource "namespace" "" "team-beta"
check_resource "namespace" "" "team-gamma"
check_resource "namespace" "" "splunk-mock"

echo ""
echo "   Namespace Labels:"
kubectl get ns team-alpha,team-beta,team-gamma -o custom-columns=NAME:.metadata.name,LABELS:.metadata.labels --no-headers | sed 's/^/   /'

# 2. Check RBAC
echo ""
echo "2️⃣  Checking RBAC:"
echo "━━━━━━━━━━━━━━━━━━"
check_resource "serviceaccount" "logging" "fluent-bit"
check_resource "clusterrole" "" "fluent-bit-cluster-reader"
check_resource "clusterrolebinding" "" "fluent-bit-cluster-reader"
check_resource "role" "team-alpha" "fluent-bit-secret-reader"
check_resource "rolebinding" "team-alpha" "fluent-bit-secret-reader"
check_resource "role" "team-beta" "fluent-bit-secret-reader"
check_resource "rolebinding" "team-beta" "fluent-bit-secret-reader"

# 3. Check Secrets
echo ""
echo "3️⃣  Checking Secrets:"
echo "━━━━━━━━━━━━━━━━━━━━"
check_resource "secret" "team-alpha" "splunk-token"
check_resource "secret" "team-beta" "splunk-token"

echo ""
echo "   Secret Contents (team-alpha):"
if kubectl get secret splunk-token -n team-alpha &> /dev/null; then
    TOKEN=$(kubectl get secret splunk-token -n team-alpha -o jsonpath='{.data.splunk-token}' | base64 -d)
    echo "     Token: $TOKEN"
    echo "     Note: Index comes from pod label 'consumer-splunk-index'"
fi

echo ""
echo "   Secret Contents (team-beta):"
if kubectl get secret splunk-token -n team-beta &> /dev/null; then
    TOKEN=$(kubectl get secret splunk-token -n team-beta -o jsonpath='{.data.splunk-token}' | base64 -d)
    echo "     Token: $TOKEN"
    echo "     Note: Index comes from pod label 'consumer-splunk-index'"
fi

# 4. Check ConfigMaps
echo ""
echo "4️⃣  Checking ConfigMaps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━"
check_resource "configmap" "logging" "fluent-bit-config"
check_resource "configmap" "logging" "fluent-bit-lua-scripts"

# 5. Check Fluent Bit DaemonSet
echo ""
echo "5️⃣  Checking Fluent Bit DaemonSet:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_resource "daemonset" "logging" "fluent-bit"

DESIRED=$(kubectl get daemonset fluent-bit -n logging -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
READY=$(kubectl get daemonset fluent-bit -n logging -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

echo ""
echo "   DaemonSet Status:"
echo "     Desired: $DESIRED"
echo "     Ready:   $READY"

if [ "$DESIRED" = "$READY" ] && [ "$READY" != "0" ]; then
    echo "  ✅ All Fluent Bit pods are ready"
else
    echo "  ⚠️  Not all Fluent Bit pods are ready"
    ((ERRORS++))
fi

echo ""
echo "   Fluent Bit Pods:"
kubectl get pods -n logging -l app=fluent-bit | sed 's/^/     /'

# 6. Check Test Applications
echo ""
echo "6️⃣  Checking Test Application Pods:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_resource "pod" "team-alpha" "test-app-alpha"
check_resource "pod" "team-beta" "test-app-beta"
check_resource "pod" "team-gamma" "test-app-gamma"

echo ""
echo "   Pod Status:"
kubectl get pods -n team-alpha,team-beta,team-gamma | sed 's/^/     /'

# 7. Check Mock Splunk Servers
echo ""
echo "7️⃣  Checking Mock Splunk Servers:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_resource "deployment" "splunk-mock" "mock-splunk-consumer"
check_resource "service" "splunk-mock" "mock-splunk-consumer"
check_resource "deployment" "splunk-mock" "mock-splunk-infra"
check_resource "service" "splunk-mock" "mock-splunk-infra"

SPLUNK_CONSUMER_READY=$(kubectl get pods -n splunk-mock -l app=mock-splunk-consumer -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
SPLUNK_INFRA_READY=$(kubectl get pods -n splunk-mock -l app=mock-splunk-infra -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [ "$SPLUNK_CONSUMER_READY" = "True" ]; then
    echo "  ✅ Mock Splunk Consumer is ready"
else
    echo "  ⚠️  Mock Splunk Consumer is not ready"
    ((ERRORS++))
fi

if [ "$SPLUNK_INFRA_READY" = "True" ]; then
    echo "  ✅ Mock Splunk Infrastructure is ready"
else
    echo "  ⚠️  Mock Splunk Infrastructure is not ready"
    ((ERRORS++))
fi

# 8. Test Log Flow
echo ""
echo "8️⃣  Testing Log Flow:"
echo "━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "   Checking Fluent Bit logs for errors..."
ERROR_COUNT=$(kubectl logs -n logging -l app=fluent-bit --tail=100 2>/dev/null | grep -i "error\|fail" | wc -l || echo "0")

if [ "$ERROR_COUNT" -gt 5 ]; then
    echo "  ⚠️  Found $ERROR_COUNT error messages in Fluent Bit logs"
    echo "     Review with: kubectl logs -n logging -l app=fluent-bit | grep -i error"
    ((ERRORS++))
else
    echo "  ✅ No significant errors in Fluent Bit logs ($ERROR_COUNT errors)"
fi

echo ""
echo "   Checking if logs are being received by Mock Splunk servers..."
sleep 3
CONSUMER_LOG_COUNT=$(kubectl logs -n splunk-mock -l app=mock-splunk-consumer --tail=50 2>/dev/null | grep "Received log event" | wc -l || echo "0")
INFRA_LOG_COUNT=$(kubectl logs -n splunk-mock -l app=mock-splunk-infra --tail=50 2>/dev/null | grep "Received log event" | wc -l || echo "0")

if [ "$CONSUMER_LOG_COUNT" -gt 0 ]; then
    echo "  ✅ Mock Splunk Consumer has received $CONSUMER_LOG_COUNT log events"
else
    echo "  ⚠️  Mock Splunk Consumer has not received any logs yet"
    echo "     This might be normal if just deployed or no consumer pods are running."
fi

if [ "$INFRA_LOG_COUNT" -gt 0 ]; then
    echo "  ✅ Mock Splunk Infrastructure has received $INFRA_LOG_COUNT log events"
else
    echo "  ⚠️  Mock Splunk Infrastructure has not received any logs yet"
    echo "     This might be normal if just deployed. Wait a minute and check again."
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Validation Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ All checks passed! Setup is working correctly."
    echo ""
    echo "💡 Next Steps:"
    echo "   1. Watch logs in real-time: ./scripts/watch-logs.sh"
    echo "   2. Check Mock Splunk Consumer: kubectl logs -f -n splunk-mock -l app=mock-splunk-consumer"
    echo "   3. Check Mock Splunk Infrastructure: kubectl logs -f -n splunk-mock -l app=mock-splunk-infra"
    echo "   4. Verify consumer logs (pods with label 'consumer-splunk-index' + container 'app')"
    echo "      appear in Mock Splunk Consumer"
    echo "   5. Verify infrastructure logs (all other logs) appear in Mock Splunk Infrastructure"
else
    echo "❌ Found $ERRORS issues. Please review the output above."
    echo ""
    echo "💡 Troubleshooting:"
    echo "   1. Check Fluent Bit logs: kubectl logs -n logging -l app=fluent-bit"
    echo "   2. Check pod status: kubectl get pods -A"
    echo "   3. Review TROUBLESHOOTING.md for common issues"
    exit 1
fi
