# Lab 08 Notes - EKS Scaling and Service Exposure

## Step 1 - starting state (2026-11-15T11:20:12Z)
- Support path still **PATH A**; verify-lab-07.sh PASS=30 FAIL=0.
- usms-enrolment CPU request present: {"cpu":"50m","memory":"32Mi"}.
- Cluster tag _lb_ports_ = 8081,8082 (from the API and from configs/lab-07.env).
- Differences from the guide's expected baseline, carried over from Lab 07 exercises:
  a fourth Deployment/Service **usms-timetable** (Lab 07 Ex 1), a /timetable/ gateway route (Ex 2),
  and an existing **usms-enrolment-pdb (minAvailable 1)** plus topology spread / anti-affinity on
  usms-enrolment (Ex 4). Step 12 will redefine usms-enrolment-pdb as maxUnavailable 1.
- Cluster has **1 node** (k3s v1.34.1, 8 CPU reported = the whole Docker VM).

## Step 3 - Your turn: usms-enrolment needs 10x its current traffic
I would go in this order. **(1) Horizontal workload first:** raise replicas (via the HPA's
maxReplicas, not by hand) because it is instant and needs no new infrastructure; then check
`kubectl get pods` for anything `Pending` and `kubectl top` to confirm load per pod falls.
**(3) Horizontal infrastructure next:** as soon as pods go Pending with "Insufficient cpu", raise the
node group's desiredSize/maxSize (or let a Cluster Autoscaler/Karpenter do it); check that new nodes
reach `Ready` and the Pending pods schedule. **(2) Vertical workload** only if one pod is the
bottleneck (e.g. it is CPU-throttled at its limit even with plenty of replicas) - it restarts every
pod and changes the HPA's denominator, so re-check the HPA percentages afterwards.
**(4) Vertical infrastructure last**, only if pods no longer fit on the current instance type: it cannot
be changed in place, so it means a new node group, cordon/drain of the old one, then deletion.

## Step 4 - scale by hand (outputs/lab-08-step4.txt)
- `kubectl scale --replicas=5`: the **same ReplicaSet** (5b64544787) went 2 -> 5; no new ReplicaSet, no
  rollout, because only `spec.replicas` changed, not the pod template.
- Watcher: new pods went Pending -> ContainerCreating -> Running **0/1** -> **1/1**; the endpoint list
  grew only at 1/1 (readiness), not at start.
- 40 requests through the unchanged gateway were answered by **all 5 pods** (12/9/9/5/5).
- Scaled back to 2; endpoints back to 2 addresses.

## Step 5 - drift (outputs/lab-08-step5.txt)
- Cluster 6, file `replicas: 2` -> `kubectl apply` of the file silently put it back to **2**.
- `kubectl diff` showed `- replicas: 2 / + replicas: 3` and exited **1** (= "there is a difference",
  not an error). Restored to 2; `kubectl diff` now exits 0; no .bak files left.

## Step 6 - requests, limits, QoS (outputs/lab-08-step6.txt)
- All six app pods are **Burstable** (requests 50m/32Mi < limits 200m/128Mi).
- Node b5986361ebbf: Capacity = Allocatable = 8 CPU / ~3.8 GiB here (k3s reserves nothing by default;
  on EKS allocatable is lower because the kubelet and system reserve CPU/memory). Allocated requests
  500m (6%), limits 1200m (15%) - the scheduler counts *requests*, not real usage.
- Denominator: HPA target 50% = 50% of the 50m request = 25m average per pod - not 50% of a node,
  not 50% of the 200m limit.

### Your turn - gateway Burstable -> Guaranteed -> Burstable
- `kubectl set resources deployment/usms-gateway --requests=cpu=200m,memory=128Mi --limits=cpu=200m,memory=128Mi`
  -> QoS **Guaranteed** (requests = limits for CPU and memory); same ceiling, so it can do exactly what it
  could before, but now reserves the full 200m/128Mi.
- Set back to 50m/32Mi requests -> **Burstable**; `kubectl diff -f manifests/lab-07/40-gateway.yaml` exit 0.
- The pod was **REPLACED each time** (ReplicaSet 54df9d9ccc -> 66854647bf -> back to 54df9d9ccc), not
  adjusted: requests/limits are part of the pod template, and a running container's resources are fixed
  at creation, so changing them (dimension 2, vertical) means a rollout. That restart cost is why the
  VerticalPodAutoscaler is used far less than the HPA.
- When I would want Guaranteed: a latency-critical or stateful pod (e.g. a database or the gateway in
  enrolment week) that must be the last thing evicted under node memory pressure and must never be
  CPU-starved by noisy neighbours - accepting that it reserves its full limit.

## Step 7 - metrics pipeline
- `v1beta1.metrics.k8s.io kube-system/metrics-server True`, metrics-server 1/1, **metrics API: AVAILABLE**
  (k3s ships it). No install and no `--kubelet-insecure-tls` needed.
- Idle: node 337m (4%); every app pod **1m** = 2% of the 50m request.

## Step 8 - HPA (manifests/lab-08/10-hpa-enrolment.yaml)
- autoscaling/v2, min 2, max 8, cpu 50%, behavior: scaleUp window 0 + Percent 100 / Pods 2 per 15s
  (selectPolicy Max); scaleDown window 300s + 1 pod per 60s (selectPolicy Min).
- First read `cpu: <unknown>/50%` with REPLICAS 0 in the first seconds (expected), then
  `cpu: 2%/50%`, REPLICAS 2. Conditions: `ScalingActive True ValidMetricFound "the HPA was able to
  successfully calculate a replica count from cpu resource utilization (percentage of request)"`.
- Worked example: 2 pods at 40m -> 40/50 = 80% -> ceil(2 x 80/50) = ceil(3.2) = **4**.

## Step 9 - load (outputs/lab-08-hpa-watch.txt)
- With the guide's usms-loadgen (3 replicas, wget via the gateway's DNS name) CPU only reached
  **6-39%** of request for ~8 minutes - **never above 50%, so the HPA correctly did nothing**.
  Raising usms-loadgen to 8 made it *worse* (enrolment ~5m), while the node sat at 5% CPU.
- Diagnosis with `kubectl top`: **CoreDNS was the bottleneck at 119m** - every `wget` starts a new
  process that resolves `usms-gateway.usms.svc.cluster.local` before connecting, so the load
  generators were mostly waiting on DNS, not loading enrolment.
- Fix (deviation from the guide, recorded honestly): an extra pod `usms-burst2` running 8 parallel
  wget loops against the enrolment Service's **ClusterIP** (10.43.205.69) - no DNS lookup per request.
  The usms-loadgen manifest itself is unchanged.
- Result: `27% -> 39% -> 96% -> 196%/50%` and replicas **2 -> 4** (11:45:07), then `292%/50%` and
  **4 -> 8** within ~15 s (maxReplicas). Arithmetic: at 196% on 2 pods, ceil(2 x 196/50) = 8, but
  scale-up policies allow at most +100% or +2 per 15 s (Max of the two = +2 at 2 replicas) -> 4;
  next period at 4 replicas Percent 100 allows +4 -> 8, clamped to maxReplicas 8.

## Step 10 - scale the data plane from the AWS side (outputs/lab-08-step10.txt)
- Before: usms-eks-nodes ACTIVE, min 2 / max 4 / desired 2, t3.small, private-a + private-b,
  labels workload=usms tier=app.
- `aws eks update-nodegroup-config --scaling-config minSize=2,maxSize=6,desiredSize=3` **FAILED**
  (exit 254): `An error occurred (400) when calling the UpdateNodegroupConfig operation:
  <Error><Code>InvalidArgument</Code><Message>POST requires either ?uploads, ?uploadId, ?restore or
  ?select parameter.</Message></Error>`. `aws eks list-updates` likewise returned an S3
  `NoSuchBucket` error - Floci is routing these EKS paths to its **S3** handler, i.e. the operation
  is not emulated. Readback unchanged: min 2 / max 4 / desired 2.
- Floci image: floci/floci:latest, version label **1.7.0** (the course's Known Issues page describes
  this same failure for Floci 2.0.1: https://norbutlepcha25.github.io/dso303/Lab/known-issues.html#lab-08-eks-scaling).
  Per that page this is an emulator capability gap, not an environment fault; I did not rebuild anything.
- Documented alternative = "the Lab 8 HPA drill (pod scaling)" - which Step 9 already performed
  (load -> replicas 2 -> 4 -> 8 -> back to 2 after the 300 s window). **What it proves:** load changes
  pod replicas. **What it does not prove:** that nodes are added - the managed node-group API is not
  emulated, and this cluster has one k3s node regardless of desiredSize.
- Kubernetes side: 1 node, and it does **not** carry the node group's `workload` label (LABELS <none>) -
  the node group's labels never reached the node. Step 11 Part 2 applies them by hand.
- On real AWS: the call returns an asynchronous Update object (InProgress); the ASG would launch a third
  t3.small, it would join as Ready within minutes, and only then would Pending pods schedule.
  Raising replicas (HPA) and raising desiredSize are different APIs and nothing connects them unless a
  Cluster Autoscaler or Karpenter is installed.
- Removed all load at 11:47:01 (usms-loadgen -> 0, burst pod deleted). CPU fell to **2%** by 11:48:17,
  but replicas **held at 8 until 11:52:54** (~5 min = stabilizationWindowSeconds 300), then dropped
  **exactly one per minute** (Pods 1 per 60s, selectPolicy Min): 7, 6, 5, 4, 3, **2 at 11:58:03**.
- HPA events, verbatim (outputs/lab-08-hpa-events.txt):
  - `New size: 4; reason: cpu resource utilization (percentage of request) above target`
  - `New size: 8; reason: cpu resource utilization (percentage of request) above target`
  - `New size: 7; reason: All metrics below target` ... `New size: 2; reason: All metrics below target`
- Final conditions: `ScalingLimited True TooFewReplicas "the desired replica count is less than the
  minimum replica count"` - at 2% load the formula wants 1 pod, minReplicas 2 holds it at 2.
- usms-loadgen left at 0 replicas (still present, as the guide requires for Step 12); deleted in Section 15.

## Step 11 - Cluster Autoscaler / Karpenter, and a nodeSelector (outputs/lab-08-step11.txt)
- **Cluster Autoscaler** watches for Pending pods and raises the desired capacity of an Auto Scaling group
  you pre-declared (one node group per instance shape), then waits for EKS to add a node - minutes.
- **Karpenter** watches the same Pending pods but launches EC2 instances directly, choosing an instance
  type that fits them (from a NodePool's constraints) - typically under a minute, better bin-packing.
- Neither is installed: both need IRSA (Lab 07 Step 21 - not available here), and CA needs a real tagged
  ASG (Step 10 showed the node group API is not even writable). Conceptual / Real AWS.
- Part 1: `node group labels did not reach the nodes` - the k3s node had no workload/tier label.
  Part 2: labelled by hand: `kubectl label node b5986361ebbf workload=usms tier=app` (on real EKS the
  managed node group puts these labels on every node it launches).
- Part 3: nodeSelector `workload: usms` -> new ReplicaSet 6dc98c655f, 2/2 Running on the labelled node.
- Part 4 (enforcement proven): nodeSelector `workload: nonexistent` -> new pod **Pending**,
  `FailedScheduling 0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector`,
  while **both old pods stayed 1/1 Running** - maxUnavailable 0 stopped the roll. Stuck, not broken.
- Part 5: back to `workload: usms`, 2/2. Added the nodeSelector to manifests/lab-07/20-enrolment.yaml;
  `kubectl diff` exit 0 = repository matches cluster.

## Step 12 - PodDisruptionBudgets (outputs/lab-08-step12.txt)
- Clash resolved: Lab 07 Exercise 4 had put `usms-enrolment-pdb` (minAvailable 1) inside
  manifests/lab-07/20-enrolment.yaml. Step 12 redefines the same object as maxUnavailable 1, so I moved
  ownership to manifests/lab-08/30-pdb-gateway.yaml and removed it from the Lab 07 file - one object,
  one file, otherwise whichever file was applied last would silently win (Step 5's lesson).
- `kubectl get pdb`: usms-gateway-pdb minAvailable 1 -> **ALLOWED DISRUPTIONS 0** (single replica: it can be
  highly available or drainable, not both - Exercise 2); usms-enrolment-pdb maxUnavailable 1 ->
  **ALLOWED DISRUPTIONS 1** (scales with the HPA's replica count). minAvailable for a fixed floor,
  maxUnavailable when the count moves.
- Eviction API on the gateway pod: `Error from server (TooManyRequests): Cannot evict pod as it would
  violate the pod's disruption budget.` - the PDB working.
- `kubectl delete pod` on the same pod: deleted immediately and replaced - the PDB said nothing. A plain
  delete does not go through the eviction API; a PDB constrains a cooperative process, it is not a lock.
- `kubectl drain --dry-run=client`: would evict gateway, both results pods and timetable; nothing was
  actually drained, the node stayed Ready (not cordoned).

## Step 13 - ClusterIP and port-forward (outputs/lab-08-step13.txt)
- `curl http://10.43.23.149/` from the Mac: no answer - **a ClusterIP is not routable from the host**.
- `kubectl port-forward svc/usms-gateway 18080:80` -> `/`, `/enrolment/`, `/results/` all answered.
- 6 requests through the tunnel were **all** answered by `usms-gateway-54df9d9ccc-9h56z`.
- Why it is debugging-only: (1) it is a single tunnel to **one pod** chosen when it starts - no load
  balancing, no failover; (2) it exists only while that command runs on my machine, and every byte goes
  through the API server (control plane), so it is neither available nor scalable.

## Step 14 - NodePort (outputs/lab-08-step14.txt)
- usms-results-np: `NodePort 10.43.151.96 80:30080/TCP` - a **second** Service selecting the **same pods**
  as usms-results (which is unchanged, still ClusterIP 10.43.37.121).
- Through the node's InternalIP 172.17.0.3:30080 from inside the cluster: 4 JSON answers from **both**
  results pods (lm95f x3, s5h2f x1) - kube-proxy forwards from the node port to any ready pod.
- "Every node answers, including nodes with no pods": this cluster has **one node**, so I could only show
  the one node. With two nodes the same port would answer on both, and a node hosting no results pod
  would still forward the request.
- From the Mac `localhost:30080`: no answer. `docker port` on the k3s container shows only
  `6443/tcp -> 0.0.0.0:6500` - 30080 was never published (Floci Limitation). Fallback
  `kubectl port-forward svc/usms-results-np 30080:80` worked - this proves the **Service** works, **not**
  that the NodePort is externally reachable.

## Step 15 - LoadBalancer (outputs/lab-08-step15.txt)
- Re-applied a **full** Service manifest (manifests/lab-08/50-service-loadbalancer.yaml), not a patch.
- `<pending>` for ~10 s, then **EXTERNAL-IP 172.17.0.3**: k3s's built-in ServiceLB (klipper) created
  DaemonSet `svclb-usms-gateway-...` (events: EnsuringLoadBalancer -> AppliedDaemonSet ->
  `Updated LoadBalancer with new IPs: [] -> [172.17.0.3]`). Observed, not just recorded.
- The ladder on one line: `type=LoadBalancer  clusterIP=10.43.23.149  nodePort=32712  external=172.17.0.3`
  - a LoadBalancer Service still has a nodePort (auto-allocated 32712) and a clusterIP.
- `wget http://172.17.0.3/` from inside the cluster -> gateway JSON. From the Mac, **8081 and 8082 do not
  answer** and nothing listens on them: on this build the `_lb_ports_` tag did not cause any host port to be
  published (only 6500 is published). So the LB address is reachable inside Docker's network only.
- The three annotations (inert here): `aws-load-balancer-type: external` = use the AWS Load Balancer
  Controller, not the legacy in-tree provider; `aws-load-balancer-nlb-target-type: ip` = register **pod IPs**
  as NLB targets, skipping the NodePort hop - **identical to Lab 05's target group `--target-type ip`**, for
  the same reason (a pod, like a Fargate task, has its own VPC address); `aws-load-balancer-scheme:
  internet-facing` = place the NLB in the two **public** subnets from Lab 02, as Lab 05's ALB was.
- On real EKS: an NLB named like `k8s-usms-usmsgat-....elb.us-east-1.amazonaws.com`, one per Service,
  billed per hour.

## Step 16 - Ingress (outputs/lab-08-step16.txt) - Conceptual on this build
- `no IngressClass registered`, `no ingress controller pod found`: Floci starts k3s with
  `--disable=traefik`, so the default k3s controller is switched off.
- `usms-portal-ingress` applied: CLASS `<none>`, ADDRESS empty, Events `<none>`; describe shows the
  three rules resolving to the right endpoints (/enrolment -> 10.42.0.102/103, /results -> .48/.49,
  / -> .104). **A valid, stored, correct object with nothing acting on it.** 8081 did not answer.
- Matching: `pathType: Prefix` matches whole path segments and the **longest matching prefix wins**
  regardless of order (`/enrolment/x` -> usms-enrolment even though `/` also matches). Lab 05's ALB
  instead chose between rules by **numeric priority** (`create-rule --priority 10`), lowest first.

### Written alternative: which four `aws elbv2` commands would the AWS Load Balancer Controller run, in order?
1. `aws elbv2 create-load-balancer --type application --scheme internet-facing --subnets <public-a>
   <public-b> --security-groups ...` - from `scheme: internet-facing` (and the subnet tags).
2. `aws elbv2 create-target-group --target-type ip --protocol HTTP --port 80 --vpc-id ...
   --health-check-path /healthz` - **one per backend Service** (enrolment, results, gateway), from
   `target-type: ip` and `healthcheck-path`; then `register-targets` with the **pod IPs** from each Service's
   endpoints, kept in sync as pods come and go (the controller watches Endpoints).
3. `aws elbv2 create-listener --protocol HTTP --port 80 --default-actions ...` - from
   `listen-ports: [{"HTTP": 80}]`.
4. `aws elbv2 create-rule --listener-arn ... --priority N --conditions Field=path-pattern,Values=/enrolment*
   --actions Type=forward,TargetGroupArn=...` - one rule per path in `spec.rules[].http.paths[]`, the
   controller assigning priorities so the longer prefixes are evaluated first; `alb.ingress.../tags` become
   `add-tags`. Exactly what I did by hand in Lab 05 - and ten paths are still **one** ALB.

## Step 17 - Practical 2 and Practical 4, compared with both running (outputs/lab-08-ecs-vs-eks.txt)
Observed: ECS usms-enrolment-svc desired 2 / running 2 on usms-enrolment:2 behind usms-enrolment-tg
(target type ip); scalable target service/usms-ecs-cluster/usms-enrolment-svc min 2 max 10; policies
cpu-target-tracking (50, in 300 s / out 60 s, **2 alarms**), requests-target-tracking (1000, 2 alarms),
queue-step-out (StepScaling); one listener rule at priority 10. EKS: usms-enrolment 2/2 with
usms-enrolment-hpa (2-8, cpu 2%/50%), usms-gateway LoadBalancer 172.17.0.3, usms-results-np NodePort 30080,
usms-portal-ingress (no class, no address), two PDBs.

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | The ECS service's `desiredCount` | The Deployment's `spec.replicas` |
| Who writes it? | Application Auto Scaling, via the scalable target `service/usms-ecs-cluster/usms-enrolment-svc` | The HPA controller (`usms-enrolment-hpa`) |
| Where does that thing run? | An AWS regional service, outside anything I own or can see | Inside the cluster's kube-controller-manager (on EKS, in the AWS-run control plane; here, in my k3s container) |
| Where does the metric come from? | CloudWatch `ECSServiceAverageCPUUtilization` (and ALB RequestCountPerTarget), pushed by ECS/ALB | metrics.k8s.io from metrics-server, which scrapes each kubelet every ~15 s |
| What does "50% CPU" mean - 50% of what? | 50% of the CPU units **reserved by the task** (task-level cpu) | 50% of the **container's CPU request** (50m -> 25m average); not the node, not the limit |
| How is scale-in slowed down? | `ScaleInCooldown: 300` on the policy | `behavior.scaleDown.stabilizationWindowSeconds: 300` + a rate policy (1 pod / 60 s) - observed 8 held for ~5 min, then -1 per minute |
| What happens if there is no capacity for the new instance/pod? | On Fargate effectively never - AWS supplies capacity per task (quotas aside) | Pods sit `Pending` until a node is added; nothing adds one unless a Cluster Autoscaler/Karpenter is installed (Step 10 could not even set desiredSize here) |
| What creates the alarms, if anything? | Application Auto Scaling creates **two CloudWatch alarms per target-tracking policy** for me (2 + 2 observed) | Nothing - **no alarms**; the controller polls the metrics API every 15 s |

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | Several, one command each: ALB, ALB security group, target group, listener, listener rule (priority 10), plus the service's `loadBalancers` attachment and the SG cutover | **None** - one Ingress object (and one LoadBalancer Service); on real EKS the AWS Load Balancer Controller would create the ALB, target groups, listener and rules |
| What is the target type, and why? | `ip` - Fargate tasks have their own ENI/VPC address, so the ALB targets them directly | `ip` (`alb.ingress.kubernetes.io/target-type: ip`, `nlb-target-type: ip`) - with the VPC CNI each pod has a VPC address, so the LB skips the NodePort hop |
| How are targets registered and deregistered? | ECS registers/deregisters task IPs in the target group as tasks start/stop (30 s deregistration delay) | The controller watches the Service's Endpoints (only Ready pods) and registers/deregisters pod IPs; locally kube-proxy does the equivalent for ClusterIP/NodePort |
| How are competing routing rules disambiguated? | Numeric rule **priority** (lowest number wins) | **Longest matching path prefix** wins, regardless of the order written |
| What would I change to move this to another cloud? | Everything - ALB, target groups, listener, rules, ECS service attachment are AWS-only APIs | The Ingress rules and Services move unchanged; I would swap the `alb.ingress.kubernetes.io/*` / `aws-load-balancer-*` annotations and the ingress class for the other cloud's controller |
| What is the cost of exposing ten services? | One ALB can route all ten by path/host rules (if I build ten rules by hand); ten separate ALBs would be ten bills | One Ingress with ten paths = **one ALB**; ten `type: LoadBalancer` Services would be **ten NLBs, ten hourly bills** |

### Two paragraphs, in prose

1. **If the AWS control plane has a bad afternoon.** On ECS, Application Auto Scaling, CloudWatch alarms and
the ECS scheduler are all AWS-regional services: if they degrade, `desiredCount` simply stops changing and
the running tasks keep serving behind the ALB, but I can only debug through the same AWS APIs and console
that are degraded - I cannot see inside the scaler. On EKS the HPA lives in the cluster's controller manager,
so an outage of *other* AWS services (CloudWatch, Application Auto Scaling) does not affect it, and I can
still debug with `kubectl describe hpa`, `kubectl top` and events as long as the cluster API answers. But the
EKS control plane is itself AWS-run: if *it* has the bad afternoon, kubectl, the HPA and all scheduling stop
together, while already-running pods keep serving - so on EKS I keep more visibility while the API is up,
but I depend on one more AWS-operated component than with Fargate.

2. **For USMS - one small team, one region, quiet for eight months and very busy for two - I would choose ECS
on Fargate.** Practical 2 gave me CPU and request-count scaling, scheduled scaling and alarms with no
nodes to own; in Practical 4 the node group could not even be resized here, capacity has to be added by a
second loop (Cluster Autoscaler/Karpenter) that the HPA knows nothing about, and the control plane itself
went down twice when Docker restarted. The strongest argument **against** my choice: Kubernetes gave
measurably finer control - the HPA's behavior block (instant doubling, then a 5-minute hold and one pod per
minute) is more expressive than a cooldown, PDBs and nodeSelectors protect capacity during maintenance,
and one Ingress can expose many services through one load balancer with portable manifests. If USMS grows
into many services or needs to leave AWS, that argument wins.

## Step 18 - persistence (outputs/lab-08-before-restart.txt, outputs/lab-08-after-restart.txt)
- floci-down.sh (docker compose stop) + floci-up.sh. diff -> **PERSISTENCE PROVEN - scaling and exposure
  configuration identical**: HPA 2/8/50, enrolment-pdb maxUnavailable 1, gateway-pdb minAvailable 1,
  usms-results-np 30080 (pinned), usms-gateway LoadBalancer nodePort 32712, Ingress /enrolment,/results,/,
  node group 2 4 2.
- Neither "legitimate difference" appeared: the gateway's auto-allocated nodePort stayed 32712 and its
  EXTERNAL-IP stayed 172.17.0.3. Reason: stopping Floci does **not** stop the k3s container on this build
  (it stayed "Up 2 days"), so the in-cluster ServiceLB never restarted. The AWS-side objects persisted in
  Floci's hybrid storage; the Kubernetes objects in the k3s volume.

## Step 19 - configs/lab-08.env
- 19 exports. One expected empty value: `USMS_INGRESS_CLASS=` - no ingress controller (Step 16).
- Node group values are the **unchanged 2/4/2**, not 2/6/3, because update-nodegroup-config failed (Step 10) -
  the file records what is actually true.

## Section 8.1 - verify-lab-08.sh (outputs/lab-08-verify.txt)
- **PASS=33 FAIL=1.** The one failure is `node group maxSize was raised to 6` - expected and explained:
  `aws eks update-nodegroup-config` is not emulated on this Floci build (Step 10; course Known Issues page),
  so maxSize is still 4. Everything else, including the _lb_ports_ tag, passes.
- Two deliberate local changes to the guide's script, as in verify-lab-07.sh: every kubectl call is pinned
  to `--context usms-eks` (Docker Desktop flips the context on restart), and the git-hygiene check ignores
  `outputs/.gitkeep`, which .gitignore deliberately keeps tracked.
- Smoke test through the gateway: three JSON documents, SMOKE TEST PASSED.

## Exercise 5 Part 3 - ECS or Kubernetes for USMS

**Recommendation: ECS on Fargate.** USMS is one small team, one region and a handful of stateless services
that sit almost idle for eight months and then spike at enrolment. That profile rewards the platform with
the least to operate, and the two practicals made the operating cost concrete.

Three observations decide it. First, in Practical 2 one `register-scalable-target` plus two target-tracking
policies gave me scaling on CPU *and* on ALB request count, and Application Auto Scaling created the
CloudWatch alarms for me (two per policy). In Practical 4 the HPA could only scale on CPU without adding a
metrics adapter, and I had to diagnose its inputs myself: my first load test never reached the 50% target
because CoreDNS, not enrolment, was the bottleneck. Second, Fargate has no second capacity loop. On EKS the HPA
raised replicas 2 -> 8 in about 15 seconds, but only because one node had room; adding nodes is a separate
loop (node group plus Cluster Autoscaler or Karpenter, which need IRSA), and on this build
`update-nodegroup-config` could not even run. Third, the Kubernetes control plane was itself something to
keep alive: the k3s cluster went down twice when Docker restarted and needed manual repair, and every kubectl
command had to be pinned to a context. ECS never asked that of me.

**The strongest argument against my choice** is that Kubernetes gave finer, more honest control exactly
where enrolment week hurts. The HPA's `behavior` block doubled capacity every 15 seconds and then held all 8
pods for five minutes before shedding one per minute, which is more expressive than a single cooldown.
PodDisruptionBudgets refused an unsafe eviction during maintenance, and a nodeSelector kept pods off the
wrong nodes. One Ingress can expose many services through a single ALB, and the manifests are portable
off AWS. If USMS grew into a dozen services, or the university needed to run on-premises or on another
cloud, that argument would win and I would revisit the decision.

---

# Section 14 - Review Questions

### 1. "An HPA at 50% scales when the node hits 50% CPU"
Wrong. `averageUtilization: 50` means the **average CPU of the target pods is 50% of each container's CPU
request**. For usms-enrolment that is 50% of 50m, which is 25m per pod, whatever the node is doing. In Step 7 the
node was at 4% while the HPA read 2%, and in Step 9 the pods were at 292% of their request while the node was
far below 50%. If someone **halves the request** (50m to 25m) without touching the HPA, the same real usage
reads as **twice** the percentage. The HPA scales out sooner and runs **more pods for the same load**, so
there is *more* capacity in pod count. But each pod also reserves less from the scheduler, so more pods pack
onto each node and the nodes become contended. All recorded percentages stop being comparable with earlier
runs. That is why the guide says to fix capacity with replicas or nodes and never by lowering the request.

### 2. Ten times the traffic by Monday
1. **Dimension 1, horizontal workload:** raise the HPA's `maxReplicas` (8 is not enough for 10x) and let it
   scale. Check `kubectl get hpa` (percentage falling towards target) and `kubectl get pods` (any `Pending`?).
2. **Dimension 3, horizontal infrastructure:** as soon as pods go Pending with `Insufficient cpu`, raise the
   node group's `maxSize`/`desiredSize` (`update-nodegroup-config`), or install a Cluster Autoscaler or
   Karpenter so it happens by itself. Check that new nodes reach `Ready` and the Pending pods schedule.
3. **Dimension 2, vertical workload:** only if a single pod is the bottleneck (throttled at its 200m limit
   even with many replicas). Raise requests/limits, accept that every pod restarts, and re-check the HPA,
   because its denominator has changed.
4. **Dimension 4, vertical infrastructure, cannot change in place.** `instanceTypes` cannot be edited on a
   node group, so create a **new node group** with bigger instances, wait for it to be Ready, cordon and drain
   the old one (PDBs keep enrolment serving), then delete it. Plan this one before Monday, not on Monday.

### 3. Application Auto Scaling (outside) vs the HPA (inside)
- **Failure:** Application Auto Scaling and its CloudWatch alarms are AWS regional services. If my workload,
  or even my whole ECS service, is unhealthy, the scaler itself is unaffected. But if *those* services
  degrade, `desiredCount` freezes and I can only debug through the same AWS APIs. The HPA runs in the
  cluster's controller manager and reads metrics-server *inside the cluster*. If metrics-server, CoreDNS or
  the control plane is unhealthy, scaling stops (`<unknown>`), but I can debug it directly with
  `kubectl describe hpa`.
- **Blast radius and coupling:** the HPA's view is only what the cluster can see (CPU/memory unless I add an
  adapter), and it shares failure with the cluster. In Step 9 my own load test was throttled by an in-cluster
  component, CoreDNS. Application Auto Scaling scales on any CloudWatch metric, including ALB requests per
  target and queue depth, with no extra component in my workload's path.

### 4. 4 -> 8 replicas, four pods Pending for twenty minutes
Section 5's picture has two loops that do not know about each other. The HPA did its job: it computed 8 and
wrote `spec.replicas`. The scheduler cannot place the four new pods because the nodes have no allocatable CPU
left for their requests (`FailedScheduling ... Insufficient cpu`). Nothing raises the node group's
`desiredSize`, because that is a different integer on a different API (Step 10). The component that normally
closes the gap is the **Cluster Autoscaler** (or **Karpenter**): it watches for Pending pods and adds nodes.
**Lowering the CPU request is a bad fix:** it lets the pods squeeze onto full nodes by reserving less than
they use, so they contend and get throttled. It also changes the HPA's denominator, so the same load now
reads as a higher percentage, the HPA asks for even more pods, and every earlier percentage becomes
incomparable. The real fix is more nodes (or a lower `maxReplicas` as a deliberate spending limit).

### 5. Service vs Ingress
A **Service** is layer-4 plumbing for *one* set of pods: a stable virtual IP and DNS name, load-balanced across
Ready endpoints. `type: LoadBalancer` gives that one Service its own external load balancer (on EKS, one NLB
per Service). An **Ingress** is a layer-7 **routing rule set** over *many* Services (paths, hosts), and it does
nothing until an ingress controller implements it (on EKS, the AWS Load Balancer Controller turns it into
**one** ALB). Requirement: *"publish enrolment, results and timetable on one public address under different
paths, with one load balancer bill"*. Three LoadBalancer Services fail it (three addresses, three NLBs, no
path routing). One Ingress with three paths meets it (one ALB, longest-prefix routing). Exercise 4 extended
the same Ingress approach with an IngressGroup, so even a separately managed rule set shares the ALB.

### 6. /enrolment through the gateway, or straight to usms-enrolment?
I would keep **one route, through the gateway**: delete the `/enrolment` and `/results` paths from
`usms-portal-ingress` and leave only `/ -> usms-gateway`. The gateway does several things the Ingress rule
does not. It **strips the prefix** (`proxy_pass .../;` turns `/enrolment/x` into `/x`, which the backend
expects; the direct Ingress path would pass `/enrolment/x` unchanged and the backend would have to accept it).
It adds `X-Forwarded-For`/`Host` headers. It also owns the URL map in one versioned nginx ConfigMap (Lab 07
Exercise 2 added `/timetable/` there). Two parallel routes to the same service mean two behaviours to test
and two places to get wrong. The cost of my choice is one extra hop and the gateway as a component to keep
highly available, which is why Exercise 2 runs it at 2 replicas with a PDB. If the gateway did nothing but
pass traffic through, I would choose the opposite: route directly from the Ingress and delete the gateway.

### 7. A PDB with minAvailable 1 did not stop `kubectl delete pod`
That is correct behaviour. A PDB is enforced only by the **eviction API**, which cooperative tools use for
**voluntary** disruptions: `kubectl drain`, node-group upgrades, Cluster Autoscaler scale-in. `kubectl delete
pod` bypasses eviction, so it went straight through in Step 12. In the same step, the eviction API refused
with `TooManyRequests: Cannot evict pod as it would violate the pod's disruption budget`. **Involuntary**
disruptions (a kernel panic, a node running out of memory, an EC2 instance terminated, a hardware fault) are
not requests at all, so no PDB can stop them; only spreading replicas across nodes helps there. Realistic
save: AWS releases a new EKS AMI and I run a managed node-group upgrade during enrolment week. The upgrade
drains nodes one by one; with `usms-enrolment-pdb` (maxUnavailable 1) and the gateway at 2 replicas with
minAvailable 1, the drain never evicts more than one enrolment pod or the last gateway pod at a time. In Lab 07
Exercise 4 a drain was blocked this way while 150/150 smoke requests succeeded.
