#!/usr/bin/env bash
# Scenario 4: a transfer is sent through the public API, and VPC Flow Logs show the wallet and
# transaction pods reaching DynamoDB through the gateway endpoint (traffic-path 7), never through
# the internet gateway (traffic-path 8). Usage: scripts/demo_dynamodb_private_path.sh <NN-name>
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="${1:?usage: demo_dynamodb_private_path.sh <NN-name>}"
LOG_GROUP="/zero-trust/vpc-flow-logs"
LB="$(ingress_host)"

{
  echo "== Private path to DynamoDB, $(stamp)"
  pods="$(kc -n "$NS" get pods -l 'app in (wallet,transaction)' -o jsonpath='{range .items[*]}{.metadata.labels.app} pod={.status.podIP} node={.status.hostIP}{"\n"}{end}')"
  echo; echo "-- Pods that call DynamoDB, and the node each runs on"; echo "$pods"
  echo "(The VPC CNI translates pod traffic leaving the VPC CIDR to the node's primary address, so the"
  echo " flow log records for DynamoDB carry the node address as packet source.)"
  ips="$(echo "$pods" | sed -E 's/.*node=//' | sort -u | paste -sd' ')"

  start=$(date +%s)
  echo; echo "-- Transfer sent through the public API"
  for i in 1 2 3; do
    curl -s -m 10 -o /dev/null -w "POST /api/transfers: HTTP %{http_code}\n" -X POST "http://$LB/api/transfers" \
      -H 'Content-Type: application/json' \
      -d "{\"idempotency_key\":\"flowlog-$start-$i\",\"from_wallet\":\"alice\",\"to_wallet\":\"bob\",\"amount\":1,\"location\":\"Nairobi\"}"
  done

  filter=""
  for ip in $ips; do filter="${filter:+$filter or }pkt_src = \"$ip\""; done
  # Field names are prefixed: CloudWatch already defines some flow log fields (bytes, start, ...).
  query="parse @message \"* * * * * * * * * * * * * * * * * * *\" as f_version, f_eni, f_srcaddr, f_dstaddr, f_srcport, f_dstport, f_protocol, f_packets, f_bytes, f_start, f_end, f_action, f_status, f_subnet, pkt_src, pkt_dst, aws_service, direction, traffic_path
| filter ($filter) and direction = \"egress\" and f_dstport = \"443\" and f_start >= $start
| stats count(*) as flows, sum(f_bytes) as bytes by pkt_src, aws_service, traffic_path"

  echo; echo "-- Waiting for flow log delivery (typically about 5 minutes)"
  for _ in $(seq 1 16); do
    sleep 60
    qid="$(aws logs start-query --region "$REGION" --log-group-name "$LOG_GROUP" \
      --start-time "$start" --end-time "$(( $(date +%s) + 60 ))" --query-string "$query" --query queryId --output text)"
    [ -n "$qid" ] || { echo "query rejected, stopping"; break; }
    sleep 5
    res="$(aws logs get-query-results --region "$REGION" --query-id "$qid" --output json)"
    echo "$res" | jq -e '.results | map(select(any(.[]; .field=="aws_service" and .value=="DYNAMODB"))) | length > 0' >/dev/null && break
  done
  echo; echo "-- Egress flows on TCP 443 from those pods since the transfer (traffic_path 7 = gateway VPC endpoint, 8 = internet gateway; aws_service "-" = destination outside the AWS public ranges)"
  echo "$res" | jq -r '["packet_source","aws_service","traffic_path","flows","bytes"], (.results[] | [ (.[] | select(.field=="pkt_src").value), (.[] | select(.field=="aws_service").value), (.[] | select(.field=="traffic_path").value), (.[] | select(.field=="flows").value), (.[] | select(.field=="bytes").value) ]) | @tsv'

  echo; echo "-- DynamoDB gateway endpoint and the route it adds to the private route table"
  aws ec2 describe-vpc-endpoints --region "$REGION" --filters Name=service-name,Values="com.amazonaws.$REGION.dynamodb" \
    --query 'VpcEndpoints[].[VpcEndpointId,VpcEndpointType,State]' --output text
  aws ec2 describe-route-tables --region "$REGION" --filters "Name=tag:Name,Values=payment-platform-vpc-private" \
    --query 'RouteTables[0].Routes[].[DestinationCidrBlock||DestinationPrefixListId,GatewayId||NatGatewayId||VpcEndpointId]' --output text
} 2>&1 | proof "$OUT"
