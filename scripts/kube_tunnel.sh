#!/usr/bin/env bash
# kubectl access to the private EKS API through a Session Manager port-forwarding session to a
# worker node. Nothing listens on the internet and no inbound rule is added anywhere.
# Usage: scripts/kube_tunnel.sh start | stop
# After start: export ZT_TUNNEL=1 KUBECONFIG=$HOME/.kube/zero-trust-tunnel
set -euo pipefail
source "$(dirname "$0")/lib.sh"
LOCAL_PORT=8443
PIDFILE="$HOME/.kube/zero-trust-tunnel.pid"

case "${1:-}" in
  start)
    endpoint="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query cluster.endpoint --output text)"
    host="${endpoint#https://}"
    node="$(first_node)"
    nohup aws ssm start-session --region "$REGION" --target "$node" \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "host=$host,portNumber=443,localPortNumber=$LOCAL_PORT" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$TUNNEL_KUBECONFIG" >/dev/null
    name="$(kubectl --kubeconfig "$TUNNEL_KUBECONFIG" config view -o jsonpath='{.clusters[0].name}')"
    kubectl --kubeconfig "$TUNNEL_KUBECONFIG" config set-cluster "$name" \
      --server="https://127.0.0.1:$LOCAL_PORT" --tls-server-name="$host" >/dev/null
    for _ in $(seq 1 30); do
      (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null && { echo "tunnel open on 127.0.0.1:$LOCAL_PORT"; exit 0; }
      sleep 1
    done
    echo "tunnel did not open within 30s" >&2; exit 1 ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"; echo "tunnel closed" ;;
  *) echo "usage: kube_tunnel.sh start|stop" >&2; exit 2 ;;
esac
