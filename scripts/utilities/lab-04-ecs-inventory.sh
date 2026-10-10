#!/usr/bin/env bash
# Do not use -e: a malformed service should be reported as N/A, not hide the rest.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"
mkdir -p "$REPO_ROOT/outputs"
cluster="${USMS_ECS_CLUSTER:-usms-ecs-cluster}"
json='[]'
while IFS= read -r service_arn; do
  [ -n "$service_arn" ] || continue
  raw="$(aws ecs describe-services --cluster "$cluster" --services "$service_arn" --output json 2>/dev/null || printf '%s' '{"services":[]}')"
  service="$(jq -c '.services[0] // {}' <<<"$raw")"
  name="$(jq -r '.serviceName // "unknown"' <<<"$service")"
  desired="$(jq -r '.desiredCount // "N/A"' <<<"$service")"
  running="$(jq -r '.runningCount // "N/A"' <<<"$service")"
  arn="$(jq -r '.taskDefinition // empty' <<<"$service")"
  taskdef="${arn##*/}"
  roles='SEPARATE'
  if [ -n "$arn" ]; then
    td="$(aws ecs describe-task-definition --task-definition "$arn" --output json 2>/dev/null || printf '%s' '{"taskDefinition":{}}')"
    taskdef="$(jq -r '.taskDefinition // {} | .family + ":" + (.revision|tostring)' <<<"$td")"
    execution="$(jq -r '.taskDefinition.executionRoleArn // ""' <<<"$td")"
    taskrole="$(jq -r '.taskDefinition.taskRoleArn // ""' <<<"$td")"
    [ "$execution" = "$taskrole" ] && roles='SAME'
  fi
  publicip="$(jq -r '.networkConfiguration.awsvpcConfiguration.assignPublicIp // "N/A"' <<<"$service")"
  public='OK'; [ "$publicip" = 'ENABLED' ] && public='RISK'; [ "$publicip" = 'N/A' ] && public='N/A'
  printf '%-22s desired=%-2s running=%-2s taskdef=%-20s roles=%-8s publicip=%s\n' "$name" "$desired" "$running" "$taskdef" "$roles" "$public"
  json="$(jq --arg name "$name" --arg desired "$desired" --arg running "$running" --arg taskdef "$taskdef" --arg roles "$roles" --arg publicip "$public" '. + [{service:$name,desired:$desired,running:$running,taskdef:$taskdef,roles:$roles,publicip:$publicip}]' <<<"$json")"
done < <(aws ecs list-services --cluster "$cluster" --query 'serviceArns[]' --output text | tr '\t' '\n')
printf '%s\n' "$json" > "$REPO_ROOT/outputs/lab-04-ecs-inventory.json"
