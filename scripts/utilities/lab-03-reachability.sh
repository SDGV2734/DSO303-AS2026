#!/usr/bin/env bash
# Report configuration-level HTTP reachability for running USMS instances.
# Deliberately omit -e: missing optional AWS fields and expected lookup failures
# are classification inputs and must not terminate the whole report.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

printf '%-20s %-16s %-16s %-13s %s\n' NAME PRIVATE-IP PUBLIC-IP VERDICT REASON

aws ec2 describe-instances \
  --filters 'Name=tag:Project,Values=USMS' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress,PublicIpAddress,SubnetId,join(`,`,SecurityGroups[].GroupId)]' \
  --output text |
while IFS=$'\t' read -r name private_ip public_ip subnet_id group_ids; do
  [ -n "${name:-}" ] && [ "$name" != "None" ] || name="-"
  [ -n "${private_ip:-}" ] && [ "$private_ip" != "None" ] || private_ip="-"
  [ -n "${public_ip:-}" ] && [ "$public_ip" != "None" ] || public_ip="-"

  gateway=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
    --output text 2>/dev/null || printf 'None')

  if [[ "$gateway" != igw-* ]]; then
    verdict="UNREACHABLE"
    reason="no igw route on subnet"
  elif [ "$public_ip" = "-" ]; then
    verdict="NO-ADDRESS"
    reason="igw route present but no public address"
  else
    sg_allows_http=false
    IFS=',' read -r -a groups <<< "${group_ids:-}"
    for group_id in "${groups[@]}"; do
      [ -n "$group_id" ] || continue
      if aws ec2 describe-security-groups --group-ids "$group_id" --output json 2>/dev/null |
        jq -e 'any(.SecurityGroups[].IpPermissions[]?;
          .IpProtocol == "tcp" and
          (.FromPort // 65536) <= 80 and
          (.ToPort // -1) >= 80 and
          any(.IpRanges[]?; .CidrIp == "0.0.0.0/0"))' >/dev/null; then
        sg_allows_http=true
        break
      fi
    done

    if [ "$sg_allows_http" = true ]; then
      verdict="REACHABLE"
      reason="igw route + sg allows 80/tcp from 0.0.0.0/0"
    else
      verdict="UNREACHABLE"
      reason="igw route present but sg blocks 80/tcp"
    fi
  fi

  printf '%-20s %-16s %-16s %-13s %s\n' \
    "$name" "$private_ip" "$public_ip" "$verdict" "$reason"
done
