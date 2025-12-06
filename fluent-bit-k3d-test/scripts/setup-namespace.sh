#!/bin/bash
# setup-namespace.sh
# Configures a namespace for Fluent Bit consumer log routing

set -e

NAMESPACE=$1
SECRET_NAME=${2:-"splunk-token"}

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace> [secret-name]"
    echo ""
    echo "Example:"
    echo "  $0 my-team splunk-token"
    echo ""
    echo "This script will:"
    echo "  1. Create RBAC Role for secret access"
    echo "  2. Create RBAC RoleBinding"
    echo ""
    echo "Note: Consumer routing is based on POD LABELS, not namespace labels."
    echo "After running this script, you must add the following to your pods:"
    echo "  - Label: consumer-splunk-index=<your-index>"
    echo "  - Container name: app"
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

# Create Role
echo ""
echo "1️⃣  Creating RBAC Role..."
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
echo "2️⃣  Creating RBAC RoleBinding..."
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
echo "3️⃣  Checking for Splunk token secret..."
if kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} &> /dev/null; then
    echo "✅ Secret '${SECRET_NAME}' already exists in namespace '${NAMESPACE}'"

    # Show secret contents
    TOKEN=$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.splunk-token}' | base64 -d 2>/dev/null || echo "ERROR")

    echo ""
    echo "   Current configuration:"
    echo "   - Token: ${TOKEN}"
else
    echo "⚠️  Secret '${SECRET_NAME}' does not exist in namespace '${NAMESPACE}'"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📝 Next Steps: Create the Splunk token secret"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Run the following command to create the secret:"
    echo ""
    echo "kubectl create secret generic ${SECRET_NAME} \\"
    echo "  --from-literal=splunk-token='YOUR-SPLUNK-HEC-TOKEN' \\"
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
EOF
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

echo ""
echo "✅ RBAC setup complete for namespace: ${NAMESPACE}"
echo ""
echo "Summary:"
echo "  ✓ RBAC configured (Role + RoleBinding)"
echo "  ✓ Fluent Bit can read secret: ${SECRET_NAME}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 IMPORTANT: To route logs to consumer Splunk endpoint"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Add the following to your pod specifications:"
echo ""
echo "metadata:"
echo "  labels:"
echo "    consumer-splunk-index: \"your-index-name\"  # Your Splunk index"
echo "spec:"
echo "  containers:"
echo "  - name: app  # Must be exactly 'app'"
echo "    image: your-app:latest"
echo ""
echo "Without these labels/container name, logs will route to infrastructure Splunk."
echo ""
