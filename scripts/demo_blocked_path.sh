#!/usr/bin/env bash
# Scenario 2: requests that try to bypass the intended path are blocked by Network Firewall and
# logged with a readable reason. Usage: scripts/demo_blocked_path.sh <NN-name>
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="${1:?usage: demo_blocked_path.sh <NN-name>}"
LB="$(ingress_host)"
ALERT_LOG="/zero-trust/network-firewall/alert"

try_http() { # $1 label, $2 url
  local code
  code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$2")"; local rc=$?
  if [ $rc -eq 0 ]; then echo "$1: HTTP $code"; else echo "$1: no response (curl exit $rc)"; fi
}

{
  echo "== Blocked unauthorized path, $(stamp)"
  start_ms=$(( $(date +%s) * 1000 ))

  echo; echo "-- From the internet (this machine) to the single entry point"
  try_http "1. GET /api/wallets (the intended public API path)" "http://$LB/api/wallets"
  try_http "2. GET /stats (a service endpoint outside the public API path)" "http://$LB/stats"
  try_http "3. GET /healthz/ready on the Istio status port 15021" "http://$LB:15021/healthz/ready"

  echo; echo "-- From inside a workload pod to the internet"
  egress() { # $1 label, $2 url
    kc -n "$NS" exec deploy/wallet -c wallet -- python3 -c "
import urllib.request, sys
try:
    r = urllib.request.urlopen('$2', timeout=8); print('$1: HTTP', r.status)
except urllib.error.HTTPError as e:
    print('$1: HTTP', e.code, '(reached the server)')
except Exception as e:
    print('$1: no connection (' + type(e).__name__ + ')')
"
  }
  egress "4. https://registry-1.docker.io/v2/ (allowlisted registry)" "https://registry-1.docker.io/v2/"
  egress "5. https://example.com/ (not on the allowlist)" "https://example.com/"

  echo; echo "-- Network Firewall alert log for this run (delivery takes a few minutes)"
  for _ in $(seq 1 12); do
    n="$(aws logs filter-log-events --region "$REGION" --log-group-name "$ALERT_LOG" --start-time "$start_ms" \
      --query 'length(events)' --output text 2>/dev/null)"
    [ "${n:-0}" != "0" ] && [ "$n" != "None" ] && break
    sleep 30
  done
  aws logs filter-log-events --region "$REGION" --log-group-name "$ALERT_LOG" --start-time "$start_ms" \
    --query 'events[].message' --output json \
    | jq -r '.[] | fromjson | .event | [.timestamp, .alert.action, .alert.signature, .proto, (.src_ip + " -> " + .dest_ip + ":" + (.dest_port|tostring)), (.tls.sni // .http.url // "")] | @tsv' \
    | sort -u | head -40
} 2>&1 | proof "$OUT"
