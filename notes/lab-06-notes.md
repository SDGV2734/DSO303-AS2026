# Lab 06 Notes

## Step 3 — Floci support path

**Path B / partial support.** ECS scalable targets, target-tracking policies,
step policies, CloudWatch metrics, alarms, and suspension state are supported.
`put-scheduled-action` and `describe-scheduled-actions` return
`UnsupportedOperation`, so the two scheduled actions are recorded as a Floci
limitation rather than fabricated. Real AWS would store and evaluate both
weekday schedules.

## Results and limitations

The scalable target is `service/usms-ecs-cluster/usms-enrolment-svc`, dimension
`ecs:service:DesiredCount`, minimum 2 and maximum 10. The CPU policy targets 50%
with 60-second scale-out and 300-second scale-in cooldowns. The ALB request
policy targets 1000 requests per target and uses the six-segment ResourceLabel
recorded from Lab 05. The queue step policy adds 1 task for a 0–100 interval and
3 tasks above 100, driven by `usms-enrolment-queue-high`.

The alarm was forced to ALARM for the controlled test, but Floci did not move
`desiredCount` or create a scaling activity record. Real AWS would invoke the
step policy and record a cause string in scaling activities. The baseline was
restored to desired 2 and all suspension switches are false.

The four-term CPU scale-out latency arithmetic is:

`60 seconds period × 3 evaluations = 180 seconds`, plus approximately `0`
seconds policy invocation, plus measured task startup time, plus the 60-second
ALB/ECS health-check grace period. I would first reduce the high-alarm
evaluation time only if the metric is trustworthy; the cost is more sensitivity
to transient spikes and possible over-scaling.

## Review questions

1. Application Auto Scaling changes the ECS service's `desiredCount`; it does
not edit the task definition, run containers directly, or replace the ALB. ECS
then starts/stops tasks, the service registers them with the target group, and
the ALB routes requests.
2. The resource ID is the three-part string
`service/usms-ecs-cluster/usms-enrolment-svc`, derived from the service ARN after
the final colon. DynamoDB and Lambda use different namespace-specific resource
shapes; this architecture also constructs the ALB ResourceLabel from the ALB
and target-group ARN suffixes.
3. Registering a scalable target with minimum 2 enforces the floor; the target,
not a policy, raises a service below that floor. An on-call engineer may raise
the floor during an incident, and the next operator can detect it with
`describe-scalable-targets`.
4. Managed target-tracking alarms belong to Application Auto Scaling and are
recreated when policies change; the queue alarm is ours and can use a custom
metric and explicit action. For a real queue, missing data should generally be
treated as breaching so a silent publisher cannot hide backlog, although this
hand-published emulator metric uses `notBreaching` to avoid false scale-out.
5. Reactive scaling waits for metric period/evaluations, policy invocation,
task startup, and health grace. That is why the floor is 2, scale-out cooldown
is 60, scale-in is 300, and scheduled scaling is preferred for known spikes.
6. On scale-out the largest capacity requested by any target policy wins; on
scale-in every policy must agree. Two target policies on one metric fight over
the set point, while step and target tracking on one metric can oscillate.
7. ALB request count is closer to user demand, independent of CPU reservation,
and naturally per-target. CPU is better for CPU-bound work whose cost varies
with computation. Request count scales badly for expensive requests that use
little CPU or when requests are mostly cached; CPU utilization would expose that
mismatch.

## Step 15 request-to-task chain

Student clicks Register → portal sends HTTP request → ALB listener accepts it →
listener forwards to target group → target group selects a healthy task IP →
task security group permits ALB traffic → ECS task receives port 80 request →
application processes the enrolment → response returns through ALB to portal.
This lab owns the scalable target, scaling policies/alarms, and desired-count
decision. The portal, ALB, target group, task definition, task networking, and
application were built earlier and needed no redesign. Auto scaling changes one
integer: the service's desired task count.
