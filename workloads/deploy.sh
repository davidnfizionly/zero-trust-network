#!/usr/bin/env bash
# Builds, pushes and deploys the five payment services onto the cluster created by infra/baseline.
# Usage: workloads/deploy.sh [--skip-build]
# Account-specific values (ECR URLs, IRSA role ARNs, queue URLs) are read from Terraform outputs,
# never stored in the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="us-east-1"
NS="payment-app"
SERVICES=(wallet transaction fraud-detection notification reconciliation)
CLUSTER_DIR="$ROOT/infra/baseline/cluster"
DATA_DIR="$ROOT/infra/baseline/data"

ecr_json="$(terraform -chdir="$CLUSTER_DIR" output -json ecr_repository_urls)"
irsa_json="$(terraform -chdir="$CLUSTER_DIR" output -json irsa_role_arns)"
cluster="$(terraform -chdir="$CLUSTER_DIR" output -raw cluster_name)"
notification_queue="$(terraform -chdir="$DATA_DIR" output -raw notification_queue_url)"
reconciliation_queue="$(terraform -chdir="$DATA_DIR" output -raw reconciliation_queue_url)"
# After the zero trust retrofit, DynamoDB Streams is reached through its interface endpoint,
# which has no private DNS name, so the endpoint URL is passed to the fraud detection service.
streams_url="$(terraform -chdir="$ROOT/infra/zerotrust" output -raw dynamodb_streams_endpoint_url 2>/dev/null || true)"

aws eks update-kubeconfig --region "$REGION" --name "$cluster" >/dev/null

if [ "${1:-}" != "--skip-build" ]; then
  registry="$(jq -r '.wallet' <<<"$ecr_json" | cut -d/ -f1)"
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$registry" >/dev/null
  for svc in "${SERVICES[@]}"; do
    repo="$(jq -r --arg s "$svc" '.[$s]' <<<"$ecr_json")"
    docker build --platform linux/amd64 -t "$repo:latest" "$ROOT/workloads/services/$svc"
    docker push "$repo:latest"
  done
fi

istioctl install -f "$ROOT/workloads/istio/operator.yaml" -y
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" istio-injection=enabled --overwrite

for svc in "${SERVICES[@]}"; do
  extra=()
  case "$svc" in
    notification)   extra=(--set "env[1].value=$notification_queue") ;;
    reconciliation) extra=(--set "env[2].value=$reconciliation_queue") ;;
    fraud-detection)
      if [[ "$streams_url" == https://* ]]; then
        extra=(--set "extraEnv[0].name=AWS_ENDPOINT_URL_DYNAMODB_STREAMS" --set "extraEnv[0].value=$streams_url")
      fi ;;
  esac
  helm upgrade --install "$svc" "$ROOT/workloads/helm/microservice" -n "$NS" \
    -f "$ROOT/workloads/helm/values/values-$svc.yaml" \
    --set "image.repository=$(jq -r --arg s "$svc" '.[$s]' <<<"$ecr_json")" \
    --set "serviceAccount.irsaRoleArn=$(jq -r --arg s "$svc" '.[$s]' <<<"$irsa_json")" \
    "${extra[@]}"
done

kubectl apply -f "$ROOT/workloads/istio/gateway.yaml"
kubectl -n "$NS" rollout status deployment --timeout=300s
kubectl -n istio-system get svc istio-ingressgateway
