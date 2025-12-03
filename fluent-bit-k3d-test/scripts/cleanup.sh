#!/bin/bash
# cleanup.sh
# Removes all resources and k3d cluster

CLUSTER_NAME="fluent-bit-test"

echo "🗑️  Cleanup Script"
echo "=================="
echo ""
echo "This will delete:"
echo "  - k3d cluster: ${CLUSTER_NAME}"
echo "  - All deployed resources"
echo ""

read -p "Are you sure you want to continue? (y/N): " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Starting cleanup..."
echo ""

# Delete k3d cluster
if k3d cluster list | grep -q "${CLUSTER_NAME}"; then
    echo "1️⃣  Deleting k3d cluster: ${CLUSTER_NAME}..."
    k3d cluster delete ${CLUSTER_NAME}
    echo "✅ Cluster deleted"
else
    echo "⚠️  Cluster ${CLUSTER_NAME} not found"
fi

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "To recreate the environment:"
echo "  1. ./scripts/setup-k3d-cluster.sh"
echo "  2. ./scripts/complete-deployment.sh"
