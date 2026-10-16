#!/usr/bin/env bash
# Scenario 3: a recorded shell session on a worker node with no SSH and no inbound rule from
# outside the VPC. Usage: scripts/demo_admin_session.sh <NN-name>
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="${1:?usage: demo_admin_session.sh <NN-name>}"
NODE="$(first_node)"

{
  echo "== Zero-open-port admin session, $(stamp)"
  echo; echo "-- Target node: public IP and key pair"
  aws ec2 describe-instances --region "$REGION" --instance-ids "$NODE" \
    --query 'Reservations[0].Instances[0].{instance:InstanceId,private_ip:PrivateIpAddress,public_ip:PublicIpAddress||`none`,key_pair:KeyName||`none`}' --output table

  echo; echo "-- Inbound rules on every security group attached to the node"
  sgs="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$NODE" \
    --query 'join(`,`, Reservations[0].Instances[0].SecurityGroups[].GroupId)' --output text)"
  aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$sgs" \
    --query 'SecurityGroupRules[?IsEgress==`false`].[GroupId,IpProtocol,FromPort,ToPort,CidrIpv4||ReferencedGroupInfo.GroupId||`-`,Description]' --output text | sort
  echo "inbound rules with an IPv4 CIDR source: $(aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$sgs" \
    --query 'length(SecurityGroupRules[?IsEgress==`false` && CidrIpv4!=null])' --output text)"
  echo "inbound rules covering port 22: $(aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$sgs" \
    --query 'length(SecurityGroupRules[?IsEgress==`false` && FromPort<=`22` && ToPort>=`22` && IpProtocol!=`-1`])' --output text)"

  echo; echo "-- Session Manager session (commands run on the node)"
  script -qec "aws ssm start-session --region $REGION --target $NODE --document-name AWS-StartInteractiveCommand \
    --parameters command='echo whoami: \$(id -un); echo host: \$(hostname); echo listening TCP sockets:; sudo ss -tln'" /dev/null \
    | tr -d '\r'

  sleep 5
  echo; echo "-- Session history for this node"
  aws ssm describe-sessions --region "$REGION" --state History \
    --filters "key=Target,value=$NODE" \
    --query 'Sessions[0:3].[SessionId,Status,StartDate,EndDate,DocumentName]' --output text
  echo; echo "-- Session recordings stored in S3"
  bucket="$(terraform -chdir="$ROOT/infra/zerotrust" output -raw session_log_bucket)"
  aws s3 ls "s3://$bucket/sessions/" | tail -5 | awk '{print $1, $2, $3, "bytes", "<session-id>.log"}'
} 2>&1 | proof "$OUT"
