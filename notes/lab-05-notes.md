# Lab 05 Notes

## Step 3 — ELBv2 support path

**Path B / partial support.** The ALB, listener, target group, rules, target
health, and tag APIs respond. Floci did not persist the in-place ECS
`update-service --load-balancers` or `health-check-grace-period-seconds`
update, returning `LB: null` and `Grace: null`; the service was recreated with
the load balancer attached using the handout fallback. Real AWS persists both
fields and performs the rolling deployment natively.

## Observed evidence

- `usms-enrolment-alb` is active, internet-facing, and spans two public subnets.
- `usms-enrolment-tg` is an IP target group on HTTP/80 with GET `/` health checks.
- The listener forwards HTTP/80 to the target group and priority 10 `/alb-health`
  returns fixed HTTP 200.
- The target group reported `172.19.0.3` healthy and `172.19.0.5` healthy in
  Floci. These emulator addresses are not the Lab 2 CIDRs; the control-plane
  target registration is the evidence available in this build.
- The task security group now admits only `usms-alb-sg`; the direct web-tier
  rule was removed in Step 13.
- The `.elb.floci` DNS name did not provide a usable public data path, so
  `outputs/lab-05-path-proof.txt` records the control-plane proof instead of an
  invented HTTP 200.

## Review questions

### 1. Why not register targets manually?

The ECS service owns the target group's contents because it registers each task
when it starts and deregisters it when it stops. Manually registering an address
would be temporary and stale after a deployment or scaling event; ECS could
remove it or replace it, so the service—not the operator—is the source of
truth.

### 2. ECS healthy but ALB unhealthy

That means the container is alive from ECS's perspective but the ALB cannot
complete its network or HTTP health check. Check the security-group path first,
then the target-group health path/port; the first command is
`aws elbv2 describe-target-health --target-group-arn "$USMS_TG_ARN"`.

### 3. Health-check grace period

The grace period makes ECS ignore ALB health results for a new task's startup
window. Without 60 seconds, a 45-second application would be probed at 30
seconds, fail twice at the two-check threshold, be marked unhealthy and
replaced; the replacement repeats the same cycle and the deployment never
settles.

### 4. Why target type `ip`

Fargate `awsvpc` tasks have their own ENIs and private IPs, not a shared ECS
instance to target. The alternative is `instance`, suitable for EC2-backed
tasks; choosing it here would fail when the target group is created/attached or
would not represent the task network endpoints.

### 5. Deregistration sequence

When ECS stops a task it deregisters the IP, the ALB marks it `draining`, sends
no new requests, waits up to 30 seconds for in-flight requests, and only then
allows ECS to terminate the container.

### 6. ALB objects

The load balancer owns public nodes, the listener accepts protocol/port traffic,
the listener rule selects actions by path, and the target group owns targets and
health-check settings.

### 7. Scaling hand-off

Lab 06 changes the ECS service's `desiredCount`, not the target group. Because
the service owns registration, every newly created task automatically appears
in the target group; otherwise an operator would have to register and deregister
task IPs after every scaling event.
