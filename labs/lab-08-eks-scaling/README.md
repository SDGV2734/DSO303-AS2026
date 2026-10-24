# Lab 08 — EKS Scaling and Service Exposure

## 1. Objectives

Lab 07 left three microservices that worked but had a fixed size and could not be reached from outside the
cluster. This lab climbs two ladders on that cluster.

- **Scaling:** first by hand (`kubectl scale`), then through a manifest, then with an `autoscaling/v2`
  HorizontalPodAutoscaler. It also covers the node group's capacity from the AWS side, and the safety controls
  around scaling: requests and QoS classes, a nodeSelector, and PodDisruptionBudgets.
- **Exposure:** ClusterIP, then `port-forward`, then NodePort, then LoadBalancer, then Ingress, compared at each
  step with the ECS, ALB and Application Auto Scaling setup from Labs 04–06.

Support path: **Path A** (the same as Lab 07). There is one k3s node, and the real version is v1.34.1+k3s1.

## 2. What was built

```
SCALING
  usms-enrolment-hpa   autoscaling/v2  min 2 max 8  cpu 50% of the 50m request
                       scaleUp: window 0, Percent 100 / Pods 2 per 15s, selectPolicy Max
                       scaleDown: window 300s, Pods 1 per 60s, selectPolicy Min
                       observed: 2 -> 4 -> 8 under load, held ~5 min, then 7,6,5,4,3,2 one per minute
  usms-results-hpa     autoscaling/v2  min 2 max 6  cpu 60%   (Exercise 1)
  usms-eks-nodes       update-nodegroup-config to 2/6/3 FAILED (not emulated) - still 2/4/2
  nodeSelector         workload=usms on usms-enrolment; node labelled by hand; enforcement proven
SAFETY
  usms-gateway-pdb     minAvailable 1   -> ALLOWED DISRUPTIONS 1 (gateway now 2 replicas, Exercise 2)
  usms-enrolment-pdb   maxUnavailable 1 -> ALLOWED DISRUPTIONS 1
EXPOSURE
  ClusterIP            the Lab 07 Services - not routable from the host (proven)
  port-forward         a tunnel through the API server to ONE pod - debugging only
  usms-results-np      NodePort 80:30080 (pinned) - answers on the node IP inside the cluster
  usms-gateway         LoadBalancer  clusterIP 10.43.23.149  nodePort 32712  external 172.17.0.3
                       (k3s ServiceLB); AWS NLB annotations: external / target-type ip / internet-facing
  usms-portal-ingress  /enrolment /results /  - stored, no controller (traefik disabled by Floci)
  usms-results-ingress /results, university-only source-IP rule, shared ALB  (Exercise 4)
```

## 3. Files

| Path | Purpose |
|---|---|
| `manifests/lab-08/10-hpa-enrolment.yaml`, `11-hpa-results.yaml` | the two HPAs |
| `manifests/lab-08/20-loadgen.yaml` | the load generator (deleted at the end; re-applicable) |
| `manifests/lab-08/30-pdb-gateway.yaml` | **both** PDBs. It now owns `usms-enrolment-pdb`, which was removed from the Lab 07 file |
| `manifests/lab-08/40-service-nodeport.yaml` | `usms-results-np` |
| `manifests/lab-08/50-service-loadbalancer.yaml` | `usms-gateway` as a LoadBalancer. It now owns this Service, which was removed from the Lab 07 file |
| `manifests/lab-08/60-ingress.yaml`, `61-ingress-results.yaml` | the portal Ingress, and the results Ingress (Exercise 4) |
| `manifests/lab-07/20-enrolment.yaml` | adds `nodeSelector: workload: usms`; PDB moved out |
| `manifests/lab-07/40-gateway.yaml` | `replicas: 2` plus topology spread (Exercise 2); Service moved out |
| `configs/lab-08.env` | 19 exports; `USMS_INGRESS_CLASS` empty (no controller) |
| `scripts/utilities/hpa-watch.sh` | HPA and Deployment watcher |
| `scripts/utilities/verify-lab-08.sh` | 34 checks, **PASS=33 FAIL=1** (see Section 5) |
| `scripts/utilities/verify-lab-07.sh` | the gateway check is now "at least 1", because Exercise 2 runs 2 replicas |
| `scripts/cleanup/lab-08-cleanup.sh` | end of course only. Written and syntax-checked, **not run** |
| `notes/lab-08-notes.md` | observations per step, Step 17 tables, Exercise 5 essay, Section 14 |
| `labs/lab-08-eks-scaling/exercises.md` | Exercises 1–5 with commands and output |

**One object, one file.** Lab 08 redefines two objects that Lab 07's files already contained:
`usms-enrolment-pdb` and the `usms-gateway` Service. If both files kept a copy, whichever was applied last
would silently win, which is the drift Step 5 demonstrates. So each object now lives in exactly one file, and
`kubectl diff` on every manifest exits 0.

## 4. Steps, as performed

1. **Baseline and four dimensions.** Recorded the baseline. Confirmed the 50m request and the `_lb_ports_` tag.
   Wrote the 10x-traffic plan.
2. **Scaling by hand.** Scaling to 5 changed only the existing ReplicaSet (no rollout). Endpoints grew only as
   pods became Ready, and all 5 pods answered.
3. **Drift.** The cluster was at 6 and the file said 2; `apply` set it back to 2. `kubectl diff` exited with 1.
4. **QoS.** All pods were Burstable. The gateway went Burstable → Guaranteed → Burstable, and the pod was
   **replaced** each time.
5. **Metrics.** metrics-server was already present in k3s. Idle usage was 1m, 2% of the request.
6. **HPA.** Created it; it read `2%/50%` with `ScalingActive True`.
7. **Load.** The guide's load generator peaked at 39%, because **CoreDNS** (one lookup per `wget`) was the
   bottleneck. A load pod hitting the ClusterIP directly drove usage to 196–292%, and the HPA scaled
   2→4→8. After the load stopped, it held 8 for 300 s and then scaled in one pod per minute back to 2.
8. **Node group.** `update-nodegroup-config` failed with an S3-style error: it is not emulated, as the Known
   Issues page says. The documented alternative is the HPA drill from step 7 above, which shows pod scaling
   but not node scaling.
9. **nodeSelector.** Labelled the node, applied the selector, then proved enforcement: with a value no node
   has, the new pod stayed Pending while the old pods kept serving.
10. **PDBs.** The eviction API refused the gateway eviction with `TooManyRequests`; `kubectl delete` went
    through anyway.
11. **Exposure ladder.** Covered port-forward, NodePort, LoadBalancer (which got an external IP from k3s
    ServiceLB) and Ingress (no controller, so the elbv2 mapping is written out instead).
12. **Comparison.** Filled in the Step 17 ECS-vs-EKS tables with both stacks running.
13. **Persistence.** After a Floci restart, the HPA, PDBs, Services, Ingress and node group all read back
    identical. The k3s container was not restarted, so even the auto-allocated nodePort stayed the same.
14. **Config.** Wrote `configs/lab-08.env`.

## 5. Floci vs real AWS, as observed

| Observed | Recorded but not enacted | Conceptual on this build |
|---|---|---|
| kubectl scale and drift; QoS; the metrics API; HPA scale-out, the stabilisation window and scale-in; nodeSelector enforcement; PDBs with eviction vs delete; NodePort inside the cluster; LoadBalancer external IP (k3s ServiceLB); persistence | Node group sizing (the update API is not emulated at all); AWS NLB/ALB annotations; Ingress objects (no controller) | AWS Load Balancer Controller, Cluster Autoscaler, Karpenter, ExternalDNS, IRSA for the S3 role, custom/external metrics, cost |

Other limitations met:
- The NodePort (30080) and the `_lb_ports_` host ports (8081/8082) are **not published** to the Mac. The k3s
  container publishes only 6443→6500, so traffic from outside the cluster used `port-forward`.
- `verify-lab-08.sh` has one expected failure, `node group maxSize was raised to 6`. It fails because of the
  node-group API gap described in step 8 of Section 4.

## 6. Verify

```bash
./scripts/utilities/verify-lab-07.sh | tail -1    # PASS=30 FAIL=0
./scripts/utilities/verify-lab-08.sh | tail -1    # PASS=33 FAIL=1 (node group maxSize - known gap)
kubectl get hpa,pdb,ingress -n usms
```

## 7. Next lab

Lab 10 creates the `usms-student-data` bucket that `USMSStudentDataReadWrite` has always named. Its first
object is `outputs/lab-08-scaling-evidence.json`. `outputs/lab-08-lab06-readiness.txt` records the bucket ARN,
the three roles carrying the policy, and the IRSA ServiceAccount that should replace the node role.
