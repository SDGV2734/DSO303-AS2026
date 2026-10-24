# Lab 09 Exercises

Run on support **Path B** (management only) against Floci 1.7.0. Nothing here is *enforced* by Floci, so every
proof is a reading of a document or a rule. The full raw output is in the git-ignored `outputs/lab-09-ex*.txt`
files. Screenshots are in `screenshots/`.

---

## Exercise 1 — Basic: finish the egress work on the web tier

**Document:** [`policies/usms-app-sg-egress.json`](../../policies/usms-app-sg-egress.json), written with an
**unquoted** heredoc (`<< EOF`). Four values had to be expanded at write time: the S3 prefix-list ID, the IDs of
`usms-alb-sg` and `usms-db-sg`, and the resolver address. A quoted heredoc would have left
`${USMS_ALB_SG}` in the file, and `authorize-security-group-egress` would have rejected it. The check
`grep -c '\$'` printed **0**.

| Req | Rule | Why this destination |
|---|---|---|
| 1 S3 | tcp/443 → **pl-63a5400a** | the managed prefix list of Lab 02's S3 gateway endpoint: transcripts traffic never leaves AWS |
| 2 AWS endpoints, STS | tcp/443 → 0.0.0.0/0 | STS, ECR and Logs have no prefix list here. On real AWS, narrow this to interface endpoints |
| 3 enrolment API | tcp/80 → **sg:usms-alb-sg** | a **group reference**: since Lab 05 the API *is* the load balancer, whose node addresses change. The tasks' group is the wrong target, because the web tier must not bypass the ALB |
| 4 database | tcp/5432 → **sg:usms-db-sg** | group reference to the data tier |
| 5a DNS | **udp/53 → 10.0.0.2/32** | the Amazon VPC resolver sits at the VPC base address +2 (10.0.0.0 network, .1 router, **.2 DNS**, .3 reserved), one of the five addresses AWS reserves per subnet, as Lab 02 noted. UDP comes first because it is DNS's normal transport |
| 5b DNS | **tcp/53 → 10.0.0.2/32** | DNS falls back to TCP when an answer is truncated (larger than 512 bytes, as with DNSSEC or long record sets). Allowing only UDP would break those lookups intermittently |

Every rule has a `Description`.

**Order: authorise first, then revoke.** Revoking the allow-all rule first would leave a window in which the
instance could initiate nothing at all (no STS credential refresh, no DNS), which is an outage. Once the
replacement rules exist, the revoke changes nothing that is still needed.

```console
=== 1. authorise the replacement FIRST
sgr-66398fce... sgr-9a0b9cb4... sgr-acfcd7a4... sgr-120aefb6... sgr-9f0f629e... sgr-e25e5331...
=== 2. only then revoke the default
True
allow-all egress remaining on usms-app-sg: 0
=== ingress untouched:  80 <- 0.0.0.0/0 | 443 <- 0.0.0.0/0 | 22 <- sg-7342478f (bastion)

$ ./scripts/utilities/usms-sg-audit.sh       (usms-app-sg)
    egress:
        tcp/443       to   pl:pl-63a5400a
        tcp/443       to   0.0.0.0/0
        tcp/80        to   sg:usms-alb-sg
        tcp/5432      to   sg:usms-db-sg
        udp/53        to   10.0.0.2/32
        tcp/53        to   10.0.0.2/32
    HIGH ingress tcp/80 from 0.0.0.0/0          <- ingress deliberately untouched (Exercise 4)
    HIGH ingress tcp/443 from 0.0.0.0/0
HIGH=3  MED=6  LOW=6  groups=8                  (MED 7 -> 6: the default egress finding is gone)

$ ./scripts/utilities/usms-reachability-matrix.sh   (egress)
  usms-app-sg   tcp/443 -> pl-63a5400a ; tcp/443 -> 0.0.0.0/0 ; tcp/80 -> usms-alb-sg ; tcp/5432 -> usms-db-sg ;
                udp/53 -> 10.0.0.2/32 ; tcp/53 -> 10.0.0.2/32

$ ./scripts/utilities/verify-lab-09.sh
PASS=48  FAIL=2          # the same two benign Floci failures (boundary, IMDSv2), unchanged
```

**Floci quirk:** in the first read after the revoke, `describe-security-group-rules` still listed the `-1`
rule while `describe-security-groups` already showed 0. A few seconds later both agreed on 0, on all four
groups. On real AWS, rule changes are near-instant but IAM is eventually consistent, so re-read before you
trust a result.

**Why 169.254.169.254 needs no rule:** the instance metadata service is a link-local address served by the
hypervisor on the instance itself. Traffic to it never leaves the host through the ENI, so security groups
(which filter at the ENI) never see it. That is why IMDSv2 tokens and the hop limit (Step 11) are the controls
for it, not a security group.

**`usms-bastion-sg` is different in kind.** A jump host's whole job is to *initiate* SSH into the VPC, so
"nothing outbound" is wrong for it. Its egress should be **tcp/22 to `sg:usms-app-sg`** (and to any other
group that admits SSH from the bastion), not allow-all to the internet. That way a compromised bastion can
reach only the hosts it administers, and cannot exfiltrate data or pull tools from the internet. ✅

---

## Exercise 2 — Intermediate: the break-glass role, and the findings Lab 09 left open

### Part A — `usms-breakglass-role`

- Trust: [`policies/trust-breakglass.json`](../../policies/trust-breakglass.json)
- Permissions: [`policies/usms-breakglass-policy.json`](../../policies/usms-breakglass-policy.json), as policy `USMSBreakGlassScaling`

| Requirement | How |
|---|---|
| 1 only usms-admin-01 | `Principal: {"AWS": "arn:aws:iam::000000000000:user/usms-admin-01"}` |
| 2 MFA | `"Bool": {"aws:MultiFactorAuthPresent": "true"}` |
| 3 ExternalId | `"StringEquals": {"sts:ExternalId": "usms-breakglass-suspend-scaling"}` |
| 4 shortest max session | `--max-session-duration 3600`. **3600 s is IAM's minimum**: `update-role --max-session-duration 900` was rejected client-side with `ParamValidation` |
| 5 permissions boundary | `--permissions-boundary USMSPermissionsBoundary`, accepted but **not stored** on Floci 1.7.0 (`PermissionsBoundary: null`, the same limitation as Step 8) |
| 6 exactly Lab 06's calls | `application-autoscaling:RegisterScalableTarget` (Lab 06 set `--suspended-state` through it) and `application-autoscaling:DescribeScalableTargets` (to verify), conditioned on `application-autoscaling:service-namespace = ecs`. **No wildcard actions** |

**AND or OR?** Both conditions are in **one `Condition` block** and under **different operators**
(`Bool`, `StringEquals`). IAM ANDs every condition operator in a block, and every key within an operator,
so assuming the role needs MFA **and** the external ID. OR exists only *within* a single key's list of
values. That is the behaviour wanted here: either control alone is too weak.

**What `sts:ExternalId` buys inside one account.** Normally it stops a third party being tricked into using
your role (cross-account confused deputy). In one account it is not a secret (it is committed to Git); it is a
**deliberate speed-bump**. Nobody assumes the break-glass role by accident or out of habit, because the call
must name this role's purpose. It also leaves an unmistakable string in CloudTrail's `AssumeRole` event,
which makes break-glass use easy to alert on.

Resource `"*"` on the two actions is a conscious choice. The scalable target's identifier
(`service/usms-ecs-cluster/usms-enrolment-svc`) is not an IAM resource ARN that these calls can be scoped to,
so the `service-namespace = ecs` condition is what narrows it. The audit reports it as `MED
application-autoscaling:RegisterScalableTarget on Resource "*"`, an accepted, documented MED.

### Part B — the unconditioned service trusts

| Role | Decision | How |
|---|---|---|
| `usms-ecs-exec-role` | **Fixed** | same scoped trust as Step 7 (`policies/trust-ecs-tasks-scoped.json`): `aws:SourceAccount` + `aws:SourceArn arn:aws:ecs:us-east-1:000000000000:*` |
| `usms-lambda-exec-role` | **Fixed** | new [`policies/trust-lambda-scoped.json`](../../policies/trust-lambda-scoped.json): `aws:SourceAccount` + `aws:SourceArn arn:aws:lambda:us-east-1:000000000000:function:*` |
| `usms-ec2-app-role` | **Accepted** | EC2 does not send `aws:SourceArn` for instance profiles, so a condition would break every instance. Compensating controls: `USMSDeployBase` **denies `iam:PassRole` to `ec2.amazonaws.com`**, and credentials are reachable only via IMDS, which should require v2 tokens with hop limit 1 |
| `AWSServiceRoleForEcsApplicationAutoscaling` | **Accepted** | a service-linked role, whose trust is owned by AWS and cannot be edited |

Both fixes kept the **same principal** and gained **2 condition keys**; the undo files are
`outputs/lab-09-usms-*-trust-before.json`. Afterwards `verify-lab-02..06` reported exactly the Step 2 lines:
**NOTHING BROKE**.

**Audit that reports decisions.** [`configs/usms-iam-accepted-findings.json`](../../configs/usms-iam-accepted-findings.json)
is committed, and every entry carries `reason`, `compensating_control`, `accepted_by` and `review_by`.
`usms-iam-audit.sh` reads it (path overridable with `USMS_IAM_ACCEPTED`), ignores any entry missing a reason
or a compensating control, prints matching HIGH findings as `ACCEPTED (was HIGH)` together with the reason,
and **still exits 1 for any unaccepted HIGH**:

```console
    ACCEPTED (was HIGH) trust policy: service principal ec2.amazonaws.com with NO Condition (confused deputy)
             reason: EC2 does not send aws:SourceArn/aws:SourceAccount when it assumes an instance-profile role ...
    ACCEPTED (was HIGH) trust policy: service principal ecs.application-autoscaling.amazonaws.com with NO Condition ...
HIGH=3  MED=37  ACCEPTED=2  roles=13          audit exit code: 1
```

The three remaining HIGH findings were deliberately left **unaccepted**. They are `usms-eks-node-role`
(ec2), `usms-eks-cluster-role` (eks) and `usms-backup-operator-role` (lambda), roles from Lab 07 and earlier
exercises that the guide puts outside this audit's scope. The backup operator can be fixed exactly like
`usms-lambda-exec-role`. The EKS roles need their own review. Hiding them would turn the file into a
suppression list. ✅

---

## Exercise 3 — Problem solving: the exposure report

**Script:** [`scripts/utilities/usms-exposure-report.sh`](../../scripts/utilities/usms-exposure-report.sh).
It takes no arguments, resolves `configs/` from `${BASH_SOURCE[0]}`, and contains no hard-coded IDs. It writes
`outputs/lab-09-exposure.json`.

Each verdict is computed from three facts only:
- does the subnet have an IGW route (from its explicit route table, or the **main** table if it has no explicit association)?
- is there a public address (the ENI association, or the attached instance's `PublicIpAddress`)?
- does any of its groups admit `0.0.0.0/0` or `::/0`?

Names and descriptions only **label** rows.

```console
$ cd ~ && ~/Desktop/.../aws-floci-course/scripts/utilities/usms-exposure-report.sh
usms-web-01        172.19.0.7     127.0.0.1      EXPOSED      igw route + sg allows 443,80 from 0.0.0.0/0
usms-web-01        172.19.0.3     127.0.0.1      EXPOSED      igw route + sg allows 443,80 from 0.0.0.0/0  [instance stopped]
usms-web-02        172.19.0.4     127.0.0.1      EXPOSED      igw route + sg allows 443,80 from 0.0.0.0/0  [instance stopped]
usms-web-02        172.19.0.4     127.0.0.1      EXPOSED      igw route + sg allows 443,80 from 0.0.0.0/0  [instance stopped]
usms-db-01         172.19.0.6     -              ISOLATED     no igw route on subnet
usms-db-02         172.19.0.5     -              ISOLATED     no igw route on subnet  [instance stopped]

EXPOSED=4  UNKNOWN=0  ADDRESSABLE=0  INTERNAL=0  ISOLATED=2  interfaces=6
IDENTICAL output from ~ and from labs/lab-09-security/
```

**Edge cases handled.**
- A group not in the cached VPC listing is fetched by ID. If it still cannot be read, the verdict is
  `UNKNOWN`, never assumed safe.
- A missing description falls back to the interface type, then to the ENI ID.
- A subnet with no explicit association falls back to the VPC's main route table.
- An interface whose instance is terminated, or missing altogether, is flagged `[... should not exist]`.

**`set -uo pipefail` without `-e`.** This is a report. One failing describe call (a group deleted mid-run)
must become one `UNKNOWN` line, not a silently truncated report, so every call is checked explicitly instead
(the reason is written in the script's header comment).

**The "public interface with no ingress rule at all" verdict: `ADDRESSABLE`, not EXPOSED.** The internet has
an address and a route, but no rule lets anything in, so nothing is listening for the internet *today*. It is
not ISOLATED either, because one rule added to its group would make it EXPOSED with no route change. So it
gets its own class, sorted just below EXPOSED, as the place to look when a group changes. A NAT gateway is
the classic case, and it is fine there because it only initiates connections.

**What this build shows (and hides):**
- Floci models **only EC2 instances** as ENIs. The ALB, NAT gateway and Fargate tasks have no interfaces here,
  so the guide's `alb node` / `usms-nat` / `enrolment task` rows cannot appear.
- Instances report `127.0.0.1` as their "public" address, because that is Floci publishing through Docker.
- Three of the four EXPOSED rows are interfaces of **stopped** instances (`usms-web-01` and `usms-web-02` from
  Lab 03). They are not reachable now, but a start command would expose them again. Deleting them is the real
  fix.
- Exercise 1's egress changes did not alter any verdict, because exposure is decided by ingress. ✅

---

## Exercise 4 — Challenge: the security review, for the Information Security Officer

### 1. The second front door

`usms-web-01` (group `usms-app-sg`) is the Lab 03 web server. Since Lab 02 Step 14, its group has admitted
**HTTP and HTTPS from anywhere**, because before Lab 05 it *was* the public entry point. Lab 05 put the
enrolment API behind `usms-enrolment-alb`, but nobody closed the old door. So an attacker can still reach the
web server directly, skipping everything the load balancer adds: health-checked targets, a single place for
TLS and a WAF, and access logs. **It should no longer be reachable from the internet.**

What would have to change:
1. Create a target group for the web tier (`--target-type instance`, port 80, health check `/`), and register `usms-web-01`.
2. Add a listener rule on the existing ALB (for example host `www.` or path `/portal/*`) that forwards to it.
3. Add an ingress rule on `usms-app-sg`: tcp/80 **from `sg:usms-alb-sg`**. Add tcp/80 to `sg:usms-app-sg` on `usms-alb-sg`'s egress (Step 14 limited it to the enrolment group).
4. Only then, revoke the 80 and 443 rules from `0.0.0.0/0` on `usms-app-sg`, and release the Elastic IP `usms-web-eip`.

What would break: anything that used the web server's public IP or EIP directly (bookmarks, DNS records,
monitoring), and HTTPS terminated *on* the instance (TLS would move to the ALB's listener, which also needs an
ACM certificate and a 443 listener). Admin SSH is unaffected, because it already comes from the bastion group.

*The other side:* a single legacy web server has no autoscaling and no second AZ, so putting an ALB in front of
it adds cost and moving parts for no availability gain. With tight ingress and IMDSv2 it is an acceptable risk
until the portal is retired.

### 2. What restricting egress actually bought

**Prevented by Steps 13–15:**
1. A compromised **database host or enrolment task opening a reverse shell** to an attacker's server on an arbitrary port (4444, 8080), or **DNS-tunnelling data out**. Only tcp/443 is allowed out, and `usms-db-sg` cannot even resolve names.
2. A compromised enrolment task **scanning and attacking the database or the web tier**. Its egress no longer includes 5432 or 22 anywhere.
3. A compromised **load balancer path being used to reach anything except the enrolment tasks**. Its only allowed destination is `sg:usms-enrolment-sg`.

**Not prevented:**
1. An attacker **sending data out over HTTPS (tcp/443) to their own server**, which is still `0.0.0.0/0`. Preventing it needs hostname-based egress filtering: **AWS Network Firewall** (about US$0.395 per endpoint-hour plus US$0.065/GB processed, so roughly US$290/month per AZ before traffic¹), or an egress proxy.
2. An attacker **using stolen credentials from outside the VPC**. Egress rules filter packets, not API calls. That needs IAM conditions (`aws:SourceVpce` / `aws:SourceVpc` on the bucket policy) plus **VPC interface endpoints** (about US$0.01 per endpoint-hour per AZ plus US$0.01/GB², so about US$15/month each for 2 AZs).

So "we restricted egress" bought protection against **opportunistic command-and-control and lateral movement
over non-HTTPS ports**. It did **not** buy protection against **targeted exfiltration over HTTPS**.

### 3. Who can read or write a transcript

Derived from `policies/`, `outputs/lab-09-identity-inventory*.json`, `outputs/lab-09-bucket-policy-draft.json`
and a sweep of user and group policies:

| Principal | How it gets access | Read | Write/Delete | Granting document |
|---|---|---|---|---|
| usms-ec2-app-role | instance profile on usms-web-01 | ✅ | ✅ Put + **Delete** | USMSStudentDataReadWrite (Lab 01) |
| usms-ecs-task-role | Fargate task role | ✅ | ✅ Put + **Delete** | USMSStudentDataReadWrite |
| usms-eks-node-role | every pod on every EKS node | ✅ | ✅ Put + **Delete** | USMSStudentDataReadWrite (Lab 07) |
| usms-transcripts-reader-role | ECS task role (none uses it yet) | ✅ | ❌ (explicit Deny) | USMSStudentDataReadOnly (Lab 09) |
| usms-backup-operator-role | Lambda role | ✅ (conditioned) | ❌ | USMSBackupOperator |
| usms-lambda-exec-role | Lambda role | ✅ | ❌ | USMSLambdaBasic |
| usms-analytics-partner-role | assumed by usms-audit-01 | `reports/*` only | ❌ | USMSAnalyticsReportsReadOnly |
| **usms-audit-01** (and anyone in `usms-auditors`) | group policy | ✅ **every object** | ❌ | AWS-managed **ReadOnlyAccess** (`s3:Get*` on `*`). It names no bucket, so a search by bucket ARN misses it |
| usms-dev-01 / admins / qa via USMSDeveloperBase | group policy | list only (`s3:List*`) | ❌ | USMSDeveloperBase |
| account root | always | ✅ | ✅ | not removable by IAM |

(`USMSReportingReadOnly` names the bucket but is attached to nothing.)

**How I know it is complete, and why I cannot fully know.** The real-AWS answer is **IAM Access Analyzer**,
plus `get-account-authorization-details`, which dumps every user, group, role and policy in one call.
Analyzer reasons from the resource's side and also covers resource policies and cross-account access. On this
build, **both calls are "not available"** (Step 3 probe), so I swept all customer policies for the bucket ARN
*and* every policy granting `s3:` on `Resource "*"`, then walked users → groups → attached policies. That
sweep is what found **usms-audit-01**, which the bucket-ARN search alone missed. It still cannot see AWS-managed
policies attached elsewhere, or resource policies.

### 4. Knowing when it changes

| Need | Service | Detective? | Cost |
|---|---|---|---|
| A record of every API call (group change, policy attach, AssumeRole) | **AWS CloudTrail** management events | detective | first trail copy of management events is **free**³ |
| Alert on a security-group change or policy attachment within minutes | **EventBridge** rule on CloudTrail events → SNS email | detective | rules for AWS service events are free; SNS email is effectively free at this volume⁴ |
| "What did this group look like last Tuesday?" | **AWS Config** with `restricted-ssh` / `vpc-sg-open-only-to-authorized-ports` rules | detective | about US$0.003 per configuration item recorded plus per rule evaluation⁵ |
| Unusual AssumeRole, credentials used from a new location | **Amazon GuardDuty** | detective | 30-day free trial, then usage-based⁶ |
| Who outside the account can reach the bucket | **IAM Access Analyzer** (external access) | detective | free⁷ |

Everything in Lab 09 is **preventive**. None of it says when somebody *tries*.

**On the morning after an incident, read in this order:**
1. CloudTrail for `AssumeRole`, `CreateAccessKey`, `AttachRolePolicy`, `PutRolePolicy`, `UpdateAssumeRolePolicy`, `AuthorizeSecurityGroup*` and `ModifyInstanceMetadataOptions` in the incident window: who changed identity or network?
2. GuardDuty findings for the same window.
3. AWS Config's timeline for `usms-app-sg`, `usms-db-sg` and the four roles above.
4. S3 data events or access logs for `usms-student-data`: which principal read which objects. Enable these before you need them; they are not on by default.

¹ https://aws.amazon.com/network-firewall/pricing/ · ² https://aws.amazon.com/privatelink/pricing/ ·
³ https://aws.amazon.com/cloudtrail/pricing/ · ⁴ https://aws.amazon.com/eventbridge/pricing/ ·
⁵ https://aws.amazon.com/config/pricing/ · ⁶ https://aws.amazon.com/guardduty/pricing/ ·
⁷ https://aws.amazon.com/iam/access-analyzer/pricing/
(All prices are approximate us-east-1 list prices; check the linked pages before budgeting.)

### Command sequence: moving the web tier behind the load balancer (written, NOT run)

```bash
source configs/course.env; for f in 02 03 05; do source configs/lab-$f.env; done

# 1. a target group for the web tier
WEB_TG_ARN=$(aws elbv2 create-target-group --name usms-web-tg --protocol HTTP --port 80 \
  --vpc-id "$USMS_VPC_ID" --target-type instance --health-check-path / \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --target-group-arn "$WEB_TG_ARN" --targets Id="$USMS_WEB_INSTANCE"

# 2. a listener rule on the existing ALB
aws elbv2 create-rule --listener-arn "$USMS_ALB_LISTENER_ARN" --priority 20 \
  --conditions Field=path-pattern,Values='/portal/*' --actions Type=forward,TargetGroupArn="$WEB_TG_ARN"

# 3. let the ALB reach the web tier (authorise BEFORE revoking anything)
aws ec2 authorize-security-group-ingress --group-id "$USMS_APP_SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$USMS_ALB_SG,Description='HTTP from the ALB only'}]"
aws ec2 authorize-security-group-egress --group-id "$USMS_ALB_SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$USMS_APP_SG,Description='HTTP to the web tier'}]"
aws elbv2 describe-target-health --target-group-arn "$WEB_TG_ARN"     # wait for "healthy"
```
> **⚠ Destructive - read before running 4.** **What will be deleted:** the two internet ingress rules (tcp/80
> and tcp/443 from 0.0.0.0/0) on usms-app-sg. **What depends on it:** every client using the web server's
> public IP or EIP directly, and HTTPS terminated on the instance. **Reversible?** Yes, re-authorise the same
> two rules. **Effect on later labs:** verify-lab-02 only checks that *some* port-80 rule exists on usms-app-sg,
> so step 3's ALB-sourced rule keeps it passing. Re-run it, and verify-lab-09, to prove that.
```bash
# 4. close the second front door
aws ec2 revoke-security-group-ingress --group-id "$USMS_APP_SG" --protocol tcp --port 80  --cidr 0.0.0.0/0
aws ec2 revoke-security-group-ingress --group-id "$USMS_APP_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0
```
> **⚠ Destructive - read before running 5.** **What will be deleted:** the association of usms-web-eip
> (and then the address). **What depends on it:** DNS records and anything that pinned the old public IP.
> **Reversible?** Not the address: a released Elastic IP is gone for good. **Effect on later labs:**
> verify-lab-03 asserts that `$USMS_WEB_EIP_ALLOC` is attached to usms-web-01, so it will FAIL. Update that
> check first.
```bash
# 5. take away the public address
aws ec2 disassociate-address --association-id "$(aws ec2 describe-addresses --allocation-ids "$USMS_WEB_EIP_ALLOC" --query 'Addresses[0].AssociationId' --output text)"
aws ec2 release-address --allocation-id "$USMS_WEB_EIP_ALLOC"
./scripts/utilities/usms-exposure-report.sh     # usms-web-01 must now read INTERNAL or ISOLATED
```
✅

---

## Exercise 5 — Integration: the bucket policy the S3 lab will apply

**Script:** [`scripts/utilities/usms-bucket-policy-draft.sh`](../../scripts/utilities/usms-bucket-policy-draft.sh).
It applies nothing, works whether or not the bucket exists, and never reads or mentions an access key.

- **The bucket name is derived, not typed.** The script reads `USMSStudentDataReadWrite`'s Resource, then
  strips the prefix with the shell parameter expansion `BUCKET="${BUCKET_ARN#arn:aws:s3:::}"`. The comment
  beside it explains why: it is a pure string operation, it cannot fail on a missing bucket, and it needs no
  API call.
- **Principals are computed.** The script scans every customer policy whose document names the bucket. It
  found **6** policies, not the 3 the guide expected, because of earlier exercises. It then calls
  `list-entities-for-policy` on each and merges the results.
- **Each role keeps exactly what it already has.** The draft copies each role's actions **with its exact
  resource prefix and condition**. A first version widened `usms-analytics-partner-role` from `reports/*` to
  the whole bucket, which would have granted *more* than it has today. That was found and fixed.

```console
bucket (from USMSStudentDataReadWrite's Resource): usms-student-data
mechanical checks: PASS          # every Principal an ARN except the TLS Deny's "*"; bucket ARN with and without /*
6 policies name the bucket; 7 roles granted s3 actions; draft has 14 statements
Allow usms-analytics-partner-role  s3:GetObject                                usms-student-data/reports/*
Allow usms-backup-operator-role    s3:GetObject,s3:ListBucket                  usms-student-data (+Condition)
Allow usms-ec2-app-role            s3:DeleteObject,s3:GetObject,s3:PutObject   usms-student-data/*
...                                (ecs-task-role, eks-node-role, lambda-exec-role, transcripts-reader-role)
Deny  *                            s3:*   bucket + bucket/*   Condition aws:SecureTransport = false
Deny  NotPrincipal [7 roles + root] s3:*  bucket + bucket/*
```

- Readiness file: `outputs/lab-09-lab10-readiness.txt` (bucket name, 6 policy names, role ARNs, principal count **8**, and what changes at `create-bucket`).
- `configs/lab-09.env`: `USMS_BUCKET_POLICY_DRAFT=outputs/lab-09-bucket-policy-draft.json` appended, giving **17 exports**.
- Both output files are git-ignored (`.gitignore:8:outputs/*`).
- `usms-audit-01` (Exercise 4) holds `s3:GetObject` only through `ReadOnlyAccess` on `"*"`, so it is not one of the computed principals. **This draft would deny it**, which is the intended effect.
- Real AWS caveat: `NotPrincipal` with assumed roles must also list the `assumed-role/...` session ARNs. AWS now recommends `"Principal": "*"` plus an `aws:PrincipalArn` `StringNotLike` condition instead. The `NotPrincipal` form was kept here because the exercise requires an ARN principal on every statement except the TLS Deny.

**This Deny compared with `USMSStudentDataReadOnly`'s.**
- The Deny in `USMSStudentDataReadOnly` is part of an **identity** policy. It can only ever stop the actions of the one role it is attached to, `usms-transcripts-reader-role`.
- The draft's Deny statements belong to a **resource** policy. They stop **every principal** that touches the bucket, whatever that principal's own policies say, including future roles and anything with `ReadOnlyAccess`.
- **Only the resource policy applies to a principal in another account.** Your account's identity policies are never consulted for an outsider, but your bucket's policy always is. ✅
