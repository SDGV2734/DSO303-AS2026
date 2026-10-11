# Lab 05 Exercises

## Exercise 1 — Second path

The existing listener can route another path to a second target group. Record
the target group, rule priority, path patterns, and target health without
manually registering targets.

## Exercise 2 — Repair verification

Step 13 intentionally removes the direct `usms-app-sg` rule. Update the Lab 04
verification logic to recognize the new ALB-only architecture and document why
the old check changed state.

## Exercise 3 — Load-balancer report

Create a report tool that lists the ALB, listeners, rules, target groups,
targets, health states, ECS service attachment, and task security groups. It
must compute whether the target group is empty and whether the ALB is the only
permitted caller.

## Exercise 4 — Exposure review

Document the internet-facing ALB, public HTTP rule, private task placement,
security-group path, and the risks of exposing an administrative path. State
which listener rule or security-group change would reduce each exposure.

## Exercise 5 — ResourceLabel hand-off

Build the Application Auto Scaling resource label from the ALB ARN suffix and
target-group ARN suffix, then record it in `configs/lab-05.env` for Lab 06.
