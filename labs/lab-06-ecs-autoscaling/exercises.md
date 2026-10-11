# Lab 06 Exercises

## Exercise 1 — Memory and scale-out-only policies

Create a memory target-tracking policy and a policy with scale-in disabled.
Record their configuration and explain why a second policy scales out on the
largest request but scales in only when all policies agree.

## Exercise 2 — Step scale-in

Add a negative step adjustment for queue relief, verify non-overlapping step
intervals, and explain how competing policies can prevent unsafe scale-in.

## Exercise 3 — Scaling report

Build a report listing the scalable target, policies, managed alarms, scheduled
actions, suspended state, and scaling activities. Derive all values from APIs.

## Exercise 4 — Enrolment-week capacity plan

Use the two-private-subnet capacity and measured task startup latency to justify
minimum, maximum, scheduled floor, metric target, cooldowns, and cost tradeoffs.

## Exercise 5 — Lab 10 hand-off

Write a durable scaling-history JSON file containing policy and activity evidence
for Lab 10 to upload to the student-data bucket.
