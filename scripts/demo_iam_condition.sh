#!/usr/bin/env bash
# IAM context condition: the wallet role can read its table from inside the VPC, and the same
# role's credentials obtained outside the VPC are denied. Credentials are never printed.
# Usage: scripts/demo_iam_condition.sh <NN-name>
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="${1:?usage: demo_iam_condition.sh <NN-name>}"
TABLE="payment-platform-wallets"

{
  echo "== IAM network context condition, $(stamp)"
  echo; echo "-- 1. Allowed: the wallet pod scans its table (request goes through the DynamoDB gateway endpoint)"
  kc -n "$NS" exec deploy/wallet -c wallet -- python3 -c "
import boto3
r = boto3.client('dynamodb', region_name='$REGION').scan(TableName='$TABLE', Limit=1)
print('scan OK, items returned:', r['Count'])
"

  echo; echo "-- 2. Denied: the same role assumed from this machine, outside the VPC"
  role="$(aws iam get-role --role-name payment-platform-wallet-irsa --query Role.Arn --output text)"
  token="$(kc -n "$NS" create token wallet-sa --audience sts.amazonaws.com --duration 10m)"
  creds="$(aws sts assume-role-with-web-identity --region "$REGION" --role-arn "$role" \
    --role-session-name zero-trust-demo --web-identity-token "$token" --query Credentials --output json)"
  echo "assume-role-with-web-identity with a service account token: $( [ -n "$creds" ] && echo succeeded || echo failed)"
  env -u AWS_PROFILE \
    AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId <<<"$creds")" \
    AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey <<<"$creds")" \
    AWS_SESSION_TOKEN="$(jq -r .SessionToken <<<"$creds")" \
    aws dynamodb scan --region "$REGION" --table-name "$TABLE" --limit 1 --query Count --output text 2>&1 | sed 's/^/dynamodb scan: /'
  unset creds token

  echo; echo "-- 3. The deny statement attached to the role"
  aws iam get-role-policy --role-name payment-platform-wallet-irsa --policy-name deny-outside-vpc-endpoints \
    --query PolicyDocument --output json
} 2>&1 | proof "$OUT"
