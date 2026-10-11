#!/usr/bin/env bash
# Destructive end-of-course cleanup. Review targets before uncommenting calls.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT"
source configs/course.env; source configs/lab-05.env
cat <<'WARNING'
DANGER: this removes the Lab 05 ALB, listener, target group, and security groups.
DANGER: confirm Lab 06 no longer needs the service and ResourceLabel first.
DANGER: this action changes shared Floci state and is not part of normal verification.
DANGER: review the commands below before executing them.
WARNING
echo 'Dry run only. Uncomment the deletion commands after review.'
# aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" --load-balancers '[]'
# aws elbv2 delete-load-balancer --load-balancer-arn "$USMS_ALB_ARN"
# aws elbv2 delete-target-group --target-group-arn "$USMS_TG_ARN"
# aws ec2 delete-security-group --group-id "$USMS_ALB_SG"
