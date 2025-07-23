#!/bin/bash

# Ethereum Pod Troubleshooting Script
# This script helps diagnose and fix the lighthouse pod scheduling issue

echo "=== Ethereum Pod Troubleshooting ==="
echo "Timestamp: $(date)"
echo

# Check if kubectl is configured
echo "1. Checking kubectl configuration..."
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ kubectl is not configured or cluster is not accessible"
    echo "Please configure kubectl with: gcloud container clusters get-credentials <cluster-name> --zone <zone>"
    exit 1
fi
echo "✅ kubectl is configured"
echo

# Check namespace
echo "2. Checking ethereum namespace..."
if ! kubectl get namespace ethereum &> /dev/null; then
    echo "❌ ethereum namespace does not exist. Creating it..."
    kubectl create namespace ethereum
else
    echo "✅ ethereum namespace exists"
fi
echo

# Check storage classes
echo "3. Checking available storage classes..."
echo "Available storage classes:"
kubectl get storageclass
echo

# Get the default storage class
DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
if [ -n "$DEFAULT_SC" ]; then
    echo "Default storage class: $DEFAULT_SC"
else
    echo "⚠️  No default storage class found"
fi
echo

# Check PVC status
echo "4. Checking PVC status..."
kubectl get pvc -n ethereum
echo

# Check for pending PVCs
PENDING_PVCS=$(kubectl get pvc -n ethereum --no-headers | grep Pending | wc -l)
if [ $PENDING_PVCS -gt 0 ]; then
    echo "❌ Found $PENDING_PVCS pending PVC(s)"
    echo "Describing pending PVCs:"
    kubectl get pvc -n ethereum --no-headers | grep Pending | while read line; do
        PVC_NAME=$(echo $line | awk '{print $1}')
        echo "--- PVC: $PVC_NAME ---"
        kubectl describe pvc $PVC_NAME -n ethereum
        echo
    done
else
    echo "✅ All PVCs are bound"
fi
echo

# Check node resources
echo "5. Checking node resources..."
echo "Node resource usage:"
kubectl top nodes 2>/dev/null || echo "Metrics server not available"
kubectl get nodes -o wide
echo

# Check pod status
echo "6. Checking pod status..."
kubectl get pods -n ethereum -o wide
echo

# Check pending pods
PENDING_PODS=$(kubectl get pods -n ethereum --no-headers | grep Pending | wc -l)
if [ $PENDING_PODS -gt 0 ]; then
    echo "❌ Found $PENDING_PODS pending pod(s)"
    echo "Describing pending pods:"
    kubectl get pods -n ethereum --no-headers | grep Pending | while read line; do
        POD_NAME=$(echo $line | awk '{print $1}')
        echo "--- Pod: $POD_NAME ---"
        kubectl describe pod $POD_NAME -n ethereum
        echo
    done
fi
echo

# Provide recommendations
echo "=== RECOMMENDATIONS ==="
echo

if [ $PENDING_PVCS -gt 0 ]; then
    echo "🔧 PVC Issues:"
    echo "   - Check if the storage class 'standard' exists in your cluster"
    echo "   - Try using 'standard-rwo' instead (common in GKE)"
    echo "   - Consider using the default storage class: $DEFAULT_SC"
    echo "   - For GKE, try: gp2, gp3, ssd, or fast-ssd"
    echo
fi

if [ $PENDING_PODS -gt 0 ]; then
    echo "🔧 Pod Scheduling Issues:"
    echo "   - Reduce resource requests if nodes have insufficient memory"
    echo "   - Add node affinity to prefer larger instance types"
    echo "   - Consider enabling cluster autoscaler"
    echo "   - Check if PVCs are bound before pods can be scheduled"
    echo
fi

echo "🔧 Quick fixes to try:"
echo "1. Delete existing PVCs and recreate with correct storage class:"
echo "   kubectl delete pvc lighthouse-data-pvc geth-data-pvc -n ethereum"
echo "   kubectl apply -f ethereum-fixed.yaml"
echo
echo "2. Scale down lighthouse temporarily if geth needs to sync first:"
echo "   kubectl scale deployment lighthouse --replicas=0 -n ethereum"
echo "   # Wait for geth to sync, then scale back up"
echo "   kubectl scale deployment lighthouse --replicas=1 -n ethereum"
echo
echo "3. Use the fixed YAML with correct storage class:"
echo "   kubectl apply -f ethereum-fixed.yaml"
echo

# Check for common GKE issues
if kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' | grep -q "cloud.google.com"; then
    echo "🔧 GKE-specific recommendations:"
    echo "   - Ensure nodes are in the same zone as persistent disks"
    echo "   - Consider using regional persistent disks for multi-zone clusters"
    echo "   - Check GKE cluster autoscaler settings"
    echo "   - Verify node pool instance types have sufficient resources"
    echo
fi

echo "=== NEXT STEPS ==="
echo "1. Apply the fixed configuration: kubectl apply -f ethereum-fixed.yaml"
echo "2. Monitor pod status: watch kubectl get pods -n ethereum"
echo "3. Check logs once pods are running: kubectl logs -f deployment/lighthouse -n ethereum"
echo