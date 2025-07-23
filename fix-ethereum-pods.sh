#!/bin/bash

# Quick fix script for Ethereum pod scheduling issues
# Based on the error analysis: unbound PVCs and insufficient memory

echo "🔧 Fixing Ethereum pod scheduling issues..."
echo

# Step 1: Check current storage classes
echo "Step 1: Checking available storage classes..."
kubectl get storageclass

# Get the default or most suitable storage class
SUITABLE_SC=""
for sc in "standard-rwo" "gp2" "gp3" "ssd" "fast-ssd" "standard"; do
    if kubectl get storageclass "$sc" &>/dev/null; then
        SUITABLE_SC="$sc"
        echo "✅ Found suitable storage class: $sc"
        break
    fi
done

if [ -z "$SUITABLE_SC" ]; then
    # Use the default storage class
    SUITABLE_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
    if [ -z "$SUITABLE_SC" ]; then
        echo "❌ No suitable storage class found. Using 'standard'"
        SUITABLE_SC="standard"
    fi
fi

echo "Using storage class: $SUITABLE_SC"
echo

# Step 2: Delete existing problematic resources
echo "Step 2: Cleaning up existing resources..."
kubectl delete deployment lighthouse -n ethereum --ignore-not-found=true
kubectl delete pvc lighthouse-data-pvc -n ethereum --ignore-not-found=true
kubectl delete pvc geth-data-pvc -n ethereum --ignore-not-found=true
echo "✅ Cleaned up existing resources"
echo

# Step 3: Create updated YAML with correct storage class
echo "Step 3: Creating updated YAML configuration..."
cat > ethereum-quick-fix.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: jwt-secret
  namespace: ethereum
data:
  secret: "aced7325ad6f01b0f5a405ac1b04f9fbd768e9d382e953c5bb25487dd874f443"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: geth-data-pvc
  namespace: ethereum
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: $SUITABLE_SC
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lighthouse-data-pvc
  namespace: ethereum
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: $SUITABLE_SC
---
apiVersion: v1
kind: Service
metadata:
  name: geth
  namespace: ethereum
spec:
  selector:
    app: geth
  ports:
  - name: http-rpc
    port: 8545
  - name: auth-rpc
    port: 8551
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: geth
  namespace: ethereum
spec:
  replicas: 1
  selector:
    matchLabels:
      app: geth
  template:
    metadata:
      labels:
        app: geth
    spec:
      enableServiceLinks: false
      containers:
      - name: geth
        image: ethereum/client-go:latest
        ports:
        - containerPort: 8545
        - containerPort: 8551
        volumeMounts:
        - name: geth-data
          mountPath: /root/.ethereum
        - name: jwt-secret
          mountPath: /root/jwt
          readOnly: true
        command:
        - geth
        args:
        - --sepolia
        - --syncmode=snap
        - --http
        - --http.addr=0.0.0.0
        - --http.api=eth,net,web3
        - --authrpc.addr=0.0.0.0
        - --authrpc.port=8551
        - --authrpc.vhosts=*
        - --authrpc.jwtsecret=/root/jwt/secret
        resources:
          requests:
            memory: "3Gi"
            cpu: "500m"
          limits:
            memory: "6Gi"
            cpu: "1500m"
      volumes:
      - name: geth-data
        persistentVolumeClaim:
          claimName: geth-data-pvc
      - name: jwt-secret
        configMap:
          name: jwt-secret
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lighthouse
  namespace: ethereum
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lighthouse
  template:
    metadata:
      labels:
        app: lighthouse
    spec:
      enableServiceLinks: false
      containers:
      - name: lighthouse
        image: sigp/lighthouse:latest
        ports:
        - containerPort: 9000
        - containerPort: 5052
        volumeMounts:
        - name: lighthouse-data
          mountPath: /root/.lighthouse
        - name: jwt-secret
          mountPath: /root/jwt
          readOnly: true
        command:
        - lighthouse
        args:
        - bn
        - --network=sepolia
        - --execution-endpoint=http://geth:8551
        - --execution-jwt=/root/jwt/secret
        - --checkpoint-sync-url=https://sepolia.beaconstate.info
        - --http
        resources:
          requests:
            memory: "1Gi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "500m"
      volumes:
      - name: lighthouse-data
        persistentVolumeClaim:
          claimName: lighthouse-data-pvc
      - name: jwt-secret
        configMap:
          name: jwt-secret
      # Add tolerations to help with scheduling
      tolerations:
      - key: "node.kubernetes.io/not-ready"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 300
EOF

echo "✅ Created ethereum-quick-fix.yaml"
echo

# Step 4: Apply the configuration
echo "Step 4: Applying the fixed configuration..."
kubectl apply -f ethereum-quick-fix.yaml
echo "✅ Applied configuration"
echo

# Step 5: Wait for PVCs to bind
echo "Step 5: Waiting for PVCs to bind..."
echo "Waiting for geth-data-pvc..."
kubectl wait --for=condition=bound pvc/geth-data-pvc -n ethereum --timeout=300s
echo "Waiting for lighthouse-data-pvc..."
kubectl wait --for=condition=bound pvc/lighthouse-data-pvc -n ethereum --timeout=300s
echo "✅ PVCs are bound"
echo

# Step 6: Monitor pod status
echo "Step 6: Monitoring pod deployment..."
echo "Waiting for geth pod to be ready..."
kubectl wait --for=condition=ready pod -l app=geth -n ethereum --timeout=600s

echo "Current pod status:"
kubectl get pods -n ethereum
echo

echo "🎉 Fix completed! Here's what was changed:"
echo "   - Updated storage class to: $SUITABLE_SC"
echo "   - Reduced lighthouse memory requirements: 1Gi request, 2Gi limit"
echo "   - Reduced lighthouse storage: 50Gi instead of 100Gi"
echo "   - Added tolerations for better scheduling"
echo "   - Simplified configuration to reduce complexity"
echo
echo "Next steps:"
echo "1. Monitor pods: kubectl get pods -n ethereum -w"
echo "2. Check logs: kubectl logs -f deployment/geth -n ethereum"
echo "3. Once geth is syncing, lighthouse should start automatically"
echo