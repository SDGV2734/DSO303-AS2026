# Lab 04 Notes

## Step 3 — Floci support path

**Recorded support path: B — ECS only.**

ECS is supported by this Floci build. The `ecs list-clusters` and task-definition
skeleton probes succeeded. The `ecs describe-services` probe reached the ECS API
and returned `ClusterNotFoundException` because the deliberately named `probe`
cluster does not exist; this confirms that the operation is available.

Application Auto Scaling support is partial rather than complete. The
`describe-scalable-targets` and `describe-scaling-policies` operations succeeded,
but `describe-scheduled-actions` returned `UnsupportedOperation`. Therefore this
build does not meet Path A's full-support requirement and is recorded as Path B
for the lab. This limitation does not affect Lab 04 because its service uses a
fixed `desiredCount`; it must be considered when completing Lab 06.

The CloudWatch metric, alarm, and alarm-list probes succeeded, as did the
CloudWatch Logs `describe-log-groups` probe.

### Probe summary

| Area | Probe | Result |
| --- | --- | --- |
| ECS | `list-clusters` | Supported |
| ECS | `register-task-definition --generate-cli-skeleton` | Supported |
| ECS | `describe-services` | Supported; expected missing-cluster error |
| Application Auto Scaling | `describe-scalable-targets` | Supported |
| Application Auto Scaling | `describe-scaling-policies` | Supported |
| Application Auto Scaling | `describe-scheduled-actions` | Not supported |
| CloudWatch | `put-metric-data` | Supported |
| CloudWatch | `describe-alarms` | Supported |
| CloudWatch | alarm query with `--max-items 1` | Supported |
| CloudWatch Logs | `describe-log-groups` | Supported |

## Step 11 — Capacity evidence

The service was changed manually with `aws ecs update-service --desired-count 3`,
waited until it reached desired 3 and running 3, and then changed back to
`desired-count 2`. The final service state is desired 2, running 2, pending 0,
ACTIVE. This demonstrates that a human update changes `desiredCount`; no
Application Auto Scaling policy was involved. Floci returned no service events
(`events: null`), so the count transition is the available audit evidence for
this emulator limitation; real AWS would retain event messages for both changes.

## Review questions

### 1. Scaling attaches to a service

Auto scaling is not attached to a task definition. In Lab 06 the scalable target
is the ECS service `usms-enrolment-svc`, and a policy changes only that service's
`desiredCount`. The service controller then starts or stops tasks from its
immutable task-definition revision until `runningCount` catches up. ECS itself
does not know about the Application Auto Scaling object, so its observable view
is only the resulting desired/running/pending counts and task events.

### 2. Instance profile and task role deliver the same policy

An EC2 instance profile supplies temporary role credentials through the instance
metadata service to code running on `usms-web-01`; a Fargate task role supplies
temporary task credentials through the container credentials endpoint to code in
the task. Neither mechanism requires a long-lived access key on disk, and the
credentials are issued and rotated by the platform. Both identities reference
the same unchanged `USMSStudentDataReadWrite` policy and the same bucket ARN.
Before the bucket exists, the permission is valid but has no matching resource;
when Lab 10 creates `usms-student-data` at that ARN, both the EC2 application
and the task application become authorized without changing either role or
policy.

### 3. Execution role versus task role symptoms

If the execution role is wrong, the task normally fails before application
startup while pulling its image or creating its log stream; if the task role is
wrong, the container starts but an application AWS call such as S3 access is
denied. Both roles trust `ecs-tasks.amazonaws.com` because ECS assumes each role
on behalf of a task, even though ECS uses the execution role and application
code uses the task role for different operations.

### 4. Why the rule names a security group

Referencing `usms-app-sg` instead of a CIDR expresses the intended caller—the
web tier—without baking in an IP address that may change. It remains correct
even with a fixed task count because the task ENIs are still protected by the
same destination security group and only the web tier is an allowed caller.
Once Lab 06 changes the number and placement of tasks, a group reference covers
all task ENIs and continues to describe the trust relationship; a manually
maintained list of task addresses would be fragile and incomplete.

### 5. What Fargate removes and retains

Fargate removes the ECS container-instance fleet: there are no EC2 hosts for us
to patch, place tasks on, or scale. It does not remove networking or security
responsibility. In `awsvpc` mode every task has its own ENI and security group,
and it follows Lab 2's private route table, NAT gateway, NACLs, and S3 endpoint
just as an EC2 workload does.

### 6. Persistence skepticism

`aws ecs describe-clusters --clusters usms-ecs-cluster` could return the same
cluster identity in memory mode and hybrid mode during one running session,
because both modes serve the current in-memory object. A restart followed by
`aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc`
would distinguish them: hybrid storage should restore the service, while memory
mode would lose it. Identity alone is not persistence evidence; a restart and
read-back are required.

## Floci limitations recorded

This build supports ECS and most Application Auto Scaling read operations, but
`describe-scheduled-actions` returns `UnsupportedOperation`; it is therefore
recorded as Path B. ECS service events are returned as `null`, so Step 11's
desired-count transition is recorded by before/after service state rather than
by an event history. Real AWS would evaluate scaling continuously and retain
service and scaling activity records.
