#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$USMS_VPC_ID" \
  --query 'sort_by(Subnets,&CidrBlock)[].[SubnetId,CidrBlock,AvailabilityZone,Tags[?Key==`Name`]|[0].Value]' \
  --output text |
while read -r subnet_id cidr az name; do

    rt=$(aws ec2 describe-route-tables \
      --filters "Name=association.subnet-id,Values=$subnet_id" \
      --query 'RouteTables[0].RouteTableId' \
      --output text)

    # If no explicit route-table association exists,
    # use the VPC main route table.
    if [ "$rt" = "None" ] || [ -z "$rt" ]; then
        rt=$(aws ec2 describe-route-tables \
          --filters \
            "Name=vpc-id,Values=$USMS_VPC_ID" \
            "Name=association.main,Values=true" \
          --query 'RouteTables[0].RouteTableId' \
          --output text)
    fi

    igw=$(aws ec2 describe-route-tables \
      --route-table-ids "$rt" \
      --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
      --output text)

    nat=$(aws ec2 describe-route-tables \
      --route-table-ids "$rt" \
      --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId | [0]' \
      --output text)

    if [[ "$igw" == igw-* ]]; then

        printf '%s %s %s PUBLIC via %s\n' \
          "$name" "$cidr" "$az" "$igw"

    elif [[ "$nat" == nat-* ]]; then

        printf '%s %s %s PRIVATE via %s\n' \
          "$name" "$cidr" "$az" "$nat"

    else

        printf '%s %s %s ISOLATED no default route\n' \
          "$name" "$cidr" "$az"

    fi

done
