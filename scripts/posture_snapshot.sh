#!/usr/bin/env bash
# Measures the network exposure of the workload VPC and scans its public endpoints from this machine.
# Usage: scripts/posture_snapshot.sh <NN-name>   (for example: 02-posture-before)
# Output is masked by scripts/mask.py and written to proof/<NN-name>.txt.
set -euo pipefail

LABEL="${1:?usage: posture_snapshot.sh <NN-name>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="us-east-1"
CLUSTER="payment-platform-eks"
OUT="$ROOT/proof/$LABEL.txt"

vpc="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=tag:Project,Values=zero-trust \
  --query 'Vpcs[0].VpcId' --output text)"

{
  echo "== Posture snapshot: $LABEL, $(date -u '+%Y-%m-%d %H:%M:%S') UTC, region $REGION"

  echo; echo "== Subnets (public IP on launch, route to an internet gateway)"
  for s in $(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$vpc" \
      --query 'Subnets[].SubnetId' --output text); do
    rt="$(aws ec2 describe-route-tables --region "$REGION" --filters Name=association.subnet-id,Values="$s" \
      --query 'RouteTables[0].RouteTableId' --output text)"
    [ "$rt" = "None" ] && rt="$(aws ec2 describe-route-tables --region "$REGION" \
      --filters Name=vpc-id,Values="$vpc" Name=association.main,Values=true --query 'RouteTables[0].RouteTableId' --output text)"
    igw="$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
      --query "RouteTables[0].Routes[?starts_with(GatewayId || '', 'igw-')].DestinationCidrBlock" --output text)"
    aws ec2 describe-subnets --region "$REGION" --subnet-ids "$s" \
      --query 'Subnets[0].[SubnetId,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch,Tags[?Key==`Name`]|[0].Value]' --output text \
      | awk -v igw="${igw:-none}" '{print $0 "\tinternet-gateway-route=" (igw=="" ? "none" : igw)}'
  done

  echo; echo "== Network interfaces with a public IP"
  aws ec2 describe-network-interfaces --region "$REGION" --filters Name=vpc-id,Values="$vpc" \
    --query 'NetworkInterfaces[?Association.PublicIp!=`null`].[InterfaceType,Association.PublicIp,Description]' --output text
  echo "count: $(aws ec2 describe-network-interfaces --region "$REGION" --filters Name=vpc-id,Values="$vpc" \
    --query 'length(NetworkInterfaces[?Association.PublicIp!=`null`])' --output text)"

  echo; echo "== EC2 instances (public IP)"
  aws ec2 describe-instances --region "$REGION" --filters Name=vpc-id,Values="$vpc" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,PrivateIpAddress,PublicIpAddress||`none`]' --output text

  echo; echo "== Security group inbound rules"
  aws ec2 describe-security-group-rules --region "$REGION" \
    --filters Name=group-id,Values="$(aws ec2 describe-security-groups --region "$REGION" --filters Name=vpc-id,Values="$vpc" \
      --query 'join(`,`, SecurityGroups[].GroupId)' --output text)" \
    --query 'SecurityGroupRules[?IsEgress==`false`].[GroupId,IpProtocol,FromPort,ToPort,CidrIpv4||ReferencedGroupInfo.GroupId||PrefixListId,Description]' --output text | sort
  echo "inbound rules open to 0.0.0.0/0: $(aws ec2 describe-security-group-rules --region "$REGION" \
    --filters Name=group-id,Values="$(aws ec2 describe-security-groups --region "$REGION" --filters Name=vpc-id,Values="$vpc" \
      --query 'join(`,`, SecurityGroups[].GroupId)' --output text)" \
    --query 'length(SecurityGroupRules[?IsEgress==`false` && CidrIpv4==`0.0.0.0/0`])' --output text)"

  echo; echo "== Load balancers"
  aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='$vpc'].[LoadBalancerName,Scheme,DNSName,join(',', ListenerDescriptions[].Listener.to_string(LoadBalancerPort))]" --output text
  aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$vpc'].[LoadBalancerName,Type,Scheme,DNSName]" --output text

  echo; echo "== NAT gateways and internet gateways"
  aws ec2 describe-nat-gateways --region "$REGION" --filter Name=vpc-id,Values="$vpc" Name=state,Values=available \
    --query 'NatGateways[].[NatGatewayId,NatGatewayAddresses[0].PublicIp]' --output text
  aws ec2 describe-internet-gateways --region "$REGION" --filters Name=attachment.vpc-id,Values="$vpc" \
    --query 'InternetGateways[].InternetGatewayId' --output text

  echo; echo "== EKS API endpoint"
  aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
    --query 'cluster.resourcesVpcConfig.[endpointPublicAccess,endpointPrivateAccess,join(`,`, publicAccessCidrs)]' --output text \
    | awk '{print "public access=" $1 ", private access=" $2 ", public CIDRs=" $3}'

  echo; echo "== External TCP scan from outside the VPC"
  targets=()
  for h in $(aws elb describe-load-balancers --region "$REGION" --query "LoadBalancerDescriptions[?VPCId=='$vpc'].DNSName" --output text) \
           $(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?VpcId=='$vpc' && Scheme=='internet-facing'].DNSName" --output text); do
    targets+=("$h")
  done
  ep="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.endpoint' --output text)"
  targets+=("${ep#https://}")
  for ip in $(aws ec2 describe-network-interfaces --region "$REGION" --filters Name=vpc-id,Values="$vpc" \
      --query 'NetworkInterfaces[?Association.PublicIp!=`null`].Association.PublicIp' --output text); do
    targets+=("$ip")
  done
  python3 "$ROOT/scripts/port_scan.py" "${targets[@]}"
} 2>&1 | python3 "$ROOT/scripts/mask.py" | tee "$OUT"
