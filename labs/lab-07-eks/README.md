# Lab 07 — Deploying a Microservices Application on Amazon EKS

## 1. Objectives

This lab builds an EKS cluster and a managed node group inside Lab 02's VPC, each with its own IAM role.
It then deploys three USMS microservices (`usms-gateway`, `usms-enrolment` and `usms-results`) from
declarative manifests into the namespace `usms`. Using that application, the lab demonstrates DNS-based
service discovery, a rolling update and a rollback, three deliberate failures, and how ConfigMaps and
Secrets work, including what a Secret does not protect. Finally, it proves that the state survives a
Floci restart and records the identifiers in `configs/lab-07.env` for Lab 08.

Support path: **Path A**. `aws eks` works on this Floci build, so both the AWS half and the Kubernetes
half ran for real.

## 2. What was built

```
IAM
├── usms-eks-cluster-role   trusts eks.amazonaws.com -> USMSEKSClusterPolicy
└── usms-eks-node-role      trusts ec2.amazonaws.com -> USMSEKSNodePolicy
                                                     -> USMSStudentDataReadWrite (Lab 01, unchanged, 3rd holder)
EC2
└── usms-eks-cluster-sg     in usms-vpc, tcp/443 from 10.0.0.0/16 only

EKS
└── usms-eks-cluster        ACTIVE, 4 Lab 02 subnets, _lb_ports_=8081,8082, endpoint https://localhost:6500
    └── usms-eks-nodes      ACTIVE, private-a + private-b, min 2 / max 4 / desired 2

Kubernetes - namespace usms
├── usms-gateway    1 replica  ClusterIP  proxies /enrolment/ /results/ /timetable/ BY DNS NAME
├── usms-enrolment  2 replicas ClusterIP  maxUnavailable 0, readiness + liveness, cpu 50m,
│                                         Secret env, topology spread + anti-affinity, PDB minAvailable 1
├── usms-results    2 replicas ClusterIP  default strategy
├── usms-timetable  1 replica  ClusterIP  (Exercise 1)
├── ConfigMaps      usms-app-config + one nginx template per service
├── Secret          usms-enrolment-secret  (manifest kept in git-ignored outputs/, never committed)
└── ServiceAccount  usms-enrolment-sa      (IRSA target on real AWS)
```

## 3. Files

| Path | Purpose |
|---|---|
| `policies/trust-eks-cluster.json`, `trust-eks-node.json` | trust policies (quoted heredoc) |
| `policies/usms-eks-cluster-policy.json`, `usms-eks-node-policy.json` | local stand-ins for the AWS managed EKS policies |
| `templates/lab-07-create-cluster.json`, `lab-07-create-nodegroup.json` | `--cli-input-json` bodies (unquoted heredoc, real IDs) |
| `manifests/lab-07/00…70-*.yaml` | namespace, shared ConfigMap, the four services, ServiceAccount, in apply order |
| `configs/lab-07.env` | 21 exports for Lab 08, no secrets |
| `scripts/utilities/eks-support-probe.sh` | decides support path A/B/C |
| `scripts/utilities/verify-lab-07.sh` | 30 checks; **PASS=30 FAIL=0** |
| `scripts/cleanup/lab-07-cleanup.sh` | end of course only. Written and syntax-checked, **not run** |
| `notes/lab-07-notes.md` | observations, written answers, Section 14 |
| `labs/lab-07-eks/exercises.md` | Exercises 1–5 with commands and output |

`manifests/` is a new top-level folder. Kubernetes manifests are neither AWS API request bodies nor IAM
documents, so `templates/` and `policies/` would both be the wrong home for them.

## 4. Steps, as performed

1. **Environment and support probe.** Floci in hybrid mode. `verify-lab-02.sh` reported FAIL=0, and the
   four subnets are in two AZs. The probe returned **PATH A**.
2. **IAM.** Wrote the two trust policies and two permission policies, then created both roles, attached the
   policies, and attached `USMSStudentDataReadWrite` to the node role. It now has three holders.
3. **Security group.** Created `usms-eks-cluster-sg` in `usms-vpc`, allowing 443 from the VPC CIDR only.
4. **Cluster.** Created it while holding assumed `usms-developer-role` credentials, then restored the
   normal identity. The first attempt timed out while Floci pulled `rancher/k3s:latest`. Pre-pulling the
   image on the host fixed it.
5. **Node group.** Placed in the private subnets only, min 2 / max 4 / desired 2, labels `workload=usms tier=app`.
6. **kubectl.** Ran `aws eks update-kubeconfig --alias usms-eks` and made `usms` the default namespace.
7. **Workloads.** Deployed enrolment, then results, then the gateway, in that order, because nginx resolves
   its upstream names at start-up.
8. **Proofs.** DNS names resolve to ClusterIPs. 12 requests through the gateway were answered by two pods.
   A deleted pod was replaced by its ReplicaSet with no failed requests.
9. **Secret.** Showed that `base64 -d` recovers the token with no key, and that `printenv` inside the pod
   shows it in plain text.
10. **Rollout and rollback.** A ConfigMap change alone did nothing. `rollout restart` created a new
    ReplicaSet. `rollout undo` restored the pod template but not the ConfigMap, so the pod still reported 1.1.0.
11. **Failures.** Produced ImagePullBackOff (old pods kept serving), Pending/FailedScheduling and
    CrashLoopBackOff, and diagnosed each one with `describe` first.
12. **IRSA.** An issuer URL exists and the OIDC provider was registered in IAM, but the discovery document
    returns 404. IRSA is therefore conceptual on this build.
13. **Persistence.** Stopped and started Floci. The cluster and node group were re-derived from
    `list-clusters`/`list-nodegroups`, and the before/after comparison showed **PERSISTENCE PROVEN**.
14. **Config file.** Wrote `configs/lab-07.env` with 21 exports and no empty values.

## 5. Floci vs real AWS, as observed

| Observed for real | Recorded only | Conceptual on this build |
|---|---|---|
| Kubernetes object model, CoreDNS discovery, kube-proxy load spreading, rolling updates and rollback, the three failure modes, PDB-enforced eviction, persistence of both halves | IAM trust and permission policies (stored, never evaluated); node group sizing and `t3.small`/AL2023 (one k3s node actually runs); security groups | IRSA (OIDC document 404s), KMS envelope encryption of Secrets, EKS access entries, control-plane logging |

Environment issues met and fixed (details in the notes):

- Docker Desktop has only 3.8 GB of memory. Another course's kind cluster was starving k3s, which then
  crashed with "Slow SQL" and context-deadline errors. Fixed by stopping that cluster.
- After each Docker Desktop restart:
  - kubectl's context flipped to `docker-desktop`.
  - k3s refused to start because its saved node IP (172.17.0.3) had been given away. Fixed by temporarily
    occupying 172.17.0.2 so k3s got .3 back. All Kubernetes state survived.
  - Because of this, `verify-lab-07.sh` pins every kubectl call to `--context usms-eks`.
- Floci reports Kubernetes **1.30**, but the cluster actually runs **v1.34.1+k3s1**, from `rancher/k3s:latest`.

## 6. Verify

```bash
source configs/course.env
./scripts/utilities/verify-lab-07.sh          # PASS=30 FAIL=0
kubectl --context usms-eks -n usms run usms-smoke --rm -it --restart=Never --image=busybox:1.36 -- sh -c \
  'G=http://usms-gateway.usms.svc.cluster.local; wget -qO- $G/ && wget -qO- $G/enrolment/ && wget -qO- $G/results/'
```

If kubectl reports `connection refused` on port 6500 after Docker restarts, check:
- `docker ps -a | grep eks-usms` to see whether the k3s container is running;
- `kubectl config current-context` to make sure the context is `usms-eks`.

## 7. Next lab

Lab 08 scales `usms-enrolment` with an HPA, which uses the 50m CPU request; the metrics API is present.
It scales the node group from the AWS side, and exposes `usms-gateway` through NodePort, then
LoadBalancer, then Ingress, which uses the `_lb_ports_` tag 8081,8082.
