#!/usr/bin/env bash
# Reaches the private Kubernetes API endpoint through a Session Manager port forward on a worker node.
# No public API endpoint, no bastion, no inbound port: the node's agent opens an outbound channel.
# Usage: scripts/k8s_tunnel.sh start|stop
# Requires session-manager-plugin on PATH.
set -euo pipefail

REGION="us-east-1"
CLUSTER="payment-platform-eks"
LOCAL_PORT=8443
PIDFILE="${TMPDIR:-/tmp}/zt-k8s-tunnel.pid"

case "${1:-start}" in
  start)
    endpoint="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.endpoint' --output text)"
    host="${endpoint#https://}"
    node="$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" Name=instance-state-name,Values=running \
      --query 'Reservations[0].Instances[0].InstanceId' --output text)"
    aws ssm start-session --region "$REGION" --target "$node" \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "host=$host,portNumber=443,localPortNumber=$LOCAL_PORT" >/dev/null 2>&1 &
    echo $! >"$PIDFILE"
    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
    ctx="$(kubectl config current-context)"
    cluster_entry="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$ctx')].context.cluster}")"
    kubectl config set-cluster "$cluster_entry" \
      --server "https://127.0.0.1:$LOCAL_PORT" --tls-server-name "$host" >/dev/null
    for _ in $(seq 1 30); do
      if kubectl get --raw /readyz >/dev/null 2>&1; then
        echo "tunnel up through a worker node, kubectl ready"
        exit 0
      fi
      sleep 1
    done
    echo "tunnel did not come up" >&2
    exit 1
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
    rm -f "$PIDFILE"
    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
    echo "tunnel stopped, kubeconfig reset to the cluster endpoint"
    ;;
esac
