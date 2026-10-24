# Lab 07 Notes - EKS

## Lab 07 support path
Probed on 2026-11-12T18:23:01Z
PATH A  - use aws eks throughout

## Step 3 - "EKS is just ECS with different names"

**What makes it false:** the data plane. With ECS on Fargate (Lab 04) the right-hand column of the
control-plane/data-plane table is almost empty - AWS runs the hosts. With EKS a managed node group
is a set of EC2 instances in *my* account: I patch them, I pay for them as ordinary EC2, they need
their own IAM role (the node role, trusting ec2.amazonaws.com) separate from the cluster role
(trusting eks.amazonaws.com), and an upgrade is two operations (update-cluster-version, then
update-nodegroup-version). ECS has no equivalent of a kubelet, etcd or a CNI plugin that I must own.

**What makes it nearly true:** both are a scheduler that keeps N copies of a container spec running
and replaces failed ones. A Task Definition ~ a pod template, an ECS Service ~ a Deployment +
Service, desiredCount ~ replicas, and both do rolling updates with a minimum-healthy guarantee.
The *job* is the same; the ownership boundary and the API (AWS-native vs portable Kubernetes) differ.

## Step 8 - what actually happened during create-cluster
- First `aws eks create-cluster` (as assumed `usms-developer-role`) hit an AWS CLI **read timeout**:
  Floci creates the cluster synchronously and was pulling `rancher/k3s:latest` inside the request.
  Floci's own pull then failed ("Transient image pull failure ... attempt 1/3").
- Fix: `docker pull rancher/k3s:latest` on the host so Floci found the image cached. The CLI's
  automatic retry then completed; a second create returned `ResourceInUseException` (already exists).
- `describe-cluster` showed FAILED -> CREATING -> ACTIVE while the retry ran.
- Identity restored to root afterwards (unset AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN, whoami.sh).
- Note: Floci uses `rancher/k3s:latest`, so the real Kubernetes version may be newer than the
  "1.30" that the eks API reports. The endpoint is https://localhost:6500, not 6443.

## Step 9 - cluster facts
- ACTIVE, 4 subnets, vpc-ba035792 (= USMS_VPC_ID), sg usms-eks-cluster-sg
- `_lb_ports_` tag = 8081,8082 (set at creation, no tag-resource fix needed)
- Your turn: `aws eks describe-cluster --name usms-eks-cluster --query 'cluster.[version,identity.oidc.issuer]' --output text`
  -> `1.30   https://oidc.eks.us-east-1.amazonaws.com/id/9BFF35DA75EC413BB0A5FB75DF1E6EFD`
- **What the OIDC issuer is for:** it is the URL of the cluster's OpenID Connect identity provider;
  ServiceAccount tokens are signed by it, and registering it in IAM lets a pod exchange its token
  for IAM role credentials (sts:AssumeRoleWithWebIdentity) - the basis of IRSA (Step 21).
  My build returns a URL, but it is not publicly reachable from STS, so IRSA still cannot complete.

## Step 11 - kubectl and nodes
- `aws eks update-kubeconfig --name usms-eks-cluster --alias usms-eks` worked; endpoint https://localhost:6500.
- First attempt: connection refused - the k3s container had **crashed** (log: 6-minute "Slow SQL",
  then `fatal ... context deadline exceeded`). Cause: Docker Desktop has only 3.8 GB and another
  course's kind cluster (dso202-p2) was using ~1.2 GB and most CPU. Stopped that cluster
  (`docker stop`, not deleted), restarted the k3s container, API ready in ~10 s.
- `kubectl get nodes`: **1 node** (b5986361ebbf, control-plane, Ready, no taints), version
  **v1.34.1+k3s1** although the eks API reports 1.30. The node group's desired=2 and t3.small are
  recorded only - Floci does not provision real node instances.

## Step 16 - Your turn: delete a pod
Deleted usms-enrolment-6965b8dbbb-bpx2g; the gateway was not restarted. Within seconds
usms-enrolment-6965b8dbbb-6sjcw replaced it, and 12 requests through /enrolment/ all succeeded
(9 answered by the new pod, 3 by the surviving one, 0 failures).
**The replacement was created by the ReplicaSet usms-enrolment-6965b8dbbb** (event
`SuccessfulCreate ... replicaset/usms-enrolment-6965b8dbbb`): its controller saw 1 pod where 2 were
desired and created one - not the Deployment, and not me.

## Incident - cluster down after Docker Desktop restarted (2026-11-13)
- Symptom: kubectl `connection refused` on localhost:6500; current context had silently switched to
  `docker-desktop`; a Ctrl+C'd `kubectl run usms-debug --rm` left a pod behind -> `AlreadyExists`.
- Docker Desktop restarted (Mac sleep), auto-restarting the other course's kind cluster (restart policy)
  but NOT the k3s container (restart=no).
- Restarting k3s failed with: `Failed to start networking ... failed to find interface with specified node ip`.
  Cause: k3s had registered its node at 172.17.0.3; after the Docker restart the container was given
  172.17.0.2, so its persisted node IP no longer existed on any interface.
- Fix: stop k3s, start a throwaway container on the default bridge (takes 172.17.0.2), start k3s
  (gets 172.17.0.3 again), remove the throwaway. API ready in ~10 s.
- **All Kubernetes state survived** (namespace, 3 Deployments, Services, ConfigMaps) - it lives in
  the k3s data volume. Pods restarted once (RESTARTS=1) and became Ready; smoke test passed.
- Lesson: Floci's EKS emulation is a single container with no restart policy and a stateful node IP;
  a real EKS control plane is managed by AWS and nodes are replaced, not resurrected.

## Step 17 - Secret
- Generated with `kubectl create secret ... --dry-run=client -o yaml` straight into
  `outputs/lab-07-secret.yaml` (chmod 600, git-ignored: `.gitignore:8:outputs/*`), NOT into
  manifests/ - so no base64 credential ever enters Git history.
- `kubectl get secret ... -o jsonpath='{.data.ENROLMENT_API_TOKEN}'` -> `ZmxvY2ktZHVtbXktdG9rZW4tbm90LWEtcmVhbC1zZWNyZXQ=`,
  `| base64 -d` -> `floci-dummy-token-not-a-real-secret`. No key needed: base64 is encoding, not encryption.
- `kubectl set env --from=secret/...` on kubectl v1.36 added two `env[].valueFrom.secretKeyRef`
  entries (not `envFrom.secretRef` as the guide shows). Same effect; `printenv` inside the pod shows
  the token in plain text - a Secret protects the value on the way to the pod, not inside it.
- 20-enrolment.yaml updated to include those two entries so the file matches the live Deployment.

## Step 18 - rollout and rollback
- ConfigMap APP_VERSION 1.0.0 -> 1.1.0 applied: pods still answered 1.0.0 (env vars are read at
  container start; changing a ConfigMap does not restart pods).
- `kubectl annotate deployment/...` changed only Deployment metadata, not the pod template ->
  no rollout, still 1.0.0. `kubectl rollout restart` writes a timestamp into the pod template ->
  new ReplicaSet 75c6db995 (revision 3) -> 1.1.0.
- `kubectl rollout undo` -> back to ReplicaSet 7d8557c58d, renumbered revision 2 -> **4**
  (history shows 1,3,4). The pod still answered **1.1.0**.
- **What rollout undo did not revert:** the ConfigMap. Undo restores the *pod template* only;
  usms-app-config is a separate object still holding 1.1.0. So rolling back a release that changed
  config + image recovers only the image. Fix: version config with the workload (immutable,
  versioned ConfigMap names such as usms-app-config-v2 referenced from the template, or a
  checksum annotation in the template), so a rollback switches config too.
- Restored ConfigMap to 1.0.0 + rollout restart -> 1.0.0, 2/2.

## Step 18 - Your turn: image update on usms-results
- `kubectl set image deployment/usms-results results=nginx:1.27`, then
  `kubectl rollout undo deployment/usms-results --to-revision=1`.
- `kubectl rollout history` afterwards shows **2 revisions (2 and 3)** - revision 1 was renumbered
  to 3 when it was rolled back to; Deployment back on nginx:1.27-alpine, 2/2.
- Pod watch (outputs/lab-07-results-roll-watch.txt): peak **4 pod objects** (2 old Running,
  1 new Running, 1 new ContainerCreating, while an old one Terminated); never fewer than 2 Ready.
- **How it differed from usms-enrolment:** in theory the default 25%/25% lets one pod be
  unavailable, but with 2 replicas Kubernetes rounds maxUnavailable *down* (25% of 2 = 0.5 -> 0)
  and maxSurge *up* (0.5 -> 1), so for 2 replicas the default behaves like enrolment's 0/+1.
  The difference only appears at 4+ replicas (25% of 4 = 1 pod allowed down).

## Incident 2 - Docker Desktop restarted again (2026-11-13 ~10:45)
- Same pattern: context flipped to `docker-desktop`, DSO202 kind cluster auto-restarted, k3s down.
  My first Step 19 command ran against docker-desktop and failed NotFound (nothing changed there).
- DSO202 stopped and `docker update --restart=no` applied; k3s brought back with the same
  placeholder-IP fix. All state survived. From here every kubectl call pins `--context usms-eks`.
- On restart usms-gateway crash-looped 4 times (`host not found in upstream`) because it started
  before the backend Services' endpoints were ready - Troubleshooting entry 3 seen for real; it
  recovered on its own once the backends were Ready.

## Step 19 - three failures, diagnosed (full output in outputs/lab-07-failure{1,2,3}.txt)
| Failure | Trigger | `get pods` | Diagnosis came from | Message |
|---|---|---|---|---|
| ImagePullBackOff | `set image ... nginx:this-tag-does-not-exist` | new pod 0/1 ImagePullBackOff, **both old pods still 1/1 Running** | `describe` Events | `Failed to pull image ... not found` -> ErrImagePull -> ImagePullBackOff |
| Pending | Pod requesting cpu 64, memory 256Gi | Pending | `describe` Events | `FailedScheduling 0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory` |
| CrashLoopBackOff | busybox that prints and `exit 1` | CrashLoopBackOff, restarts climbing | `logs --previous` + `describe` Last State | `fatal: no database configured`, Exit Code 1 |

- **Why describe before logs:** in the first two cases the container never started, so `kubectl logs`
  has nothing to show - the reason is in the Events at the bottom of `describe`. Only when the
  container did start (CrashLoopBackOff) does `logs` (and `--previous` for the last crashed run) help.
- ImagePullBackOff never reached users: the rolling update creates the new pod first and only removes
  old ones after the new one is Ready, so a broken image stalls the rollout instead of breaking service.
  Fixed with `rollout undo`.
- All three temporary objects deleted; usms-results back to 2/2 on nginx:1.27-alpine.

## Step 20 - ECS and Kubernetes, compared with both running
Observed (outputs/lab-07-ecs-vs-eks.txt): ECS usms-enrolment-svc desired 2 / running 2, task
definition usms-enrolment:2, 1 load balancer; EKS usms-enrolment 2/2, usms-results 2/2,
usms-gateway 1/1, three ClusterIP Services, no external address.

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | Task definition revision (`usms-enrolment:2`), registered via the AWS API | Pod template inside the Deployment manifest (`spec.template`), in a YAML file in Git |
| What keeps N copies alive? | The ECS service scheduler (`desiredCount: 2`) | The ReplicaSet controller, owned by the Deployment (`replicas: 2`) |
| What gives it a stable name? | The ALB DNS name / target group (Lab 05); optionally Cloud Map | A Service: stable ClusterIP + DNS name `usms-enrolment.usms.svc.cluster.local` from CoreDNS |
| How does another service find it? | Through the ALB (or Service Connect / Cloud Map) - an AWS resource | By DNS name; kube-proxy maps the ClusterIP to current Ready endpoints (Step 16) |
| What does a rolling update create? | A new ECS *deployment* pointing at a new task-definition revision | A new ReplicaSet (new pod-template-hash), old one scaled to 0 and kept |
| Where does rollback state live? | Old task-definition revisions in ECS; you redeploy an old revision | Old ReplicaSets kept up to `revisionHistoryLimit` (5); `rollout undo` scales one back up |
| Which IAM role does the app code use? | The task role `usms-ecs-task-role` - per task, scoped to that service | Here: the node role `usms-eks-node-role`, shared by every pod on the node. Properly: IRSA / Pod Identity per ServiceAccount (Step 21) |
| What would I have to change to move to another cloud? | Nearly everything - task definitions, services, ALB, IAM are all AWS-only APIs | Manifests move almost unchanged; but IAM roles, the VPC/subnets, the node group, LoadBalancer annotations and IRSA wiring are AWS-specific and must be rebuilt |

**Which one I would choose for USMS, and why:** ECS on Fargate. USMS is a small team, in one
region, with a few stateless services, and it has no portability requirement; ECS gave me a working,
load-balanced, autoscaled service with no nodes to patch, no second control plane to keep healthy
(this lab's k3s cluster went down twice), and per-task IAM roles out of the box. Kubernetes' strengths
- portable manifests and a rich ecosystem - would only pay off if USMS grew into many services or
needed to run outside AWS.

## Step 21 - IRSA (output: outputs/lab-07-irsa.txt)
- Issuer: https://oidc.eks.us-east-1.amazonaws.com/id/9BFF35DA75EC413BB0A5FB75DF1E6EFD (my build DOES return one).
- `aws iam create-open-id-connect-provider` succeeded:
  arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/9BFF35DA75EC413BB0A5FB75DF1E6EFD
- But the discovery document `<issuer>/.well-known/openid-configuration` returns **HTTP 404** - the
  URL is a realistic-looking name Floci generated, not a document anyone (including STS) can fetch.
- ServiceAccount usms-enrolment-sa created from manifests/lab-07/60-serviceaccount.yaml (not annotated -
  there is no role to point it at yet).
- Of the six IRSA steps: **completed 1 (issuer exists, as a string) and 2 (provider registered in IAM,
  stored only)**; created the object for step 4 (ServiceAccount) without the annotation; steps 3, 5, 6
  (web-identity role, webhook-injected token, AssumeRoleWithWebIdentity) are **conceptual only** - no
  token could ever be validated against a 404 discovery document. I did not configure IRSA; I traced
  the trust chain and recorded how far this build goes.

## Step 22 - persistence
- Before: outputs/lab-07-before-restart.txt; `floci-down.sh` (docker compose stop) + `floci-up.sh`.
- After: cluster re-derived from `eks list-clusters`, node group from `eks list-nodegroups` (not shell
  variables), both ACTIVE; namespace Active; Deployments 2/1/2; Services kept the same ClusterIPs;
  4 usms ConfigMaps + 1 Secret present. diff -> **PERSISTENCE PROVEN - identical before and after**.
  Storage mode confirmed hybrid.
- Observation: stopping Floci did NOT stop the k3s container (it kept running, so the k3s IP problem
  from the two Docker restarts did not occur). Floci persists the eks API objects; the Kubernetes
  objects persist in the k3s container's own volume. The two halves survive independently.

## Step 23 - configs/lab-07.env
21 exports, "all values populated", lb_ports=8081,8082 (Path A, so no empty values expected).

## Section 8 - verification
- `./scripts/utilities/verify-lab-07.sh` -> **PASS=30 FAIL=0** (Path A, so no expected failures).
- Two local changes to the guide's script, both deliberate:
  1. every kubectl call is pinned to `--context usms-eks`, because Docker Desktop flips the current
     context to docker-desktop on every restart (seen twice in this lab) and the checks would
     otherwise query the wrong cluster;
  2. the "no secret is tracked by git" check ignores `outputs/.gitkeep`, which the .gitignore
     deliberately re-includes (`!outputs/.gitkeep`) - the guide's version would always FAIL on it.
- Smoke test through the gateway: three JSON documents, SMOKE TEST PASSED.
- scripts/cleanup/lab-07-cleanup.sh written, `bash -n` -> valid syntax, **NOT run**.

## Step 24 - Git hygiene
- `git check-ignore -v outputs/lab-07-support-probe.txt` -> `.gitignore:8:outputs/*` - the rule that
  protects every outputs/ file (including outputs/lab-07-secret.yaml and the base64 Secret in it).
- `git ls-files outputs/` -> only `outputs/.gitkeep`.
- The Secret manifest was never in manifests/, so nothing secret is staged.

## Exercise 5 Part 3 - which configs/lab-07.env variables Lab 08 needs, and why
- `USMS_EKS_CLUSTER` - every `aws eks` call in Lab 08 and the kubeconfig/context it re-creates.
- `USMS_EKS_NODEGROUP` - `aws eks update-nodegroup-config` (Lab 08 Step 10) scales the data plane from the AWS side.
- `USMS_EKS_NAMESPACE` - every `kubectl` call; Lab 08 works only inside `usms`.
- `USMS_EKS_LB_PORTS` - the host ports (8081,8082) a LoadBalancer Service/Ingress can publish on; without
  the tag Lab 08 Step 15 has nothing to reach and the cluster would have to be recreated.
- `USMS_EKS_ENDPOINT` - to confirm kubectl points at the right API server (https://localhost:6500) after a
  restart - directly relevant here, since Docker Desktop kept flipping my context.
- `USMS_K8S_DEPLOY_ENROLMENT` - the Deployment the HorizontalPodAutoscaler targets.
- `USMS_K8S_CPU_REQUEST` (50m) - the HPA divides measured CPU by this; Part 1 measured 1m = 2% at idle,
  so I can check the HPA's arithmetic rather than trust it.
- `USMS_K8S_DEPLOY_GATEWAY` / `USMS_K8S_SVC_GATEWAY` - the gateway is what Lab 08 exposes
  (port-forward -> NodePort -> LoadBalancer -> Ingress).
- Not needed by Lab 08 directly: the role/policy ARNs and the SG (Lab 09's least-privilege review uses
  them), the results Deployment/Service names, and the manifest dir (useful for re-applying after a crash).

---

# Section 14 - Review Questions

### 1. ACTIVE cluster, every pod Pending
`ACTIVE` describes only the **control plane** - the API server, etcd, scheduler and controllers that AWS
runs. It says nothing about the **data plane**, the worker nodes where pods actually run. The scheduler is
working (that's why the pods exist and are `Pending` rather than missing), but it has nowhere valid to
put them. Two configurations that produce exactly this:
(a) **no node group, or nodes that never joined** - e.g. a node role missing `eks:DescribeCluster`, or a
node role that trusts `eks.amazonaws.com` instead of `ec2.amazonaws.com`, so instances boot but never
register; `kubectl get nodes` is empty or shows only a tainted control-plane node.
(b) **nodes exist but cannot fit the pods** - requests larger than any node (my `usms-toobig`:
"0/1 nodes are available: Insufficient cpu, Insufficient memory"), a `nodeSelector` such as
`workload=usms` matching no node label, an untolerated taint, or a cordoned node (Exercise 4: "1 node(s)
were unschedulable"). In every case `kubectl describe pod` → Events → `FailedScheduling` names the reason.

### 2. Swapping the two trust policies
The cluster role would trust `ec2.amazonaws.com` and the node role would trust `eks.amazonaws.com`.
On real AWS the first failure is at **Step 8, `create-cluster`**: EKS must assume the cluster role to create
the control-plane ENIs in my subnets, and the role does not trust `eks.amazonaws.com`, so the call is
rejected (or the cluster goes `FAILED`). If that were somehow fixed alone, **Step 10/11** fails next:
the node instances cannot assume a role that only trusts `eks.amazonaws.com`, so they get no credentials,
the kubelet cannot call `eks:DescribeCluster` or pull from ECR, and the node group stays `CREATING`/
`DEGRADED` with zero `Ready` nodes - `kubectl get nodes` is empty. On Floci I would notice **nowhere**:
Floci stores trust and permission policies but never evaluates them, so every step succeeds. That is
why the lab checks the trust principal explicitly (`verify-lab-07.sh` tests both).

### 3. Readiness probe vs liveness probe
**Readiness** answers "should this pod receive traffic right now?" - failing it removes the pod from the
Service's endpoints but leaves the container running. **Liveness** answers "is this container wedged
beyond recovery?" - failing it makes the kubelet kill and restart the container.
Getting it backwards, concretely: put a check that depends on load or on the database (e.g. `/ready`
that times out when the DB is slow) on the **liveness** probe. During enrolment week the DB slows down, the
probe times out, Kubernetes restarts every enrolment pod; restarted pods hit the DB with cold caches,
time out again, and the service goes into a restart storm - a slowdown becomes a full outage. The right
design is: dependency/load checks on readiness (shed traffic, recover by itself), and liveness only on a
cheap local check like my `/healthz`. Exercise 3 shows the other side: a readiness probe pointing at a
path that 404s silently keeps pods out of the Service forever while they look `Running`.

### 4. Rollback that still reports 1.1.0
`kubectl rollout undo` restores the previous **pod template** - image, env wiring, probes - by scaling an
old ReplicaSet back up. The value `APP_VERSION` was not in the pod template; it came from the
**ConfigMap** `usms-app-config` via `envFrom`, and the ConfigMap is a separate object that undo does not
touch. The old template plus the still-new ConfigMap = 1.1.0.
I'd argue the statement is **half true**: Kubernetes rollback is a real, fast, reliable rollback of the
*workload definition*, but it is not a rollback of the *release* if the release also changed config,
Secrets or anything outside the template. The practice that resolves it is **versioning configuration
with the workload**: immutable, versioned ConfigMaps (e.g. `usms-app-config-v2`, or a content hash in the
name as Kustomize's configMapGenerator does) referenced from the pod template - then changing config
changes the template, creates a new ReplicaSet, and `rollout undo` switches the config back too. Keeping
manifests in Git and rolling back by re-applying a previous commit (GitOps) achieves the same.

### 5. maxUnavailable: 0 vs the default 25%/25%
`usms-enrolment` (maxUnavailable 0, maxSurge 1) always keeps 2 ready pods: it adds a third, waits for it
to be Ready, then removes an old one - capacity never drops, at the cost of needing room for one extra pod.
The default 25%/25% is *intended* to allow some unavailability, but percentages are rounded:
maxUnavailable rounds **down** (25% of 2 = 0.5 → 0) and maxSurge rounds **up** (0.5 → 1), so with only
2 replicas it behaves the same as enrolment - which is what I observed (peak 4 pod objects, never below
2 Ready). The difference appears from 4 replicas (1 pod may go down).
Suited to `maxUnavailable: 0`: a user-facing service at peak where every pod is needed - enrolment during
registration week. Suited to the default (or higher maxUnavailable): background or batch-like services,
or clusters with no spare capacity to surge into, where a faster rollout matters more than full capacity.
Lab 04's ECS configuration (`minimumHealthyPercent 100`, `maximumPercent 200`) is the equivalent of
**maxUnavailable: 0** - never go below desired, surge above it.

### 6. "A Secret is encrypted, so it's fine to commit the manifest"
That is wrong. In Step 17 I ran `kubectl get secret ... -o jsonpath='{.data.ENROLMENT_API_TOKEN}' | base64 -d`
and got `floci-dummy-token-not-a-real-secret` back with no key at all - **base64 is an encoding, not
encryption**. A committed Secret manifest is a plaintext credential in Git history forever.
What a Secret *does* provide: it keeps the value out of the image and out of the Deployment spec, can be
restricted separately with RBAC (who may `get secrets`), is not shown by `kubectl describe`, and is
delivered to the pod as an env var or a file. What it does *not* provide: confidentiality at rest (etcd
stores it as base64 unless encryption is configured), protection from anyone with `get secret` on the
namespace, or protection inside the container (`printenv` shows it in plain text).
On real EKS I would: never commit Secret manifests (I generated mine into the git-ignored `outputs/`);
enable **KMS envelope encryption** of Secrets at cluster creation; keep the real value in **AWS Secrets
Manager** and sync it in (External Secrets Operator / Secrets Store CSI driver) or have the app read it
using **IRSA / Pod Identity**; and lock down `get secrets` with RBAC.

### 7. ECS or Kubernetes for USMS
For USMS - a small team, one region, a few stateless services, quiet for eight months and very busy for
two - I would choose **ECS on Fargate**. Things this lab made harder than Lab 04:
- **Two systems to operate instead of one.** Every step was either `aws eks` or `kubectl`, with separate
  endpoints, credentials and contexts; my kubectl context silently switched clusters twice.
- **I own a data plane.** A node group, a node IAM role separate from the cluster role, node upgrades,
  and - locally - a control-plane container that crashed under memory pressure and refused to restart
  after an IP change. With Fargate there were no nodes at all.
- **IAM per workload is harder.** ECS gave each task a task role directly; on EKS the simple path (node
  role) shares permissions with every pod on the node, and the correct path (IRSA) needs an OIDC provider,
  a web-identity trust policy and an annotated ServiceAccount - which my build could not complete.
- More YAML and more concepts (Deployments, ReplicaSets, Services, ConfigMaps, probes, PDBs).
What Kubernetes gave me that ECS could not: **built-in service discovery by DNS name** for many small
services with no load balancer between them (the gateway routes to `usms-enrolment.usms.svc.cluster.local`
with zero AWS resources), **portable declarative manifests** that would run unchanged on any conformant
cluster, and fine-grained controls such as PodDisruptionBudgets and topology spread (Exercise 4).
The two-month peak is handled well by either (Lab 06's ECS autoscaling vs Lab 08's HPA), so for a team
this size the lower operational cost of ECS wins; I would revisit if USMS grew to many services or needed
to leave AWS.
