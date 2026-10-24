# Lab 09 — Securing the USMS Application with IAM Roles and Security Groups

## 1. Objectives

Labs 01–06 built the system; this lab reviews it on both access-control axes:
- **who can call what** (IAM): trust, identity and resource policies, boundaries and session policies;
- **what can reach what** (security groups and routing).

The method was the same throughout: audit before changing anything, fix identity before network, add rather
than replace, and prove at the end that nothing earlier broke.

Support path: **Path B, management only**. Roles, policies and rules can be created and read, but
`simulate-principal-policy`, `get-account-authorization-details`, Access Analyzer and the credential report
are absent. Floci (1.7.0) enforces neither IAM nor security groups, so **every proof here is a reading of a
document or a rule**, and each one is written into a script.

## 2. What was built

```
IDENTITY
  USMSStudentDataReadOnly      Get + List on the transcripts bucket, explicit Deny on Put/Delete/PutBucketPolicy
  usms-transcripts-reader-role scoped ecs-tasks trust (aws:SourceAccount + aws:SourceArn), carries the RO policy
  usms-ecs-task-role           SAME principal, NEW confused-deputy conditions (permissions untouched - Lab 10)
  USMSDeployBase               iam:PassRole -> 3 named role ARNs, iam:PassedToService ecs-tasks; Deny PassRole to ec2
  USMSPermissionsBoundary      a ceiling, attached to NOTHING (do not "tidy it up")
  usms-deploy-role             trusts user/usms-admin-01, boundary passed (Floci does not store it)
  usms-dev-01                  access key rotated: create -> move -> deactivate -> delete; exactly one key
  usms-web-01 / usms-db-01     IMDSv2 / endpoint-disabled attempted - UnsupportedOperation on Floci
NETWORK
  usms-enrolment-sg  out tcp/443 -> pl-63a5400a (S3) ; tcp/443 -> 0.0.0.0/0
  usms-alb-sg        out tcp/80  -> sg:usms-enrolment-sg   (a GROUP, not an address)
  usms-db-sg         out tcp/443 -> 0.0.0.0/0              (OS updates only)
  usms-app-sg        in  tcp/22  <- sg:usms-bastion-sg     (10.0.0.0/16 rule removed by rule ID)
                     out written in Exercise 1 (S3, HTTPS, ALB, DB, DNS to 10.0.0.2)
  usms-bastion-sg    created (Lab 02 Exercise 2 had not been done), SSH in from 203.0.113.10/32
EXERCISES
  usms-breakglass-role, USMSBreakGlassScaling     MFA AND ExternalId; 2 autoscaling actions
  ecs-exec / lambda-exec trusts                   conditioned; ec2 + service-linked ACCEPTED in a file
  usms-exposure-report.sh                         EXPOSED / ADDRESSABLE / INTERNAL / ISOLATED / UNKNOWN
  usms-bucket-policy-draft.sh                     14-statement resource-policy draft for the S3 lab
```

## 3. Files

| Path | Purpose |
|---|---|
| `policies/usms-student-data-ro-policy.json` | the read half of Lab 01's transcripts policy |
| `policies/trust-ecs-tasks-scoped.json`, `trust-deploy.json` | the scoped ECS trust; the user trust for the deploy role |
| `policies/usms-deploy-policy.json`, `usms-permissions-boundary.json` | scoped PassRole; the ceiling |
| `policies/usms-{alb,enrolment,db,app}-sg-egress.json` | written egress for four groups (`app` is Exercise 1) |
| `policies/usms-egress-allow-all.json` | the rule that was revoked, kept as the undo |
| `policies/usms-app-sg-ssh-bastion.json` | the group-referenced SSH rule |
| `policies/trust-breakglass.json`, `usms-breakglass-policy.json`, `trust-lambda-scoped.json` | Exercise 2 |
| `configs/lab-09.env` | **17 exports** (16 + `USMS_BUCKET_POLICY_DRAFT` from Exercise 5). No access key ID |
| `configs/usms-iam-accepted-findings.json` | accepted HIGH findings, each with a reason and a compensating control |
| `scripts/utilities/usms-iam-audit.sh` | 4 IAM checks; reads the accepted-findings file; exit 1 on any unaccepted HIGH |
| `scripts/utilities/usms-sg-audit.sh` | 4 security-group questions, with names resolved and interfaces counted |
| `scripts/utilities/usms-reachability-matrix.sh` | who may reach what, computed from rules only |
| `scripts/utilities/usms-exposure-report.sh` | Exercise 3: per-interface verdicts from route, address and ingress |
| `scripts/utilities/usms-bucket-policy-draft.sh` | Exercise 5: derives the bucket, computes the principals, writes the draft |
| `scripts/utilities/verify-lab-09.sh` | 50 checks, **PASS=48 FAIL=2** (both benign, see Section 5) |
| `scripts/cleanup/lab-09-cleanup.sh` | end of course only. Syntax-checked, **not run**. Also removes the break-glass role |
| `notes/lab-09-notes.md` | path, observations per step, the "Your turn" answers, Section 14 |
| `labs/lab-09-security/exercises.md` | Exercises 1–5 with commands and output, and the ISO review |

## 4. Steps, as performed

1. **Baseline.** Recorded lab-02 33/0, lab-03 36/0, lab-04 37/1 (the documented failure), lab-05 20/0 and
   lab-06 14/0.
2. **Probe.** The result was Path B. The transcripts bucket did not exist yet (`head-bucket` returned 404), as
   the guide expects.
3. **Inventory and IAM audit.** 10 roles, more than the guide's 5 because of earlier exercises and Lab 07. The
   audit found **HIGH=8**, all of them unconditioned service trusts.
4. **Read-only split.** Created `USMSStudentDataReadOnly` and `usms-transcripts-reader-role`. Rewrote the task
   role's trust and got `SAME PRINCIPAL, NEW CONDITION`.
5. **PassRole and the boundary.** Built the deploy role. The boundary is accepted but stored as `null` (a known
   Floci limitation).
6. **Session policy.** Computed the intersection: `ec2:RunInstances` came out **NOT in the identity policy →
   denied**.
7. **Key rotation.** Rotated the key in the four-step order. One key remains. The new key file is chmod 600 and
   git-ignored.
8. **IMDSv2.** UnsupportedOperation on Floci, so it was recorded along with what real AWS would do (and
   `--http-endpoint disabled` for usms-db-01).
9. **Security-group audit.** Found **HIGH=3 MED=11**. Also found that `usms-db-sg` admits 5432 from
   `usms-exam-sg` too, a leftover from an earlier exercise.
10. **Egress.** Wrote egress for the enrolment, ALB and DB groups, always authorising the new rules before
    revoking the old one. **0** allow-all rules remain on the three groups.
11. **SSH cutover.** Created the bastion group, added the group-referenced rule, then removed the CIDR rule by
    its rule ID.
12. **Matrix and the negative proof.** Listed five independent controls on usms-db-01. `usms-enrolment-sg` is a
    single point of control in the security-group-only model.
13. **Restart.** `PERSISTENCE PROVEN` (honestly: the *absence* of the boundary and IMDSv2 also persisted) and
    **NOTHING BROKE**.
14. **Env file.** Wrote `configs/lab-09.env`: 16 exports, later 17.

After the lab and Exercises 1–2:
- IAM audit: **HIGH=3 MED=37 ACCEPTED=2**, still exit 1, on purpose.
- SG audit: **HIGH=3 MED=6 LOW=6**.

## 5. Floci vs real AWS, as observed

| Observed | Recorded but not enforced | Conceptual on this build |
|---|---|---|
| Policies, roles and trust conditions stored and read back; egress rules with group and prefix-list destinations; rule removal by ID; key rotation, including the two-key state; persistence across a restart | Permissions boundaries (accepted, stored as `null`); session policies (credentials returned, policy ignored); all IAM and SG evaluation | IMDSv2 (`UnsupportedOperation`); simulate-principal-policy; Access Analyzer; the credential report; MFA; CloudTrail; Network Firewall; interface endpoints |

Other observations:
- `describe-security-group-rules` lagged one read behind a revoke, while `describe-security-groups` was correct.
- ENIs exist only for EC2 instances. Instances report `127.0.0.1` as their public IP and 172.19.x Docker
  addresses as private.
- `verify-lab-09.sh` has two benign failures: `usms-deploy-role HAS a permissions boundary` and
  `usms-web-01 requires IMDSv2`.

## 6. Verify

```bash
./scripts/utilities/verify-lab-09.sh | tail -1        # PASS=48 FAIL=2 (boundary + IMDSv2 - Floci limitations)
./scripts/utilities/usms-sg-audit.sh | tail -1         # HIGH=3 MED=6 LOW=6 groups=8
./scripts/utilities/usms-iam-audit.sh outputs/lab-09-identity-inventory-after.json | tail -1
                                                       # HIGH=3 MED=37 ACCEPTED=2 roles=13
grep -c '^export' configs/lab-09.env                   # 17
git status --short | grep outputs/ || echo "nothing from outputs/"
```

## 7. Next lab

Lab 10 creates `usms-student-data`. At that moment `USMSStudentDataReadWrite` (on the ec2-app, ecs-task and
eks-node roles) and `USMSStudentDataReadOnly` start granting real access. Lab 10 validates the Exercise 5
draft, `outputs/lab-09-bucket-policy-draft.json`, against the new bucket; the S3 configuration lab applies
it. Before then, decide what to do about `usms-audit-01`. Its `ReadOnlyAccess` lets it read every transcript,
and the draft's NotPrincipal Deny would block it.
