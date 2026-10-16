# Shared settings for the demo scripts. Sourced, not executed.
REGION="us-east-1"
CLUSTER="payment-platform-eks"
NS="payment-app"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUNNEL_KUBECONFIG="$HOME/.kube/zero-trust-tunnel"

# kubectl goes through the Session Manager tunnel when it is open, else the default kubeconfig.
kc() {
  if [ -f "$TUNNEL_KUBECONFIG" ] && [ -n "${ZT_TUNNEL:-}" ]; then
    kubectl --kubeconfig "$TUNNEL_KUBECONFIG" "$@"
  else
    kubectl "$@"
  fi
}

ingress_host() {
  kc -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
}

first_node() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

stamp() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }

# Every proof file goes through the masking filter before it is written.
proof() { python3 "$ROOT/scripts/mask.py" | tee "$ROOT/proof/$1.txt"; }
