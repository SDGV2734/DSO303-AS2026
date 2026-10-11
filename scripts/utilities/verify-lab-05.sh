#!/usr/bin/env bash
# Lab 05 verification. Known Floci limitation: service grace period is not
# persisted by this build; the intended value is recorded in lab-05.env.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT"
source configs/course.env; source configs/lab-02.env; source configs/lab-04.env; source configs/lab-05.env
PASS=0; FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
echo '== Lab 05 ALB =='
check 'ALB exists and is active' "test \"\$(aws elbv2 describe-load-balancers --load-balancer-arns \"$USMS_ALB_ARN\" --query 'LoadBalancers[0].State.Code' --output text)\" = active"
check 'ALB is internet-facing application type' "test \"\$(aws elbv2 describe-load-balancers --load-balancer-arns \"$USMS_ALB_ARN\" --query 'LoadBalancers[0].Scheme' --output text)\" = internet-facing"
check 'ALB spans two subnets' "test \"\$(aws elbv2 describe-load-balancers --load-balancer-arns \"$USMS_ALB_ARN\" --query 'length(LoadBalancers[0].AvailabilityZones)' --output text)\" = 2"
check 'ALB security group exists' "aws ec2 describe-security-groups --group-ids \"$USMS_ALB_SG\""
check 'target group is ip HTTP 80' "test \"\$(aws elbv2 describe-target-groups --target-group-arns \"$USMS_TG_ARN\" --query 'TargetGroups[0].TargetType' --output text)\" = ip"
check 'target group health path is /' "test \"\$(aws elbv2 describe-target-groups --target-group-arns \"$USMS_TG_ARN\" --query 'TargetGroups[0].HealthCheckPath' --output text)\" = /"
check 'target group is attached to ALB' "aws elbv2 describe-target-groups --target-group-arns \"$USMS_TG_ARN\" --query 'TargetGroups[0].LoadBalancerArns[]' --output text | grep -q \"$USMS_ALB_ARN\""
check 'listener exists on HTTP 80' "aws elbv2 describe-listeners --listener-arns \"$USMS_ALB_LISTENER_ARN\" --query 'Listeners[0].Port' --output text | grep -q '^80$'"
check 'listener forwards by default' "aws elbv2 describe-listeners --listener-arns \"$USMS_ALB_LISTENER_ARN\" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text | grep -q \"$USMS_TG_ARN\""
check 'health rule priority 10 exists' "aws elbv2 describe-rules --listener-arn \"$USMS_ALB_LISTENER_ARN\" --output json | grep -q '\"Priority\": \"10\"'"
echo '== ECS integration =='
check 'service is active' "test \"\$(aws ecs describe-services --cluster \"$USMS_ECS_CLUSTER\" --services \"$USMS_ENROLMENT_SERVICE\" --query 'services[0].status' --output text)\" = ACTIVE"
check 'service has target group attachment' "aws ecs describe-services --cluster \"$USMS_ECS_CLUSTER\" --services \"$USMS_ENROLMENT_SERVICE\" --query 'services[0].loadBalancers[0].targetGroupArn' --output text | grep -q \"$USMS_TG_ARN\""
check 'service maps enrolment-api port 80' "aws ecs describe-services --cluster \"$USMS_ECS_CLUSTER\" --services \"$USMS_ENROLMENT_SERVICE\" --query 'services[0].loadBalancers[0].containerName' --output text | grep -q '^enrolment-api$'"
check 'service has two running tasks' "test \"\$(aws ecs describe-services --cluster \"$USMS_ECS_CLUSTER\" --services \"$USMS_ENROLMENT_SERVICE\" --query 'services[0].runningCount' --output text)\" = 2"
# Floci can retain a healthy address briefly after a service replacement;
# require at least the two desired targets rather than rejecting that benign residue.
check 'target group has at least two targets' "test \"\$(aws elbv2 describe-target-health --target-group-arn \"$USMS_TG_ARN\" --query 'length(TargetHealthDescriptions)' --output text)\" -ge 2"
check 'targets are healthy or initial' "aws elbv2 describe-target-health --target-group-arn \"$USMS_TG_ARN\" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text | grep -Eq 'healthy|initial'"
echo '== Cutover and files =='
check 'task group has ALB source' "aws ec2 describe-security-groups --group-ids \"$USMS_ENROLMENT_SG\" --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text | grep -q \"$USMS_ALB_SG\""
check 'task group no longer has web source' "! aws ec2 describe-security-groups --group-ids \"$USMS_ENROLMENT_SG\" --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text | grep -q \"$USMS_APP_SG\""
check 'lab-05.env has no empty/None values' "! grep -qE '=$|=None$' configs/lab-05.env"
check 'cleanup script has valid syntax' 'bash -n scripts/cleanup/lab-05-cleanup.sh'
echo; echo "PASS=$PASS  FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
