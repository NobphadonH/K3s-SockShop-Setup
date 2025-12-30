#!/bin/bash

NAMESPACE="sock-shop"

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
kubectl label ns "$NAMESPACE" istio-injection=enabled --overwrite

kubectl apply -n sock-shop -f https://raw.githubusercontent.com/microservices-demo/microservices-demo/master/deploy/kubernetes/complete-demo.yaml
