# Lab 09 Notes - Securing USMS with IAM Roles and Security Groups

## Support path and starting facts
- **Support path: B - management only.** Step 3 probe (outputs/lab-09-probe.txt): roles, policies, trust
  updates, access keys, security-group rules, prefix lists and describe calls all respond;
  `get-account-authorization-details`, `simulate-principal-policy`, `accessanalyzer list-analyzers` and
  `get-credential-report` are **not available**. Every proof in this lab is therefore a proof about a document.
- **`usms-student-data` did NOT exist** when Step 6 ran: `head-bucket` -> `(404) ... Not Found`. Lab 10 creates
  it. An IAM policy is a statement about ARNs, so it can be reviewed before the resource exists.
- Floci image `floci/floci:latest`, version label **1.7.0**.
- Baseline (outputs/lab-09-pre-verify.txt): lab-02 33/0, lab-03 36/0, lab-04 37/**1** (the one documented
  failure: `usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)`, caused by Lab 05 Step 13), lab-05 20/0,
  lab-06 14/0. The counts differ from the guide's example because this repo's verify scripts differ; Step 18
  only needs them to be identical before and after.
- The account has more than the guide's 5 roles: **10 inventoried** at Step 4 (Lab 01/02 exercise roles
  `usms-analytics-partner-role`, `usms-backup-operator-role`, the Lab 07 EKS roles and the ECS service-linked
  role), so the audit counts are larger than the guide's: **IAM HIGH=8 MED=33** before.

## Floci limitations met (with what real AWS would do)
| What | Observed here | Real AWS |
|---|---|---|
| Permissions boundary | `create-role --permissions-boundary` and `put-role-permissions-boundary` both **succeed (exit 0)**, but `get-role` returns `PermissionsBoundary: null` - accepted, never stored | Stored on the role and evaluated as a ceiling on every call |
| IMDSv2 | `modify-instance-metadata-options` -> `UnsupportedOperation: Operation ModifyInstanceMetadataOptions is not supported`; `HttpTokens` stays `optional` on usms-web-01 and usms-db-01 | `HttpTokens: required` enforced at the hypervisor the moment the call returns |
| Session policy | `assume-role --policy` returned credentials, and `iam list-users` (not in the session policy) still answered | The session would be limited to the intersection; `list-users` -> AccessDenied |
| Policy evaluation, SG enforcement | Nothing is evaluated; no traffic exists | Every API call and every packet evaluated |
| `simulate-principal-policy` | Not available -> used the Python intersection (Step 9) as the "read the documents" fallback | Second opinion from the policy simulator |
These are the two benign failures in `verify-lab-09.sh` (**PASS=48 FAIL=2**): `usms-deploy-role HAS a
permissions boundary` and `usms-web-01 requires IMDSv2`. Consequently Step 18's persistence files record
`None` for the boundary and `optional` for HttpTokens - identical before and after, so the diff passed, but
the message's wording ("the permissions boundary ... and the IMDSv2 requirement are unchanged") is only true
in the sense that *their absence* persisted. I state that rather than claim them.

---

## Step 4 - Your turn: two trust policies, side by side
- `usms-ec2-app-role`: `Principal: {"Service": "ec2.amazonaws.com"}` - a **service principal**.
- `usms-developer-role`: `Principal: {"AWS": "arn:aws:iam::000000000000:user/usms-dev-01"}` - an **AWS identity**.

The EC2 role is assumed *by a service on behalf of whatever it runs*: anyone who can launch an instance with
that instance profile (i.e. anyone with `ec2:RunInstances` + `iam:PassRole` on it) - or any code running on
usms-web-01 that can reach the metadata service - obtains its credentials, without ever calling
`sts:AssumeRole` themselves. The developer role is assumed *by one named human principal* calling
`sts:AssumeRole` with usms-dev-01's own credentials, so who can obtain it is exactly whoever holds that user's
access key - which is why Step 10 rotates it, and why a service-principal trust needs `aws:Source*` conditions
while a user-principal trust needs MFA instead.

## Step 6 - Your turn: what each workload actually needs
- **Enrolment API, to display a transcript:** `s3:GetObject` (on `usms-student-data/*`) and `s3:ListBucket`
  (on the bucket). ListBucket matters because without it S3 answers a missing key with **403 AccessDenied**
  instead of **404 NoSuchKey**, so the API could not tell "no transcript yet" from "not allowed".
- **Registry upload workflow, to store one:** `s3:GetObject`, `s3:ListBucket` and `s3:PutObject`.
- **The single extra action is `s3:PutObject`.** (`s3:GetBucketLocation` and `s3:DeleteObject` in this repo's
  Lab 01 policy are not needed by either list - DeleteObject in particular is a write nobody asked for.)

## Step 7 - result
`SAME PRINCIPAL, NEW CONDITION`: usms-ecs-task-role still trusts `ecs-tasks.amazonaws.com`, now with
`aws:SourceAccount = 000000000000` and `aws:SourceArn like arn:aws:ecs:us-east-1:000000000000:*`. The undo is
outputs/lab-09-ecs-task-role-trust-before.json. The explicit Deny in USMSStudentDataReadOnly adds nothing
today, but still wins if someone later attaches a broader policy to the reader role - keep it.

## Step 9 - session policy intersection
Assumed usms-developer-role with outputs/lab-09-session-policy.json (900 s). In this repo USMSDeveloperBase
already allows `sts:GetCallerIdentity`, so all four session actions came out ALLOWED; following the guide,
I added an action the role never had - `ec2:RunInstances` - and it computed **`NOT in the identity policy ->
denied`**: a session policy cannot grant anything the role did not already have. Method: the Python "read the
documents" fallback (simulate-principal-policy unavailable). Floci did not enforce it (`iam list-users` still
answered as the scoped session).

## Step 10 - key rotation
Before: one key `AKIA616E...` (Aug 2026). Create new key straight into outputs/ (chmod 600, ignored by
`.gitignore:8:outputs/*`) -> repoint the `usms-dev` profile -> verify `user/usms-dev-01` -> deactivate old
(two keys: Active + Inactive, profile still answering) -> delete old. After: exactly one key, created
2026-11-16. This lab compresses the "wait a day or a week" between deactivate and delete. On a real account a
human would use IAM Identity Center / federation (short-lived SSO credentials) and a workload a role, so no
long-lived key would exist.

## Step 11 - IMDSv2, and the Your turn
- **Not applied** (UnsupportedOperation). What real AWS would have done: `HttpTokens required` blocks the
  **SSRF credential theft** (a GET to 169.254.169.254 forced through the app returns nothing without a
  PUT-obtained token); `hop limit 1` blocks a **container on the instance** inheriting the host's role, because
  the response cannot survive the extra network hop. Safe rollout order: watch the per-instance
  `MetadataNoToken` CloudWatch metric until it is zero (all callers already use tokens) -> set
  `--http-tokens required` -> keep hop limit 1 (raise to 2 only if a container legitimately needs it).
- **Your turn, usms-db-01** (no instance profile: `Profile: null`): the right setting is the stronger one,
  **`--http-endpoint disabled`** - an instance with no role has nothing for the metadata service to hand out,
  so turning it off removes the attack surface entirely. It was attempted and is also unsupported here
  (recorded in outputs/lab-09-step11.txt). Applying the same setting to **usms-web-01 would break it**: its
  application gets its usms-ec2-app-role credentials *from* the metadata service, so every AWS call it makes
  would start failing.

## Step 12/13 - audit sorting (HIGH=3 MED=11 LOW=6 groups=8 before)
| Finding | Verdict |
|---|---|
| usms-alb-sg tcp/80 from 0.0.0.0/0 | Accepted risk - internet-facing load balancer (Lab 05) |
| usms-app-sg 80/443 from 0.0.0.0/0 | Open finding - a second front door (Exercise 4) |
| usms-app-sg tcp/22 from 10.0.0.0/16 | Fixed in Step 16 |
| default allow-all egress | Fixed on alb/enrolment/db (Steps 13-15); app-sg is Exercise 1 |
| default group, no interfaces | Accepted |
| usms-eks-cluster-sg 443 from 10.0.0.0/16 | Accepted - Lab 07's control-plane endpoint must be reachable from the whole VPC (nodes in both private subnets); out of this lab's scope |
| usms-exam-sg (Lab 02 exercise) | 443 from 10.10.0.0/16, no interfaces - leftover from an earlier exercise; **and it is a second source on usms-db-sg (see below)** |
- S3 prefix list found: **pl-63a5400a**; usms-enrolment-sg egress = tcp/443 -> pl-63a5400a + tcp/443 -> 0.0.0.0/0.

## Step 16 - SSH cutover
usms-bastion-sg did not exist (Lab 02 Exercise 2 not done) -> created (`sg-7342478fa9ca49e56`, SSH in from
203.0.113.10/32). usms-app-sg now admits tcp/22 only from usms-bastion-sg; the 10.0.0.0/16 rule was removed by
its rule ID. A compromised enrolment task (inside 10.0.0.0/16) can no longer reach SSH on the web tier.

## Step 17 - reachability and the negative proof
- **Finding beyond the guide:** control 4 is **not** "ONE group": `usms-db-sg` admits tcp/5432 from
  `usms-app-sg` **and from `usms-exam-sg`** (`PostgreSQL access from USMS exam-results service`), and Floci lists
  that second rule **twice**. It came from an earlier lab exercise, not from this lab, so Lab 09 left all ingress
  unchanged as instructed; but it widens who may reach the database and should be reviewed (remove it if the
  exam-results service no longer exists - usms-exam-sg has no interfaces).
- **If control 3 failed** (an IGW route appeared on the private route table): the database would still have
  no public IPv4 address (control 1) and its subnet would not assign one (control 2), so nothing on the
  internet has an address to send to - and usms-db-sg would still only admit the app/exam groups.
- **If control 4 failed** (usms-db-sg admitted 0.0.0.0/0 on 5432): the instance still has no public address
  and its subnet has no route to an internet gateway, so internet traffic could not reach it or be answered;
  and usms-private-nacl's implicit deny would still drop anything its explicit rules do not allow.
- Single point of control: usms-enrolment-sg is protected by exactly one ingress rule in the matrix - but the
  matrix models security groups only; the tasks' private subnets and lack of public addresses are further
  controls on the other axis.

## Step 18 - persistence and regression
- Floci stop/start, every identifier re-derived: pre-restart and post-restart files identical
  (trust Condition keys 2; boundary None [limitation]; reader role + its policy present; 1 access key;
  0 allow-all egress on 3 groups; 0 CIDR SSH sources; HttpTokens optional [limitation]).
- **NOTHING BROKE:** the five earlier verify scripts reported exactly the Step 2 lines.

## Step 19 - configs/lab-09.env: 16 exports, all values populated; `imds tokens` is honestly `optional`,
`allow-all egress left 0`, prefix list pl-63a5400a. No access key ID recorded.

## After
- IAM audit: **HIGH=8 -> 7** (usms-ecs-task-role fixed; new roles usms-transcripts-reader-role and
  usms-deploy-role have conditioned/user trusts). Still exit 1 - the remaining HIGHs are the unconditioned
  service trusts Exercise 2 deals with.
- SG audit after: **HIGH=3 MED=7 LOW=6** (MED 11 -> 7: three default egress rules and the CIDR SSH rule gone).

## Exercises (full write-up in `labs/lab-09-security/exercises.md`)
- **Ex 1:** `policies/usms-app-sg-egress.json` (unquoted heredoc, 0 `$`). It has six rules:
  - 443 → S3 prefix list;
  - 443 → 0.0.0.0/0 (STS and other endpoints);
  - 80 → sg:usms-alb-sg;
  - 5432 → sg:usms-db-sg;
  - udp/53 and tcp/53 → 10.0.0.2/32.

  The rules were authorised first and the default rule revoked afterwards. SG audit went MED 7 → 6; verify-lab-09 is still 48/2.
- **Ex 2:** `usms-breakglass-role` requires MFA AND an ExternalId (one Condition block). Its max session is
  3600 s, IAM's minimum (900 s was rejected with ParamValidation). The boundary was passed, but Floci stored
  null. `USMSBreakGlassScaling` allows RegisterScalableTarget + DescribeScalableTargets only.
  - Fixed: ecs-exec and lambda-exec trusts.
  - Accepted, in `configs/usms-iam-accepted-findings.json`: ec2-app-role and the service-linked autoscaling role.
  - Audit result: `HIGH=3 MED=37 ACCEPTED=2`, still exit 1. The three remaining HIGHs are the Lab 07 EKS roles and the backup operator; they were deliberately left unaccepted.
- **Ex 3:** `usms-exposure-report.sh`: EXPOSED=4, ISOLATED=2. Three of the EXPOSED interfaces belong to stopped
  instances. Floci models ENIs only for EC2 instances, so the ALB, NAT and task rows cannot appear. Output is
  identical from `~` and from the lab directory.
- **Ex 4:** the ISO review.
  - **New finding:** `usms-audit-01` can read every transcript through the AWS-managed `ReadOnlyAccess`
    policy on its group. A search for the bucket ARN cannot see this.
- **Ex 5:** the bucket-policy draft.
  - The bucket name is derived with `${BUCKET_ARN#arn:aws:s3:::}`.
  - 6 policies name the bucket, carried by 7 roles, giving 8 principals including root.
  - The draft has 14 statements. The analytics role keeps its `reports/*` limit.
  - `configs/lab-09.env` now has **17 exports**.
- Floci behaviour met during the exercises:
  - `describe-security-group-rules` lagged one read behind a revoke;
  - instances report `127.0.0.1` as their public IP and 172.19.x Docker addresses as private;
  - the boundary was again not stored.

## Section 14 - Review Questions

**1. Why "nothing broke" is a strong result.** The five earlier verification scripts were written before this
lab and by a different author. Step 2 recorded their summary lines (lab-02 33/0, lab-03 36/0, lab-04 37/1
documented, lab-05 20/0, lab-06 14/0) and Step 18 reproduced them exactly. So a large set of independent
assertions about the running system survived the identity changes (trust policies, a new boundary, key
rotation) and the network changes (written egress on four groups, the SSH cutover). That is regression evidence
I did not design to pass. A plausible break: `verify-lab-02.sh` asserts that `usms-app-sg` still has a port-80
rule. If the Exercise 4 move behind the load balancer had revoked the 0.0.0.0/0 rule *before* adding the
ALB-sourced port-80 rule, that check would have failed, and on real AWS the site would have gone down. I would
first decide whether the change was intended. If it was not, I would put the rule back from its undo document.
If it was, I would update the check in the same commit and say why, as Lab 05 Step 13 did. I would never delete
the check silently.

**2. Attaching the boundary as an identity policy.** The colleague's change would act in both directions.
- **Added:** the deploy role would *gain* everything the boundary lists, because an attached policy grants. That
  includes `ecs:*`, `elasticloadbalancing:*`, `logs:*`, `s3:PutObject` on `*`, and **`iam:PassRole` on `*` with
  no condition**. That is far more than USMSDeployBase's three named roles.
- **Removed, if it is moved out of the boundary slot:** the role loses its ceiling. Nothing would then cap a
  broad policy attached tomorrow.

The boundary's Deny statements would still apply, because a Deny in an identity policy is still a Deny. The
danger comes from the unconditioned PassRole. It becomes exploitable the moment the account contains a powerful
role trusted by a service the deploy role can drive. USMSDeployBase still denies passing roles to EC2, but
`lambda.amazonaws.com` or `ecs-tasks.amazonaws.com` would remain open. After Lab 10, `s3:PutObject` on `*` would
also let a pipeline overwrite transcripts. Section 8's check **"the boundary is attached to NOTHING as an
ordinary policy"** (AttachmentCount = 0) catches it. `usms-iam-audit.sh` would also report a new HIGH,
`iam:PassRole on Resource "*" with no Condition`.

**3. Correct ingress, still a breach.** Take an injection or SSRF bug in the enrolment API, reached through the
*legitimate* path: internet → ALB tcp/80 → tasks tcp/80. Every ingress rule is doing exactly what it should. The
attacker runs code in a task and uses the task role's credentials (USMSStudentDataReadWrite) to read
transcripts once Lab 10 creates the bucket. They then POST the data to a server they control.

Steps 13–15 **narrow** this incident:
- the task can no longer open a reverse shell on an arbitrary port;
- it can no longer tunnel data out over DNS;
- it can no longer reach the database on 5432 or SSH anywhere.

They do **not** stop the exfiltration itself, because tcp/443 to 0.0.0.0/0 is still open. That channel is the
one an attacker would choose anyway.

Preventing it entirely needs several things together:
- hostname-based egress filtering (AWS Network Firewall or an egress proxy allowing only the registry, Logs and STS);
- VPC interface endpoints;
- a bucket policy requiring `aws:SourceVpce`;
- least privilege, so a read-only API role cannot write.

This course cannot build that. Floci carries no packets for a firewall to filter, models no interface
endpoints, and enforces no IAM, so none of it could be shown working.

**4. An attacker calling `sts:AssumeRole` from their own machine.**
- **usms-ecs-task-role and usms-transcripts-reader-role** trust only the *service principal*
  `ecs-tasks.amazonaws.com`. An attacker's own credentials are never that principal, so a direct AssumeRole call
  fails whatever the conditions say.
- The conditions guard a different route: getting ECS itself to assume the role on the attacker's behalf from
  another account (the confused deputy). `aws:SourceAccount` and `aws:SourceArn` close that route.
- The two roles have the same answer. They differ only in blast radius if a real task of ours is compromised:
  the task role reads **and writes**, the reader role only reads.
- **usms-deploy-role** trusts a *user*, `usms-admin-01`. Anyone holding that user's credentials can assume it
  from anywhere on the internet. The trust has no MFA or source-IP condition (that is what Exercise 2's
  break-glass role adds).
- Here the boundary is what limits the damage. Even after a successful assume, the session cannot create users
  or keys, change any policy, remove its own boundary, or pass any role to EC2.

The answers differ because a service principal can only be "spoken" by AWS itself, while a user principal is a
long-lived human credential that can leak.

**5. Why "five controls" is not five times better than one.** The db-01 controls are not fully independent:
- controls 1 and 2 (no public address, no auto-assign) are correlated;
- all five are plain EC2 configuration, so one principal with `ec2:*` (or one bad CloudFormation change) could
  remove every one in a single afternoon.

Defence in depth protects against *independent* mistakes, not against a compromised administrator. Detection
(CloudTrail, Config) is what covers that. "One control" on usms-enrolment-sg is partly an artefact: the matrix
models security groups only. The tasks also sit in private subnets with no internet-gateway route and no public
address, behind the same NACL, so against the *internet* they are protected about as well as db-01. They are
genuinely more exposed in one respect: the load balancer is a deliberate, internet-facing path *to* them, so
application-layer attacks reach them by design. That risk is real, but no network control removes it.

**6. The two extra rotation steps.**
- **Step 2, moving every consumer before touching the old key,** protects against an outage. Take a CI job or a
  teammate's profile still using the old key. Deleting it first gives an immediate `InvalidClientTokenId` with no
  fallback.
- **Step 3, deactivating before deleting,** protects against a consumer you did not know about. Deactivation is
  reversible in seconds, so a forgotten cron job that breaks costs one `update-access-key --status Active`.
  Deleting is permanent and forces an emergency re-issue to everything.

A long-lived key is a compromise because it is a bearer credential. It works for anyone, from anywhere, until
someone rotates it. It leaks through Git, laptops, CI logs and screenshots, and nothing about it expires. The
course keeps one only because Lab 02's assume-role handshake needs a named user. A real system would use:
- **for humans:** IAM Identity Center (SSO) with MFA, which issues short-lived credentials;
- **for workloads:** roles. That means instance profiles, ECS task roles, EKS Pod Identity or IRSA, and OIDC
  federation for CI, so no static key exists at all.

**7. Is reading a substitute for testing?** Not on its own. The two catch different defects.
- **Reading catches what testing does not.** It finds over-grants in cases nobody thought to test. Reading the
  documents found that `usms-audit-01` can read every transcript through `ReadOnlyAccess`, and that the boundary
  would hand out `iam:PassRole` on `*` if attached. A test of the reader role's `GetObject` would pass and reveal
  neither, because security claims are about what *cannot* happen, and you cannot test every case.
- **Testing catches what reading does not.** It finds documents that are correct on paper but wrong in reality:
  - a condition on a key the service never sends (EC2 and `aws:SourceArn`), which makes a role unassumable and
    looks perfect when read;
  - a group reference that names the wrong but valid group ID;
  - IAM's eventual consistency;
  - IMDSv2 breaking an old SDK.

For student transcripts I would want **reading first**. The worst outcome is disclosure, and only reading
covers the untested cases. Before Lab 10 makes the bucket real, I would follow it on a real account with
`simulate-principal-policy` and IAM Access Analyzer, which do the reading mechanically, plus a small set of
positive and negative tests.
