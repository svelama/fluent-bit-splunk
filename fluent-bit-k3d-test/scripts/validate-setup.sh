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
check_resource "secret" "team-alpha" "splunk-config"
check_resource "secret" "team-beta" "splunk-config"

echo ""
echo "   Secret Contents (team-alpha):"
if kubectl get secret splunk-config -n team-alpha &> /dev/null; then
    TOKEN=$(kubectl get secret splunk-config -n team-alpha -o jsonpath='{.data.splunk-token}' | base64 -d)
    INDEX=$(kubectl get secret splunk-config -n team-alpha -o jsonpath='{.data.splunk-index}' | base64 -d)
    echo "     Token: $TOKEN"
    echo "     Index: $INDEX"
fi

echo ""
echo "   Secret Contents (team-beta):"
if kubectl get secret splunk-config -n team-beta &> /dev/null; then
    TOKEN=$(kubectl get secret splunk-config -n team-beta -o jsonpath='{.data.splunk-token}' | base64 -d)
    INDEX=$(kubectl get secret splunk-config -n team-beta -o jsonpath='{.data.splunk-index}' | base64 -d)
    echo "     Token: $TOKEN"
    echo "     Index: $INDEX"
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

# 7. Check Mock Splunk
echo ""
echo "7️⃣  Checking Mock Splunk:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━"
check_resource "deployment" "splunk-mock" "mock-splunk"
check_resource "service" "splunk-mock" "mock-splunk"

SPLUNK_READY=$(kubectl get pods -n splunk-mock -l app=mock-splunk -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [ "$SPLUNK_READY" = "True" ]; then
    echo "  ✅ Mock Splunk is ready"
else
    echo "  ⚠️  Mock Splunk is not ready"
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
echo "   Checking if logs are being received by Mock Splunk..."
sleep 3
LOG_COUNT=$(kubectl logs -n splunk-mock -l app=mock-splunk --tail=50 2>/dev/null | grep "Received log event" | wc -l || echo "0")

if [ "$LOG_COUNT" -gt 0 ]; then
    echo "  ✅ Mock Splunk has received $LOG_COUNT log events"
else
    echo "  ⚠️  Mock Splunk has not received any logs yet"
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
    echo "   2. Check Mock Splunk: kubectl logs -f -n splunk-mock -l app=mock-splunk"
    echo "   3. Verify team-alpha logs appear with ALPHA-TOKEN-12345"
    echo "   4. Verify team-beta logs appear with BETA-TOKEN-67890"
    echo "   5. Verify team-gamma logs do NOT appear (namespace not labeled)"
else
    echo "❌ Found $ERRORS issues. Please review the output above."
    echo ""
    echo "💡 Troubleshooting:"
    echo "   1. Check Fluent Bit logs: kubectl logs -n logging -l app=fluent-bit"
    echo "   2. Check pod status: kubectl get pods -A"
    echo "   3. Review TROUBLESHOOTING.md for common issues"
    exit 1
fi
