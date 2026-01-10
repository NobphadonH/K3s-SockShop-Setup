kubectl --kubeconfig ~/k3s.yaml run -n locust locust-trigger \
  --rm -i --restart=Never \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --image=curlimages/curl:8.5.0 -- \
  curl -sS -X POST "http://locust-ui:8089/swarm" \
  -d "user_count=50" \
  -d "spawn_rate=5"