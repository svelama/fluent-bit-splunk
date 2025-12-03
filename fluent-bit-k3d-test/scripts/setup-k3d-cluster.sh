#!/bin/bash
# setup-k3d-cluster.sh
# Creates a k3d cluster for testing Fluent Bit

set -e

CLUSTER_NAME="fluent-bit-test"
AGENTS=2

echo "================================================"
echo "Setting up k3d cluster: ${CLUSTER_NAME}"
echo "================================================"

# Check if k3d is installed
if ! command -v k3d &> /dev/null; then
    echo "❌ k3d is not installed. Installing..."
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

# Check if cluster already exists
if k3d cluster list | grep -q "${CLUSTER_NAME}"; then
    echo "⚠️  Cluster ${CLUSTER_NAME} already exists."
    read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🗑️  Deleting existing cluster..."
        k3d cluster delete ${CLUSTER_NAME}
    else
        echo "Using existing cluster."
        exit 0
    fi
fi

# Create k3d cluster
echo "🚀 Creating k3d cluster..."
k3d cluster create ${CLUSTER_NAME} \
  --agents ${AGENTS} \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

# Wait for cluster to be ready
echo "⏳ Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s

# Display cluster info
echo ""
echo "✅ k3d cluster created successfully!"
echo ""
echo "📊 Cluster Information:"
echo "----------------------"
kubectl cluster-info
echo ""
kubectl get nodes
echo ""
echo "💡 Next Steps:"
echo "  1. Run: ./scripts/complete-deployment.sh"
echo "  2. Run: ./scripts/validate-setup.sh"
echo "  3. Run: ./scripts/watch-logs.sh"
