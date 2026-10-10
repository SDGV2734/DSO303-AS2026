# Lab 04 Exercises

## Exercise 1 — Basic: deploy a second service

Created `usms-results-svc` from `usms-enrolment:1`, with desired count 1, both
private subnets, `usms-enrolment-sg`, and Project/Tier/Lab/Service tags. The
temporary service reached ACTIVE with one running task, while the original
service remained at desired 2. The two services differed in name and desired
count; task definition, launch type, subnets and security group were shared.
The temporary service was then deleted as required by Exercise 4.

## Exercise 2 — Intermediate: register a new revision

Registered `usms-enrolment:2` from `templates/lab-04-taskdef-v2.json`, raising
memory from 512 to 1024 MiB and adding `USMS_LOG_LEVEL=info`. The service now
points to revision 2 and is ACTIVE with desired/running 2; revision 1 remains
ACTIVE and describable. A revision is immutable, so the service's
`taskDefinition` pointer changes while revision 1 itself does not.

## Exercise 3 — Problem solving: configuration-drift report

Implemented `scripts/utilities/lab-04-ecs-inventory.sh`. It resolves every
service from the cluster API, computes role separation and public-IP risk, and
writes `outputs/lab-04-ecs-inventory.json`. Current inventory:

```text
usms-enrolment-svc desired=2 running=2 taskdef=usms-enrolment:2 roles=SEPARATE publicip=OK
```

The recorded cluster, service, roles, subnets, security group and log group
match the live APIs; no availability or security drift was found.

## Exercise 4 — Challenge: enrolment-week capacity plan

### Capacity plan

The fixed service cannot answer the 08:03 spike: nothing in this lab reads a
metric or a clock, so capacity changes only when a human runs `update-service`.
Start with a minimum of 2 tasks, schedule a floor of 10 tasks from 07:55–08:30,
and allow a maximum of 20 tasks. The 10-task peak is a planning derivation:
assume 200 requests/second and 25 requests/second sustainable per task, then
add two tasks of headroom: `ceil(200/25) + 2 = 10`. Too high wastes Fargate
compute; too low recreates queueing and outage risk. Target 60% service CPU (or
request rate when an application metric exists), scale out quickly, scale in
slowly with a 10-minute cooldown, and watch ALB/task health and scaling
activities before rolling back to the last task-definition revision.

For Linux/x86 in us-east-1, AWS lists $0.04048 per vCPU-hour and $0.004445 per
GB-hour on the [Fargate pricing page](https://aws.amazon.com/fargate/pricing/).
Our 0.25-vCPU/0.5-GB task therefore costs
`0.25*0.04048 + 0.5*0.004445 = $0.0123425/hour` before other charges. At 720
hours/month, two fixed tasks cost about `$17.77/month`; twenty fixed peak tasks
cost about `$177.73/month`. The proposed scheduled floor is deliberately
cheaper than running peak capacity all month while covering the known window.

The temporary Exercise 1 service was switched off with the dependency-safe
sequence: first set its desired count to zero (or use Floci's forced deletion
when stop is unsupported), then delete `usms-results-svc`. The permanent
`usms-enrolment-svc` service, cluster, roles, log group and security group were
not deleted. Verification remains healthy after the exercise resource removal.

## Exercise 5 — Integration: link back to Lab 03 and forward to Lab 05

The linkage report is in `outputs/lab-04-lab03-linkage.txt`. The source group is
`usms-app-sg` (`sg-d8b3e1ca4279edb2b`); the filtered Floci lookup returned the
recorded web instance `i-9c2ae17cd84c77491` plus an additional matching instance,
so the verdict is LOOP CLOSED with the extra match documented. Lab 05 should
attach to `usms-enrolment-svc`, port 80, both private subnets, and
`usms-enrolment-sg`. The group rule is temporary: Lab 05 removes it after the
load balancer becomes the only caller.
