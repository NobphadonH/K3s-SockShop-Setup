#!/bin/bash

NAMESPACE="sock-shop"

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
kubectl label ns "$NAMESPACE" istio-injection=enabled --overwrite

kubectl apply -n sock-shop -f https://raw.githubusercontent.com/microservices-demo/microservices-demo/master/deploy/kubernetes/complete-demo.yaml

until kubectl -n sock-shop get deploy carts-db >/dev/null 2>&1; do
  sleep 1
done

kubectl -n sock-shop set image deploy/carts-db carts-db=mongo:4.4

until kubectl -n sock-shop get deploy orders-db >/dev/null 2>&1; do
  sleep 1
done

kubectl -n sock-shop set image deploy/orders-db orders-db=mongo:4.4