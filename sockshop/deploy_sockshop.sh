#!/bin/bash

NAMESPACE="sock-shop"

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
kubectl label ns "$NAMESPACE" istio-injection=enabled --overwrite

kubectl apply -n sock-shop -f https://raw.githubusercontent.com/microservices-demo/microservices-demo/master/deploy/kubernetes/complete-demo.yaml

# Wait for session-db and patch the read-only filesystem bug
until kubectl -n sock-shop get deploy session-db >/dev/null 2>&1; do
  sleep 1
done
kubectl patch deployment session-db -n sock-shop -p '{"spec":{"template":{"spec":{"volumes":[{"name":"data-dir","emptyDir":{}}],"containers":[{"name":"session-db","volumeMounts":[{"name":"data-dir","mountPath":"/data"}]}]}}}}'

until kubectl -n sock-shop get deploy carts-db >/dev/null 2>&1; do
  sleep 1
done

kubectl -n sock-shop set image deploy/carts-db carts-db=mongo:4.4

until kubectl -n sock-shop get deploy orders-db >/dev/null 2>&1; do
  sleep 1
done

kubectl -n sock-shop set image deploy/orders-db orders-db=mongo:4.4

echo "Waiting for terminating pods to disappear..."
while kubectl -n sock-shop get pods 2>/dev/null | grep -q Terminating; do
  sleep 2
done
