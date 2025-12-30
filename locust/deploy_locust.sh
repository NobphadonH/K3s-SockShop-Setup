#!/bin/bash
NAMESPACE="locust"
NODE_PORT=30089

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
kubectl label ns "$NAMESPACE" istio-injection=enabled --overwrite

# echo "Waiting for all pods in sock-shop to be ready..."

# # Wait for pods with the 'app' label to be ready
# kubectl wait --for=condition=Ready pod --all -n sock-shop --timeout=600s

# Create/update ConfigMap from repo file
kubectl -n "$NAMESPACE" create configmap locustfile-config \
  --from-file=locustfile.py=./locust/locustfile.py \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply Deployment + NodePort Service
kubectl apply -f ./locust/locust-nodeport.yaml

kubectl -n "$NAMESPACE" rollout status deploy/locust --timeout=300s
kubectl -n "$NAMESPACE" get svc locust-ui -o wide

echo ""
echo "Locust UI: http://<EC2_PUBLIC_IP>:$NODEPORT"