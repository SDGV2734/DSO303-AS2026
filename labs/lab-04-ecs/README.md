# Lab 04 — ECS and Fargate

This lab deploys the USMS enrolment service as a containerized Amazon ECS
service running on Fargate in the private subnets created by Lab 02.

## Objective

Build a stable, fixed-capacity ECS service with two tasks spread across the two
private Availability Zones. The service is deliberately kept at
`desiredCount = 2`; load balancing belongs to Lab 05 and automatic scaling to
Lab 06.

## ECS objects

- **Cluster:** `usms-ecs-cluster`, the namespace for the service and tasks.
- **Task definition:** `usms-enrolment`, an immutable Fargate blueprint using
  `awsvpc`, 256 CPU units and 512 MiB memory.
- **Task:** one running instantiation of the task definition.
- **Service:** `usms-enrolment-svc`, which keeps `runningCount` equal to
  `desiredCount`.

## Resources created

- CloudWatch log group `/usms/ecs/enrolment` with seven-day retention.
- `usms-ecs-exec-role` for image pulls and log delivery.
- `usms-ecs-task-role` for the application, reusing Lab 01's
  `USMSStudentDataReadWrite` policy.
- `usms-enrolment-sg`, allowing TCP/80 only from `usms-app-sg`.
- ECS task definition and service in both private subnets.
- `configs/lab-04.env`, verification script, and cleanup script.

## Prerequisites

Labs 01–03 must be complete. Floci must be running with hybrid storage, and
`jq`, `python3`, Docker, and the AWS CLI must be available. Source
`configs/course.env` and the previous lab environment files before running the
commands in the handout.

## Implementation sequence

1. Resume Floci and load the environment files.
2. Verify the Lab 02 and Lab 03 dependencies.
3. Probe ECS, Application Auto Scaling, CloudWatch, and CloudWatch Logs support;
   record Path A, B, or C in `notes/lab-04-notes.md`.
4. Create the ECS cluster.
5. Create the CloudWatch log group.
6. Create the task execution role.
7. Create the task role and attach the Lab 01 policy.
8. Create the enrolment security group.
9. Register the task definition.
10. Create the service in both private subnets.
11. Read back desired, running, pending, and status values.
12. Write `configs/lab-04.env`.
13. Run verification and record the evidence before committing.

## Important limitation

Fargate removes the need to manage ECS container instances, but it does not
remove VPC networking. Each task still receives an ENI in a private subnet and
uses the NAT gateway, route tables, security groups, and S3 endpoint from Lab 2.

This lab does not create an ALB or configure Application Auto Scaling.
