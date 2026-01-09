kubectl --kubeconfig ~/k3s.yaml run -n locust locust-trigger --rm -i --restart=Never \
  --image=curlimages/curl:8.5.0 -- \
  curl -X POST "http://locust-ui.sock-shop.svc.cluster.local:8089/swarm" \
  -d "user_count=50" \
  -d "spawn_rate=5"