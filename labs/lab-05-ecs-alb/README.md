# Lab 05 — ECS behind an Application Load Balancer

This lab places the Lab 04 `usms-enrolment-svc` behind an internet-facing ALB.
The ALB spans both public subnets, forwards HTTP/80 to an IP target group, and
the ECS tasks remain private in both private subnets.

## Build

`Internet → usms-alb-sg → usms-enrolment-alb → usms-enrolment-tg →
usms-enrolment-sg → Fargate tasks`

The ECS service owns target registration. The target group uses `ip` targets,
GET `/` health checks, a 30-second deregistration delay, and the listener has a
priority-10 `/alb-health` fixed-response rule. Step 13 removes the old direct
`usms-app-sg` ingress so the ALB becomes the only task caller.

## Implementation sequence

1. Load Labs 01–04 and probe ELBv2 support.
2. Create the ALB security group and ALB in both public subnets.
3. Create/configure the target group and HTTP listener.
4. Allow the ALB group to reach the task group.
5. Attach the existing ECS service to the target group.
6. Verify target health, the request path, deployment draining, and persistence.
7. Remove the direct web-tier rule, write `configs/lab-05.env`, and verify.

This Floci build did not persist an in-place `update-service --load-balancers`
update, so the service was recreated with the same task definition and the
load-balancer attachment, as permitted by the handout's fallback.
