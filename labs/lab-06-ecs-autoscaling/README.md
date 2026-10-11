# Lab 06 — Implementing Auto Scaling for the ECS Application

## 1. Objectives

This lab adds Application Auto Scaling to the load-balanced ECS service created
in Labs 04 and 05. It registers `usms-enrolment-svc` as a scalable target with a
minimum of 2 and a maximum of 10 tasks, then configures CPU target tracking, ALB
request-count target tracking, queue-depth step scaling, scheduled scaling, and
scaling suspension/resumption.

Application Auto Scaling changes one value only: the ECS service's
`desiredCount`. ECS creates or stops tasks to make `runningCount` converge to
that value, while the ALB continues routing to healthy targets.

## 2. Prerequisites

- Labs 01–04 are complete and the ECS service uses `usms-enrolment:2`.
- Lab 05 is complete and the service is attached to `usms-enrolment-tg`.
- The service starts at desired count 2 with one deployment.
- Floci runs under Docker Compose with hybrid storage.
- `jq`, `python3`, and Docker are installed.
- The previous lab verification scripts pass, except for any documented Floci
  limitations.

Check the tools and storage before beginning:

```bash
cd ~/aws-floci-course
for t in jq python3 docker; do command -v "$t" || echo "MISSING $t"; done
./scripts/utilities/floci-storage-check.sh
```

## 3. Architecture and reused resources

The service path remains:

```text
Internet → ALB → target group → private Fargate tasks
                              ↑
                    ECS service desiredCount
                              ↑
                    Application Auto Scaling
```

Reused resources include `usms-ecs-cluster`, `usms-enrolment-svc`, task
definition `usms-enrolment:2`, the Lab 05 ALB and target group, both private
subnets, and the ALB-only task security-group rule.

## 4. Scaling configuration

| Component | Configuration |
| --- | --- |
| Scalable target | `service/usms-ecs-cluster/usms-enrolment-svc` |
| Dimension | `ecs:service:DesiredCount` |
| Minimum / maximum | 2 / 10 |
| CPU target tracking | `ECSServiceAverageCPUUtilization`, target 50, cooldowns 60/300 seconds |
| Request target tracking | `ALBRequestCountPerTarget`, target 1000, cooldowns 60/300 seconds |
| Queue step scaling | 0–100 adds 1; 100+ adds 3; cooldown 60 seconds |
| Queue metric | `USMS/Enrolment / EnrolmentQueueDepth` |
| Scheduled scaling | Weekday 07:45 floor 4; weekday 20:00 floor 2 |
| Suspended state | Dynamic in, dynamic out, and scheduled scaling all false at the end |

Target tracking creates its own high and low alarms. The queue step policy uses
the explicitly created `usms-enrolment-queue-high` alarm.

## 5. Step-by-step implementation

### Step 1 — Load six environment files

Source `course.env`, `lab-01.env`, `lab-02.env`, `lab-03.env`, `lab-04.env`,
and `lab-05.env`. Confirm the AWS account and service baseline.

### Step 2 — Verify dependencies

Confirm the VPC, private subnets, ECS cluster, task definition, ALB, target
group, load-balanced service, and desired count 2.

### Step 3 — Probe support

Probe `application-autoscaling`, CloudWatch metrics, alarms, and scheduled
actions. Record Path A, B, or C in `notes/lab-06-notes.md`. A supported object
API does not guarantee that Floci evaluates its control loop.

### Step 4 — Create/read the service-linked role

Use the Application Auto Scaling service principal:
`ecs.application-autoscaling.amazonaws.com`. Do not create an ordinary IAM role
or hand-write a trust policy. This Floci build uses the generated role name
`AWSServiceRoleForEcsApplicationAutoscaling`.

### Step 5 — Register the scalable target

Derive the resource ID from the service ARN, producing exactly:

```text
service/usms-ecs-cluster/usms-enrolment-svc
```

Register dimension `ecs:service:DesiredCount`, minimum 2, and maximum 10. Read
the target back and record its `RoleARN` and `SuspendedState`.

### Step 6 — Re-register the bounds

Raise the maximum temporarily to 12, read it back, then restore the maximum to
10. Re-registration updates the target bounds without creating a second target
or deleting policies.

### Step 7 — Create CPU target tracking

Register `usms-enrolment-cpu-target-tracking` from
`templates/lab-06-target-tracking-cpu.json`. Verify target 50, scale-out 60,
scale-in 300, and `DisableScaleIn=false`.

### Step 8 — Read managed alarms

List the two alarms created by target tracking. Do not edit or delete them. The
high and low alarms intentionally have asymmetric evaluation periods to avoid
rapid scale-in and oscillation.

### Step 9 — Create ALB request-count tracking

Validate the six-segment ResourceLabel from the Lab 05 ALB and target-group
ARNs, then register `usms-enrolment-requests-target-tracking` with target 1000.

### Step 10 — Create queue step scaling

Publish `USMS/Enrolment / EnrolmentQueueDepth`, register the two-step
`ChangeInCapacity` policy, and create `usms-enrolment-queue-high` with threshold
100 and the step-policy ARN as its alarm action.

### Step 11 — Create scheduled actions

Create a weekday morning action with minimum 4/max 10 at 07:45 Asia/Thimphu and
an evening action with minimum 2/max 10 at 20:00. If Floci returns
`UnsupportedOperation`, record the limitation and do not claim the actions were
created.

### Step 12 — Fire the queue alarm

Push the metric above 100, set the alarm to ALARM for the controlled test, and
observe `desiredCount`. Restore the service to 2. If Floci stores the alarm but
does not evaluate it, preserve `outputs/lab-06-scaling-proof.txt` with the
observed sequence and limitation.

### Step 13 — Suspend and resume

Set all three `SuspendedState` switches to true, verify them, then set all three
back to false. The final state must not leave any switch suspended.

### Step 14 — Prove persistence

Record the target and policy state, restart Floci, derive the resource ID and
policy names again from the APIs, and read them back. Record `PERSISTENCE PROVEN`
only after the target, policies, suspension state, and ECS baseline survive.

### Step 15 — Trace the request-to-task path

Document the nine-link chain from a student clicking Register through the ALB,
target group, task ENI, application, and response. Identify which three links
Lab 06 owns: scalable target, policies/alarms, and desired-count decision.

### Step 16 — Write configuration

Populate `configs/lab-06.env` with resource IDs, policy names/ARNs, metric names,
the ResourceLabel, scheduled-action names, and support flags. Values must be
looked up from APIs, not copied from assumptions.

### Step 17 — Review and commit

Run the verification script, inspect ignored outputs, check syntax, repair any
stale cleanup hint strings, and commit the Lab 06 files explicitly.

## 6. Verification and cleanup

Run:

```bash
bash scripts/utilities/verify-lab-06.sh
bash -n scripts/cleanup/lab-06-cleanup.sh
```

The cleanup script is intentionally a dry run until the end of the course. The
scalable target, three permanent policies, queue alarm, metric, and scheduled
actions belong in the KEEP set for later labs.

## 7. Evidence checklist

Keep the following evidence in ignored `outputs/` files:

- Scalable target with RoleARN, bounds, and suspension state.
- CPU managed alarms and request ResourceLabel validation.
- Queue alarm and scaling-proof explanation.
- Suspension output while true and after resuming.
- `PERSISTENCE PROVEN` output after restart.
- Pre/post restart records and the nine-line request chain in the notes.

The required screenshots are for Checkpoints 3, 5, and 7. Do not fabricate
scaling activity or scheduled-action output when the emulator does not provide
it.

## 8. Floci limitations recorded for this build

- The service-linked role is generated under a different valid name than the
  AWS documentation example.
- Scheduled-action APIs return `UnsupportedOperation`.
- Scaling policies and alarms can be stored and described without the emulator
  evaluating them or producing scaling activities.
- The target-tracking managed alarms may exist with empty evaluation data.

Real AWS continuously evaluates metrics, invokes scaling policies, records
scaling activities with cause strings, and executes scheduled actions.

## 9. Preparation for Lab 07

Keep the scalable target at min 2/max 10 with all suspension flags false. Keep
the ECS service at desired 2, task definition `usms-enrolment:2`, and the ALB
attachment unchanged. Lab 07 can now reuse the scaling configuration and
resource identifiers recorded in `configs/lab-06.env`.
