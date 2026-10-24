# Lab 07 Exercises

All commands were run against `usms-eks-cluster` (context `usms-eks`, namespace `usms`) on
support **Path A**. Full raw output for each exercise is in the git-ignored `outputs/lab-07-ex*.txt`
files; the essential commands and output are reproduced below. Screenshots are in `screenshots/lab_7/`.

---

## Exercise 1 — Basic: a fourth microservice (`usms-timetable`)

**Manifest:** [`manifests/lab-07/70-timetable.yaml`](../../manifests/lab-07/70-timetable.yaml) — one file,
three objects (ConfigMap `usms-timetable-conf`, Deployment `usms-timetable`, ClusterIP Service
`usms-timetable`), written by hand on the pattern of `30-results.yaml`.

- 1 replica, `nginx:1.27-alpine`, readiness probe on `/healthz`, Service on port 80 → `targetPort: http`
- labels `app`, `project`, `tier` on every object and on the pod template
- requests `cpu: 50m`, `memory: 32Mi`; limits `200m` / `128Mi`
- the ConfigMap's nginx template returns JSON naming the service and its own pod (`${POD_NAME}` from the
  downward API) plus `APP_CAMPUS` / `APP_VERSION` from the shared `usms-app-config`

```console
$ kubectl apply --dry-run=client -f manifests/lab-07/70-timetable.yaml
configmap/usms-timetable-conf created (dry run)
deployment.apps/usms-timetable created (dry run)
service/usms-timetable created (dry run)

$ kubectl apply -f manifests/lab-07/70-timetable.yaml
$ kubectl rollout status deployment/usms-timetable
deployment "usms-timetable" successfully rolled out

$ kubectl get deploy,svc -n usms
NAME                             READY   UP-TO-DATE   AVAILABLE
deployment.apps/usms-enrolment   2/2     2            2
deployment.apps/usms-gateway     1/1     1            1
deployment.apps/usms-results     2/2     2            2
deployment.apps/usms-timetable   1/1     1            1

NAME                     TYPE        CLUSTER-IP     PORT(S)
service/usms-enrolment   ClusterIP   10.43.205.69   80/TCP
service/usms-gateway     ClusterIP   10.43.23.149   80/TCP
service/usms-results     ClusterIP   10.43.37.121   80/TCP
service/usms-timetable   ClusterIP   10.43.139.50   80/TCP

$ kubectl run usms-ex1 --rm -i --restart=Never --image=busybox:1.36 -- \
    wget -qO- http://usms-timetable.usms.svc.cluster.local/
{"service":"usms-timetable","pod":"usms-timetable-cf6b9c8fb-2nl9x","campus":"rtc","version":"1.0.0"}
```

**Outcome:** four Deployments and four Services; a busybox pod reaches the new service by DNS name and
gets JSON naming the service and its pod. ✅

---

## Exercise 2 — Intermediate: route `/timetable/` through the gateway, and prove it

**Change:** edited [`manifests/lab-07/40-gateway.yaml`](../../manifests/lab-07/40-gateway.yaml) only (no
`kubectl edit`): added a `location /timetable/ { proxy_pass http://usms-timetable.usms.svc.cluster.local/; }`
block and listed the route in the gateway's `/` response.

```console
$ kubectl rollout history deployment/usms-gateway        # before
REVISION  CHANGE-CAUSE
1         <none>

$ kubectl apply -f manifests/lab-07/40-gateway.yaml
configmap/usms-gateway-conf configured
deployment.apps/usms-gateway unchanged                   # <- pod template did NOT change
service/usms-gateway unchanged

# the running pod still has the old config:
$ kubectl exec deploy/usms-gateway -- grep -c timetable /etc/nginx/conf.d/default.conf
0
$ wget -qO- http://usms-gateway.usms.svc.cluster.local/timetable/
wget: server returned error: HTTP/1.1 404 Not Found

$ kubectl rollout restart deployment/usms-gateway        # <- the command that creates the new ReplicaSet
deployment "usms-gateway" successfully rolled out

$ kubectl rollout history deployment/usms-gateway        # after
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
$ kubectl get rs -l app=usms-gateway
NAME                      DESIRED   CURRENT   READY   AGE
usms-gateway-54df9d9ccc   1         1         1       9s     # new ReplicaSet
usms-gateway-58854c9ffd   0         0         0       9h     # old, kept for rollback

$ kubectl exec deploy/usms-gateway -- grep -A1 'location /timetable/' /etc/nginx/conf.d/default.conf
  location /timetable/ {
    proxy_set_header Host $host;

# all three routes in one command:
$ kubectl run usms-ex2b --rm -i --restart=Never --image=busybox:1.36 -- sh -c \
    'G=http://usms-gateway.usms.svc.cluster.local; wget -qO- $G/enrolment/; wget -qO- $G/results/; wget -qO- $G/timetable/'
{"service":"usms-enrolment","pod":"usms-enrolment-56b75557cb-rfrtx","node":"b5986361ebbf","env":"laboratory","version":"1.0.0"}
{"service":"usms-results","pod":"usms-results-7fc784c47f-s5h2f","campus":"rtc","version":"1.0.0"}
{"service":"usms-timetable","pod":"usms-timetable-cf6b9c8fb-2nl9x","campus":"rtc","version":"1.0.0"}
```

**Why `rollout restart` and not `kubectl apply`:** the change was only to the ConfigMap, so the pod
template was unchanged (`deployment.apps/usms-gateway unchanged`) and no rollout happened; a ConfigMap
change never restarts pods. Of the two commands Step 18 named, the annotation on the Deployment's own
metadata does not touch the pod template either — `kubectl rollout restart` is the one that writes a
timestamp **into the pod template**, so it is the one that fits. It created ReplicaSet `54df9d9ccc`
(revision 2). nginx resolves the new `usms-timetable` name at start-up, which is also why the Service had
to exist before the gateway restarted (Troubleshooting entry 3). ✅

---

## Exercise 3 — Problem solving: find the misconfiguration

Applied the manifest exactly as given (saved as `outputs/lab-07-ex3-broken.yaml`). `kubectl apply`
accepted it; the Service returned nothing. Diagnosed with commands, in this order:

```console
# 1. symptom - the Service has no endpoints
$ kubectl get endpoints usms-broken
NAME          ENDPOINTS   AGE
usms-broken   <none>      16s

# 2. the pods exist, but are not ready
$ kubectl get pods -l app=usms-broken
NAME                           READY   STATUS    RESTARTS   AGE
usms-broken-7c447464c4-27v26   0/1     Running   0          17s
usms-broken-7c447464c4-2trnt   0/1     Running   0          17s

# 3. FAULT A - compare what the Service selects with what the pods carry
$ kubectl get svc usms-broken -o jsonpath='{.spec.selector}'
{"app":"usms-broken","version":"v2"}
$ kubectl get pods -l app=usms-broken --show-labels
usms-broken-7c447464c4-27v26   0/1   Running   ...   app=usms-broken,pod-template-hash=7c447464c4,version=v1
usms-broken-7c447464c4-2trnt   0/1   Running   ...   app=usms-broken,pod-template-hash=7c447464c4,version=v1
$ kubectl get pods -l app=usms-broken,version=v2
No resources found in usms namespace.

# 4. FAULT B - why are the pods 0/1? read the Events
$ kubectl describe pod usms-broken-7c447464c4-27v26        # Events
  Warning  Unhealthy  0s (x5 over 16s)  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
$ kubectl exec usms-broken-7c447464c4-27v26 -- wget -qO- http://127.0.0.1/healthz
wget: server returned error: HTTP/1.1 404 Not Found
```

### Diagnosis

| | Fault | Revealed by | Cause in one sentence |
|---|---|---|---|
| **A** | Service selector `version: v2` | `get svc -o jsonpath={.spec.selector}` vs `get pods --show-labels`; `get pods -l ...,version=v2` → none | The Service selects `version: v2` but the pod template labels the pods `version: v1`, so the selector matches no pods at all. |
| **B** | Readiness probe `path: /healthz` | `describe pod` Events: `Readiness probe failed ... statuscode: 404`; `wget /healthz` → 404 | The base `nginx` image has no `/healthz` (only this lab's custom templates add it), so the probe always fails and the pods never become Ready — and a not-Ready pod is never a serving endpoint. |

### Fix — exactly one line per fault

Fixing one alone does not work:

```console
# Fix A only: Service selector `version: v2` -> `version: v1`
$ diff broken.yaml fixed.yaml
37c37
<     version: v2
---
>     version: v1
$ kubectl get endpoints usms-broken
NAME          ENDPOINTS   AGE
usms-broken               33s          # still no serving endpoint ...
$ kubectl get endpointslice -l kubernetes.io/service-name=usms-broken ...
10.42.0.63 ready=false                 # ... the pods are now selected, but NOT ready
10.42.0.62 ready=false

# Fix B: readiness probe `path: /healthz` -> `path: /`  (nginx serves / with 200)
$ diff broken.yaml fixed.yaml
25c25
<               path: /healthz
---
>               path: /
37c37
<     version: v2
---
>     version: v1
$ kubectl apply -f fixed.yaml && kubectl rollout status deployment/usms-broken
deployment "usms-broken" successfully rolled out
$ kubectl get endpoints usms-broken
NAME          ENDPOINTS                     AGE
usms-broken   10.42.0.64:80,10.42.0.65:80   37s        # two endpoints
$ wget -qO- http://usms-broken.usms.svc.cluster.local/ | grep title
<title>Welcome to nginx!</title>
```

(Fix A could equally be done by deleting the `version: v2` line from the Service selector.)

**Clean up (Section 15):**
```console
$ kubectl delete deployment,service usms-broken --ignore-not-found
deployment.apps "usms-broken" deleted
service "usms-broken" deleted
```
✅

---

## Exercise 4 — Challenge: survive a node going away

**Changes** (all in [`manifests/lab-07/20-enrolment.yaml`](../../manifests/lab-07/20-enrolment.yaml), no new
Deployment):

```yaml
# pod template
topologySpreadConstraints:              # ADVISORY
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector: { matchLabels: { app: usms-enrolment } }
affinity:
  podAntiAffinity:                      # ADVISORY
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector: { matchLabels: { app: usms-enrolment } }
---
apiVersion: policy/v1                   # NEW OBJECT - ENFORCED
kind: PodDisruptionBudget
metadata: { name: usms-enrolment-pdb, namespace: usms }
spec:
  minAvailable: 1
  selector: { matchLabels: { app: usms-enrolment } }
```

### Justification

The brief has three requirements, and each one is met by a different mechanism:

1. **"Must not have all its capacity on one node"** is a *placement* rule, applied by the scheduler when
   pods are created. I used two complementary, **advisory** tools. `topologySpreadConstraints` with
   `maxSkew: 1` over `kubernetes.io/hostname` keeps the per-node pod count within 1 of each other, so 2
   replicas on 2 nodes become 1+1, and 4 replicas become 2+2 rather than 3+1. Preferred
   `podAntiAffinity` adds a second nudge against putting two enrolment pods on the same host. I chose
   `ScheduleAnyway` / `preferred…` rather than `DoNotSchedule` / `required…` on purpose: if a node fails
   during enrolment week, a hard rule would leave the replacement pod `Pending` until a second node exists,
   so it would cut capacity exactly when it is most needed. A soft rule spreads when it can and still runs
   the pod when it cannot. The weakness is that a soft rule does not re-balance existing pods later.
2. **"Must never drop below one healthy pod during a voluntary disruption"** is an *eviction* rule, and only
   a `PodDisruptionBudget` is **enforced**. `minAvailable: 1` makes the eviction API (used by `kubectl drain`,
   managed node group upgrades and the cluster autoscaler) refuse any eviction that would leave fewer than
   one Ready enrolment pod. I chose `minAvailable: 1` rather than `maxUnavailable: 1` because the brief is
   stated as a floor; with 2 replicas they behave the same, but when Lab 08's HPA scales out, `minAvailable: 1`
   would allow faster drains. To keep more capacity at peak I would raise it to 2 or use a percentage. A PDB
   does **not** protect against *involuntary* loss (a node crashing); only the spread rules help there,
   because the surviving pod is on a different node.
3. **"Must be able to say, from the cluster itself, which node each pod is on"**: the cluster reports this
   itself. The scheduler records the node in `spec.nodeName`, which `kubectl get pods -o wide` shows. The pod
   also reports it in its own response through the downward API (`"node":"${NODE_NAME}"`).

### Demonstration — what this cluster allows

This cluster has **one schedulable node**. Floci records the node group as desired 2 but starts one k3s
node, so the spread rules cannot place pods on different nodes:

```console
$ kubectl get nodes
NAME           STATUS   ROLES           AGE   VERSION
b5986361ebbf   Ready    control-plane   10h   v1.34.1+k3s1

$ kubectl get pods -l app=usms-enrolment -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName'
POD                               NODE
usms-enrolment-5b64544787-j7lvg   b5986361ebbf
usms-enrolment-5b64544787-z48rl   b5986361ebbf           # both on one node - ScheduleAnyway allowed it

$ kubectl get pdb
NAME                 MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
usms-enrolment-pdb   1               N/A               1
```

**What I would have shown with two nodes:** after the rollout, `get pods -o wide` would show one enrolment
pod on each node. Draining node A would evict only its pod, and the pod on node B would keep serving the
whole time. The replacement would be scheduled onto B, or onto A again once it was uncordoned.

**What the cluster does allow:** I drained the node of its enrolment pods while a smoke test sent one request
every 0.5 s through the gateway for about 75 s:

```console
$ kubectl drain b5986361ebbf --pod-selector=app=usms-enrolment --ignore-daemonsets \
    --delete-emptydir-data --timeout=30s
node/b5986361ebbf cordoned
evicting pod usms/usms-enrolment-5b64544787-j7lvg
evicting pod usms/usms-enrolment-5b64544787-z48rl
pod/usms-enrolment-5b64544787-j7lvg evicted                       # 1st eviction allowed (2 -> 1)
error when evicting pods/"usms-enrolment-5b64544787-z48rl" -n "usms" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.   # 2nd eviction REFUSED
error: unable to drain node "b5986361ebbf" ... global timeout reached: 30s

$ kubectl get pods -l app=usms-enrolment -o wide          # during the drain
usms-enrolment-5b64544787-xhhrd   0/1   Pending   <none>          # replacement: nowhere to go (cordoned)
usms-enrolment-5b64544787-z48rl   1/1   Running   b5986361ebbf    # the PDB kept this one serving
$ kubectl get pdb
usms-enrolment-pdb   1   N/A   0                                   # ALLOWED DISRUPTIONS now 0
$ kubectl describe pod usms-enrolment-5b64544787-xhhrd    # Events
  Warning  FailedScheduling  default-scheduler  0/1 nodes are available: 1 node(s) were unschedulable.

$ kubectl uncordon b5986361ebbf
$ kubectl rollout status deployment/usms-enrolment
deployment "usms-enrolment" successfully rolled out           # back to 2/2

# smoke test result, the whole time:
    150 OK          # 0 FAIL
```

**Outcome:** the drain could not take enrolment below one healthy pod, and no request failed during it.
The pods report their node from the cluster itself. The node was uncordoned afterwards and the Deployment
is back at 2/2. ✅

---

## Exercise 5 — Integration: prepare what Lab 08 needs, using what Lab 01 built

### Part 1 — CPU baseline → `outputs/lab-07-cpu-baseline.txt`

```console
$ kubectl get --raw /apis/metrics.k8s.io/v1beta1 >/dev/null && echo PRESENT
metrics API: PRESENT (k3s ships metrics-server)
$ kubectl top pods -l app=usms-enrolment
NAME                              CPU(cores)   MEMORY(bytes)
usms-enrolment-5b64544787-xhhrd   1m           8Mi
usms-enrolment-5b64544787-z48rl   1m           6Mi
cpu request per pod: 50m
usms-enrolment-5b64544787-xhhrd  cpu=1m  = 2.0% of 50m request
usms-enrolment-5b64544787-z48rl  cpu=1m  = 2.0% of 50m request
```
`kubectl top` **works** on this build: k3s bundles metrics-server, so Lab 08's HPA has a metrics source.
The baseline at idle is 1m, which is 2% of the 50m request. These are measured values, not estimates.

### Part 2 — `USMSStudentDataReadWrite` readiness → `outputs/lab-07-lab06-readiness.txt`

I derived everything from IAM: `list-policies` → `get-policy` (default version) → `get-policy-version`.
I didn't open Lab 1's documentation.

```console
Policy ARN       : arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite
Roles carrying it: usms-ec2-app-role  usms-ecs-task-role  usms-eks-node-role
Default version  : v1
  Allow  ListTheBucketItself              s3:ListBucket,s3:GetBucketLocation     arn:aws:s3:::usms-student-data
  Allow  ReadWriteObjectsInsideTheBucket  s3:GetObject,s3:PutObject,s3:DeleteObject arn:aws:s3:::usms-student-data/*
  Deny   NeverDeleteTheBucket             s3:DeleteBucket                        arn:aws:s3:::usms-student-data
Bucket ARN (ListBucket target)    : arn:aws:s3:::usms-student-data
Object ARN (Get/PutObject target) : arn:aws:s3:::usms-student-data/*
Bucket name (derived from the doc): usms-student-data
Does the bucket exist? NO - head-bucket fails; Lab 10 creates it
```
The **bucket ARN** (`arn:aws:s3:::usms-student-data`) is the resource for bucket-level actions such as
`ListBucket`. The **object ARN** (`.../*`) is the resource for object actions. These are separate entries,
and Lab 10 relies on that difference. The policy names a bucket that does not exist yet. It is now held by
three roles.

### Part 3 — which `configs/lab-07.env` variables Lab 08 needs

Written in `notes/lab-07-notes.md` ("Exercise 5 Part 3"), one line each with the reason.

### Git-ignore check

```console
$ git check-ignore -v outputs/lab-07-cpu-baseline.txt outputs/lab-07-lab06-readiness.txt
.gitignore:8:outputs/*	outputs/lab-07-cpu-baseline.txt
.gitignore:8:outputs/*	outputs/lab-07-lab06-readiness.txt
```
✅
