#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT"
source configs/course.env; source configs/lab-04.env; source configs/lab-05.env; source configs/lab-06.env
PASS=0; FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
echo '== Scalable target =='
check 'exactly one ECS scalable target' "test \"\$(aws application-autoscaling describe-scalable-targets --service-namespace ecs --query 'length(ScalableTargets)' --output text)\" = 1"
check 'target resource and dimension' "aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids \"$USMS_SCALABLE_RESOURCE_ID\" --query 'ScalableTargets[0].ScalableDimension' --output text | grep -q DesiredCount"
check 'target bounds 2 and 10' "test \"\$(aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids \"$USMS_SCALABLE_RESOURCE_ID\" --query 'ScalableTargets[0].MinCapacity' --output text)\" = 2"
check 'all suspension switches false' "aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids \"$USMS_SCALABLE_RESOURCE_ID\" --query 'ScalableTargets[0].SuspendedState' --output json | grep -q 'false'"
echo '== Policies =='
check 'CPU policy exists' "aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id \"$USMS_SCALABLE_RESOURCE_ID\" --policy-names \"$USMS_CPU_POLICY\""
check 'request policy exists' "aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id \"$USMS_SCALABLE_RESOURCE_ID\" --policy-names \"$USMS_REQUEST_POLICY\""
check 'step policy exists' "aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id \"$USMS_SCALABLE_RESOURCE_ID\" --policy-names \"$USMS_STEP_POLICY\""
check 'queue alarm exists' "aws cloudwatch describe-alarms --alarm-names \"$USMS_QUEUE_ALARM\""
check 'baseline desired count is 2' "test \"\$(aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc --query 'services[0].desiredCount' --output text)\" = 2"
check 'task definition remains revision 2' "aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc --query 'services[0].taskDefinition' --output text | grep -q ':2$'"
check 'service remains load balanced' "aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc --query 'services[0].loadBalancers[0].containerName' --output text | grep -q enrolment-api"
check 'lab-06.env has no empty values' "! grep -qE '=$|=None$' configs/lab-06.env"
check 'templates are valid JSON' "python3 -c 'import glob,json; [json.load(open(f)) for f in glob.glob(\"templates/lab-06-*.json\")]'"
check 'cleanup script syntax' 'bash -n scripts/cleanup/lab-06-cleanup.sh'
echo; echo "PASS=$PASS  FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
