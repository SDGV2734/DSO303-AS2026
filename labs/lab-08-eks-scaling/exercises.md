# Lab 08 Exercises

Run against `usms-eks-cluster` (context `usms-eks`, namespace `usms`, support **Path A**, one k3s node).
The full raw output for each exercise is in the git-ignored `outputs/lab-08-ex*.txt` files. Screenshots are
in `screenshots/lab_8/`.

---

## Exercise 1 — Basic: a second autoscaler

**Manifest:** [`manifests/lab-08/11-hpa-results.yaml`](../../manifests/lab-08/11-hpa-results.yaml). It uses
autoscaling/v2. Its settings are min 2 and max 6, a 60% CPU target, a 180 s scale-in stabilisation window, and
a scale-up limit of `Pods 2 per 30 s`. Scale-in removes 1 pod per 60 s.

Pre-check: `usms-results` declares a CPU request (`{"cpu":"50m","memory":"32Mi"}`), so the HPA has a
denominator.

```console
$ kubectl apply --dry-run=client -f manifests/lab-08/11-hpa-results.yaml
horizontalpodautoscaler.autoscaling/usms-results-hpa created (dry run)
$ kubectl apply -f manifests/lab-08/11-hpa-results.yaml
horizontalpodautoscaler.autoscaling/usms-results-hpa created
$ kubectl get hpa
NAME                 REFERENCE                   TARGETS       MINPODS   MAXPODS   REPLICAS
usms-enrolment-hpa   Deployment/usms-enrolment   cpu: 2%/50%   2         8         2
usms-results-hpa     Deployment/usms-results     cpu: 2%/60%   2         6         2
```

**Why 60% suits results when enrolment uses 50%:** results is a read-mostly service with predictable, cheap
requests, so it can run its pods hotter before adding capacity. Enrolment uses 50% because it takes the
sharp registration-week spikes and must keep more headroom to absorb a burst while new pods start. ✅

---

## Exercise 2 — Intermediate: make the gateway drainable

**The problem (Step 12):** `usms-gateway-pdb` has `minAvailable: 1` and the gateway had 1 replica. Every
voluntary eviction would drop it below the floor, so the PDB allowed **0** disruptions, and a node drain
could never finish.

**The fix is the workload, not the PDB.** In
[`manifests/lab-07/40-gateway.yaml`](../../manifests/lab-07/40-gateway.yaml) I set **`replicas: 2`**, which
is the simplest fix and needs none of the spreading tools. I also added an advisory
`topologySpreadConstraints` (`maxSkew: 1` on `kubernetes.io/hostname`, `ScheduleAnyway`), so the two pods
land on different nodes whenever there is more than one. `minAvailable: 1` is unchanged: one gateway pod
must always be serving, and that requirement has not changed.

**A clash fixed on the way:** this Lab 07 file also defined the `usms-gateway` **Service as ClusterIP**, but
Step 15 made it a LoadBalancer in `manifests/lab-08/50-service-loadbalancer.yaml`. Re-applying the Lab 07 file
would have silently turned the gateway back into ClusterIP. So the Service now lives **only** in the Lab 08
file, with a comment in the Lab 07 file explaining why.

```console
$ kubectl get pdb usms-gateway-pdb                       # before
usms-gateway-pdb   1   N/A   0
$ kubectl diff -f manifests/lab-07/40-gateway.yaml        # before apply
-  replicas: 1
+  replicas: 2
+      topologySpreadConstraints: ...
$ kubectl apply -f manifests/lab-07/40-gateway.yaml
deployment.apps/usms-gateway configured
$ kubectl get pdb
usms-enrolment-pdb   N/A   1     1
usms-gateway-pdb     1     N/A   1                          # ALLOWED DISRUPTIONS 0 -> 1
$ kubectl get pods -l app=usms-gateway -o wide
usms-gateway-d45b4c6f-jkxv4   1/1   Running   10.42.0.109   b5986361ebbf
usms-gateway-d45b4c6f-kq8bf   1/1   Running   10.42.0.111   b5986361ebbf
$ kubectl diff -f manifests/lab-07/40-gateway.yaml; echo $?
0                                                          # clean
$ kubectl get svc usms-gateway
usms-gateway   LoadBalancer   10.43.23.149   172.17.0.3   80:32712/TCP   # not reverted

# proof - the eviction refused in Step 12 is now accepted:
eviction of usms-gateway-d45b4c6f-jkxv4: ACCEPTED
usms-gateway-pdb   1   N/A   0     # while the replacement starts
usms-gateway-pdb   1   N/A   1     # once it is Ready again
```

**One node:** both pods are on `b5986361ebbf`, because this cluster has only one node. With two or more nodes,
the spread constraint would place them on different nodes. A drain of either node would then evict one
gateway pod (the PDB allows 1) while the other kept serving, and the drain would complete. Here I could only
show the PDB allowing an eviction, not the cross-node placement. ✅

---

## Exercise 3 — Problem solving: the autoscaler that will not act

I applied the manifest exactly as given (saved as `outputs/lab-08-ex3-broken.yaml`). The only addition was a
plain ClusterIP Service in front of it, so the load had an address. Then I put heavy load on it: two pods
running 16 parallel `wget` loops against that ClusterIP.

### What the commands showed, in order

```console
$ kubectl get deploy usms-reports
usms-reports   4/4   4   4                                  # manifest says replicas: 2, yet 4 run
$ kubectl describe hpa usms-reports-hpa    # Events
Normal  SuccessfulRescale  New size: 4; reason: Current number of replicas below Spec.MinReplicas
$ kubectl get hpa usms-reports-hpa
usms-reports-hpa   cpu: 68%/70%   MINPODS 4   MAXPODS 4   REPLICAS 4
```

**Fault A, the CPU request.** I looked at what the Deployment declares and what the pods actually received:

```console
$ kubectl get deploy usms-reports -o jsonpath='{...resources}'
{"limits":{"cpu":"200m","memory":"128Mi"}}                 # NO request declared
$ kubectl get pods -l app=usms-reports -o custom-columns=NAME,CPUREQ,CPULIM,QOS
usms-reports-89c744c64-bclb6   200m   200m   Guaranteed     # ...but the pods HAVE one
```

**This result differs from what the exercise expects.** The hint expects `<unknown>`. On this cluster
(Kubernetes v1.34), when a container sets a **limit but no request**, the API server **defaults the request to
the limit**. So the HPA had a denominator, the 200m limit, and showed `68%/70%`. The fault is still real: the
HPA is measuring against the **limit**, the pods reserve their full 200m (QoS Guaranteed), and the HPA can
never see a pod above 100% of its "request". To show the `<unknown>` case the exercise describes, I created a
Deployment with **no resources at all**:

```console
usms-reports-noreq-...   CPUREQ <none>   QOS BestEffort
usms-reports-noreq   cpu: <unknown>/70%
ScalingActive  False  FailedGetResourceMetric  the HPA was unable to compute the replica count:
  failed to get cpu utilization: missing request for cpu in container nginx of Pod usms-reports-noreq-...
```

**Fault B, min = max.** I pushed the load to about 66% (each pod at about 135m of 200m). That stayed below the
70% target, so to make the HPA *want* more pods I lowered the target to 30% for a test and then put it back:

```console
$ kubectl get hpa usms-reports-hpa           # test target 30%: desired = ceil(4 x 65/30) = 9
usms-reports-hpa   cpu: 65%/30%   4   4   4
ScalingLimited  True  TooManyReplicas  the desired replica count is more than the maximum replica count
```

### Causes, one sentence each

- **A (gives `<unknown>` when no limit is set either):** the container declares no CPU **request**, so the HPA
  has no denominator for "percentage of request". Here the limit was silently copied into the request
  instead, so the HPA measures against the wrong number.
- **B (stops action even with perfect metrics):** `minReplicas: 4` and `maxReplicas: 4`. The only value the HPA
  can clamp to is 4, so whatever the metric says, the replica count can never move. The HPA also forced
  replicas from 2 up to 4 the moment it was created.

### Fixes, one field each

```console
$ diff broken.yaml fixed.yaml
>             requests:
>               cpu: "50m"              # fix A
<   maxReplicas: 4
>   maxReplicas: 8                     # fix B
```

```console
12:38:48  cpu: 58%/70%    min=4 max=8 replicas=4
12:38:59  cpu: 129%/70%   min=4 max=8 replicas=8      # it can move now
ScalingActive  True  ValidMetricFound
pods: CPUREQ 50m  QOS Burstable
```

**Clean up (Section 15):** I deleted `usms-reports`, `usms-reports-hpa`, the helper Service and both load
pods. ✅

---

## Exercise 4 — Challenge: expose the results service properly

**Manifest:** [`manifests/lab-08/61-ingress-results.yaml`](../../manifests/lab-08/61-ingress-results.yaml):
an Ingress `usms-results-ingress` with one path, `/results`, routing to the existing `usms-results`
ClusterIP Service.

### Design, and why

| Requirement | How it is met | Rung |
|---|---|---|
| A path of its own | One Ingress containing only `/results` (Prefix) | Ingress (top) |
| Behind it | The existing `usms-results` **ClusterIP** Service. No NodePort and no LoadBalancer Service are needed, because with `target-type: ip` the ALB sends traffic straight to the pod IPs | ClusterIP (bottom) |
| A normal HTTP port | `alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'` | Ingress |
| Reachable from the university network only | `alb.ingress.kubernetes.io/conditions.usms-results` adds a **source-IP condition** to the `/results` listener rule (`203.0.113.0/24` is a documentation placeholder for the university's real range) | Ingress |
| Enrolment does not get the same exposure | The condition sits only on this Ingress's rule. Enrolment's rules do not get it | Ingress |
| No second load balancer | `alb.ingress.kubernetes.io/group.name: usms-portal` makes this an **IngressGroup** member, so the AWS Load Balancer Controller merges its rules into the **same ALB** as `usms-portal-ingress`, which gets the same group name | Ingress |
| A stable address | The ALB's DNS name, published under a fixed name through `external-dns.alpha.kubernetes.io/hostname: results.usms.example.edu`, which needs ExternalDNS and a Route 53 zone | Ingress |

**Why not a second `type: LoadBalancer` Service:** it would create a second NLB, which means a second
hourly bill, works at layer 4 with no path of its own, and offers no per-rule source-IP control. That fails
two parts of the brief.

**Why a separate Ingress rather than editing `usms-portal-ingress`:** it gives the Examinations Office's rule
its own object, which they can own and review, while the IngressGroup still shares the ALB. In production I
would also **remove `/results` from the public `usms-portal-ingress`**, so results is reachable only through
the restricted rule. I left it in place here because Step 16 and `verify-lab-08.sh` check for the three
original paths.

### What this build can and cannot demonstrate

```console
$ kubectl get ingress
usms-portal-ingress    <none>   *      80        # no class, no address
usms-results-ingress   <none>   *      80
$ kubectl describe ingress usms-results-ingress
  /results   usms-results:80 (10.42.0.48:80,10.42.0.49:80)
  alb.ingress.kubernetes.io/conditions.usms-results: [{"field":"source-ip","sourceIpConfig":{"values":["203.0.113.0/24"]}}]
via Service:      {"service":"usms-results","pod":"usms-results-7fc784c47f-lm95f",...}
via gateway LB:   {"service":"usms-results","pod":"usms-results-7fc784c47f-s5h2f",...}
```

There is no ingress controller here, because Floci runs k3s with `--disable=traefik`. So the Ingress is stored
and validated, its backends resolve to the right pods, and `/results` traffic reaches the results pods, but
**nothing enforces the rule**. On real EKS, the **AWS Load Balancer Controller** (needs IRSA), **ExternalDNS**
and a **Route 53 hosted zone** would implement it. The `conditions.*`, `group.name`, `scheme`,
`target-type`, `listen-ports` and `external-dns...hostname` annotations are the objects that would do the work.

### Cost

Approximate us-east-1 figures, checked against the AWS pricing page before any real decision:
- **Adding the `/results` rule to the existing ALB:** no new fixed cost. The ALB's base hourly charge (about
  US$16–20 per month) is already being paid for the portal, and results traffic only adds to its LCU (usage)
  charge.
- **The rejected design:** a second LoadBalancer Service would add a whole second NLB (about another US$16–20
  per month base, plus usage).
- **DNS:** a Route 53 hosted zone is about US$0.50 per month, plus a negligible per-query charge.

### What breaks if the cluster is unavailable

- **Only the EKS control plane is down:** the ALB, its target groups and the running results pods are
  unaffected, so `/results` **keeps working**. Nothing can change, though: no new pods, no re-registration of
  targets, no HPA.
- **The nodes or pods are down:** the ALB stays up at the same stable DNS name, but every target fails its
  `/healthz` check, so users get **HTTP 502/503** straight from the ALB.
- **Mitigations:** keep 2 or more results replicas spread across nodes with a PDB, as in Exercise 2. Add an
  ALB `fixed-response` default action, such as "Results temporarily unavailable", so users see a clear message
  instead of a bare 503. Keep the ECS deployment from Practical 2 as a fallback target if the Office needs
  higher availability than one cluster gives. ✅

---

## Exercise 5 — Integration: the artefacts Lab 10 needs

### Part 1 — `outputs/lab-08-scaling-evidence.json`

Assembled with `python3` from live `kubectl get hpa/deploy -o json` and `aws eks describe-nodegroup` output,
not typed by hand:

```console
$ python3 -m json.tool outputs/lab-08-scaling-evidence.json > /dev/null && echo "valid JSON"
valid JSON
hpa 2 8 current 2 | deploy 2 | nodegroup {'minSize': 2, 'maxSize': 4, 'desiredSize': 2} | nodes 1
```

It contains:
- a `generatedAt` timestamp;
- the HPA's full `spec` and `status`;
- the Deployment's replica count, ready count and CPU request;
- the node group's scaling configuration, with a note that the Step 10 update **failed** on this build;
- the observed Kubernetes node count (1);
- the observed scaling run (2→4→8→…→2, with timestamps).

### Part 2 — `outputs/lab-08-lab06-readiness.txt`

I re-derived this from IAM by chaining `list-policies` → `get-policy` (default version) → `get-policy-version`.
It is not copied from Lab 07.

```console
Policy ARN        : arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite
Roles carrying it : usms-ec2-app-role usms-ecs-task-role usms-eks-node-role
Bucket ARN (from the policy Resource): arn:aws:s3:::usms-student-data
Object ARN (from the policy Resource): arn:aws:s3:::usms-student-data/*
Does bucket 'usms-student-data' exist? NO - head-bucket fails; Lab 10 creates it
ServiceAccount : usms-enrolment-sa
Annotation     : eks.amazonaws.com/role-arn: arn:aws:iam::000000000000:role/usms-enrolment-s3-irsa-role
```

**Why that role and not `usms-eks-node-role`:** every pod on a node can use the node role's credentials,
including the gateway, results, timetable, the load generator and a compromised pod. A dedicated IRSA role
whose trust policy matches `system:serviceaccount:usms:usms-enrolment-sa` gives the student-data permissions
only to pods that run as that ServiceAccount, with short-lived credentials. The policy could then be detached
from the node role. That role is **proposed only**: IRSA cannot complete on this build (Lab 07 Step 21).

```console
$ git check-ignore -v outputs/lab-08-scaling-evidence.json outputs/lab-08-lab06-readiness.txt
.gitignore:8:outputs/*	outputs/lab-08-scaling-evidence.json
.gitignore:8:outputs/*	outputs/lab-08-lab06-readiness.txt
```

### Part 3 — "ECS or Kubernetes for USMS"

This is in `notes/lab-08-notes.md` (328 words, under the 400 limit). It recommends ECS on Fargate, gives the
strongest argument against that choice, and cites specific observations from Practicals 2 and 4. ✅
