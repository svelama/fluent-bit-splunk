#!/bin/bash
# setup-namespace.sh
# Adds a new namespace to Fluent Bit log collection

set -e

NAMESPACE=$1
SECRET_NAME=${2:-"splunk-config"}

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace> [secret-name]"
    echo ""
    echo "Example:"
    echo "  $0 my-team splunk-config"
    echo ""
    echo "This script will:"
    echo "  1. Label the namespace for Fluent Bit collection"
    echo "  2. Create RBAC Role for secret access"
    echo "  3. Create RBAC RoleBinding"
    echo ""
    exit 1
fi

echo "🔧 Setting up Fluent Bit for namespace: ${NAMESPACE}"
echo "=================================================="

# Check if namespace exists
if ! kubectl get namespace ${NAMESPACE} &> /dev/null; then
    echo ""
    read -p "Namespace '${NAMESPACE}' does not exist. Create it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl create namespace ${NAMESPACE}
        echo "✅ Namespace created"
    else
        echo "❌ Namespace does not exist. Exiting."
        exit 1
    fi
fi

# Label the namespace
echo ""
echo "1️⃣  Labeling namespace for log collection..."
kubectl label namespace ${NAMESPACE} fluent-bit-enabled=true --overwrite
echo "✅ Namespace labeled: fluent-bit-enabled=true"

# Create Role
echo ""
echo "2️⃣  Creating RBAC Role..."
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: fluent-bit-secret-reader
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["${SECRET_NAME}"]
  verbs: ["get"]
EOF
echo "✅ Role created"

# Create RoleBinding
echo ""
echo "3️⃣  Creating RBAC RoleBinding..."
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: fluent-bit-secret-reader
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: fluent-bit-secret-reader
subjects:
- kind: ServiceAccount
  name: fluent-bit
  namespace: logging
EOF
echo "✅ RoleBinding created"

# Check if secret exists
echo ""
echo "4️⃣  Checking for Splunk configuration secret..."
if kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} &> /dev/null; then
    echo "✅ Secret '${SECRET_NAME}' already exists in namespace '${NAMESPACE}'"
    
    # Show secret contents
    TOKEN=$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.splunk-token}' | base64 -d 2>/dev/null || echo "ERROR")
    INDEX=$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.splunk-index}' | base64 -d 2>/dev/null || echo "ERROR")
    
    echo ""
    echo "   Current configuration:"
    echo "   - Token: ${TOKEN}"
    echo "   - Index: ${INDEX}"
else
    echo "⚠️  Secret '${SECRET_NAME}' does not exist in namespace '${NAMESPACE}'"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📝 Next Steps: Create the Splunk configuration secret"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Run the following command to create the secret:"
    echo ""
    echo "kubectl create secret generic ${SECRET_NAME} \\"
    echo "  --from-literal=splunk-token='YOUR-SPLUNK-HEC-TOKEN' \\"
    echo "  --from-literal=splunk-index='your-index-name' \\"
    echo "  --namespace=${NAMESPACE}"
    echo ""
    echo "Or apply this YAML:"
    echo ""
    cat <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  splunk-token: "YOUR-SPLUNK-HEC-TOKEN"
  splunk-index: "your-index-name"
EOF
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

echo ""
echo "✅ Fluent Bit setup complete for namespace: ${NAMESPACE}"
echo ""
echo "Summary:"
echo "  ✓ Namespace labeled for log collection"
echo "  ✓ RBAC configured (Role + RoleBinding)"
echo "  ✓ Secret access granted to: ${SECRET_NAME}"
echo ""
echo "Logs from pods in namespace '${NAMESPACE}' will now be collected"
echo "and sent to Splunk using the configuration from secret '${SECRET_NAME}'."
