# Laurel POC — repository architecture

This file is the **project structure plan** for the Laurel AKS POC. How each technology is configured lives in [Laurel-POC.md](./Laurel-POC.md). This document answers: which folders exist, which YAML files go where, who applies them (Helm CI/CD vs Argo CD), and in what order.

The repo is both:

1. The **Helm source** for Argo CD (`bootstrap/argocd` + CI workflows).
2. The **GitOps source of truth** Argo CD syncs after it is installed (`gitops/`, `platform/`, `apps/`).

Do not put cluster-create Azure CLI into Argo CD. VNet, identity, and `az aks create` stay in `infra/` as scripts an operator runs once.

---

## 1. Delivery model

```text
infra scripts (once)
        │
        ▼
   AKS cluster + NAP
        │
        ▼
 Helm  ── manual laptop  OR  GitHub Actions / Azure DevOps
        │                    (only when bootstrap/argocd/** changes)
        ▼
    Argo CD
        │
        │  watches Git: gitops/applications/*
        ▼
  platform/*  and  apps/*   (plain manifests)
```

| Change in Git | Applied by | Not applied by |
| --- | --- | --- |
| `bootstrap/argocd/values.yaml` | Helm (`helm upgrade --install`), manual or CI | Argo CD |
| `bootstrap/root/*.yaml` | `kubectl apply` once, or the Helm CI job’s last step | Optional later self-manage |
| `gitops/applications/*.yaml` | Root Argo CD Application | Helm / app CI |
| `platform/**`, `apps/**` | Child Argo CD Applications | Helm / app CI |
| `infra/**` | Human or a separate infra pipeline (`az`) | Argo CD |

There is **no application CI/CD pipeline**. After Argo CD exists, shipping a workload is `git commit` + `git push`.

---

## 2. Target folder tree

```text
laurel-poc/
├── Laurel-POC.md
├── Laurel-POC-architecture.md
│
├── infra/
│   ├── README.md
│   ├── 00-providers.sh
│   ├── 01-foundation.sh
│   ├── 02-aks-create.sh
│   └── 99-teardown.sh
│
├── bootstrap/
│   ├── argocd/
│   │   ├── Chart.lock                 # optional; pin after first helm pull
│   │   └── values.yaml                # Helm values for Argo CD
│   └── root/
│       ├── appproject.yaml            # AppProject laurel-poc
│       └── root-application.yaml      # Application laurel-poc-root
│
├── gitops/
│   └── applications/                  # child Application CRs (App of Apps)
│       ├── platform-karpenter.yaml
│       ├── platform-kyverno.yaml
│       ├── platform-agfc.yaml
│       ├── app-namespaces.yaml
│       ├── app-storefront-l4.yaml
│       ├── app-storefront-l7.yaml
│       └── app-scale-me.yaml
│
├── platform/
│   ├── karpenter/
│   │   ├── aksnodeclass.yaml
│   │   ├── nodepool-workload.yaml
│   │   └── nodepool-spot.yaml         # optional
│   ├── kyverno/
│   │   ├── kustomization.yaml
│   │   ├── upstream/
│   │   │   └── install.yaml           # vendored Kyverno release manifest
│   │   ├── patches/
│   │   │   ├── webhook-aks.yaml
│   │   │   └── system-pool.yaml
│   │   └── policies/
│   │       ├── disallow-privileged.yaml
│   │       ├── require-labels.yaml
│   │       └── add-env-label.yaml
│   └── agfc/
│       ├── controller/                # only if using Helm instead of AKS add-on
│       │   ├── README.md
│       │   └── values.yaml
│       ├── namespace.yaml
│       └── applicationloadbalancer.yaml
│
├── apps/
│   ├── namespaces.yaml
│   ├── storefront-l4/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── storefront-l7/
│   │   ├── backend-v1.yaml
│   │   ├── backend-v2.yaml
│   │   ├── gateway.yaml
│   │   └── httproute.yaml
│   └── scale-me/
│       └── deployment.yaml
│
├── ci/
│   └── azure-pipelines/
│       └── deploy-argocd.yml
│
└── .github/
    └── workflows/
        └── deploy-argocd.yaml
```

Keep secrets out of this tree. Azure client IDs for GitHub OIDC live in GitHub secrets. The Argo CD admin password stays as an in-cluster Secret.

---

## 3. Folder responsibilities

### 3.1 `infra/` — Azure and AKS (not GitOps)

Run these from a workstation (or a dedicated infra pipeline) **before** Helm.

| File | Purpose |
| --- | --- |
| `00-providers.sh` | `az provider register`, feature flags, CLI extensions |
| `01-foundation.sh` | Resource group, managed identity, VNet, `snet-aks-nodes`, `snet-agfc` (delegated `/24`), Network Contributor |
| `02-aks-create.sh` | `az aks create` with Overlay + Cilium + NAP + workload identity. **Does not** enable the AGfC add-on |
| `99-teardown.sh` | `az group delete` |

Commands and networking CIDRs are specified in [Laurel-POC.md](./Laurel-POC.md) sections 2.3–2.5.

Optional later: add `03-agfc-addon.sh` (`az aks update --enable-gateway-api --enable-application-load-balancer`) **or** `03-agfc-helm.sh` (identity + federated credential + `helm install alb-controller`). Never run both.

### 3.2 `bootstrap/argocd/` — Helm for Argo CD

| File | Kind | Applied by |
| --- | --- | --- |
| `values.yaml` | Helm values | `helm upgrade --install argocd argo/argo-cd` |

This is the only Helm chart the POC treats as first-class. Full values are in [Laurel-POC.md](./Laurel-POC.md) section 3.1.

Chart version is pinned in the CI workflow (`ARGOCD_CHART_VERSION`) and in the manual command, not inside `values.yaml`.

### 3.3 `bootstrap/root/` — one-time GitOps bootstrap

| File | Kind | Fields that must be set |
| --- | --- | --- |
| `appproject.yaml` | `AppProject` | `sourceRepos` = this Git URL; `destinations` = in-cluster `*`; cluster-scoped whitelist |
| `root-application.yaml` | `Application` | `path: gitops/applications`; `destination.namespace: argocd`; automated sync + prune + selfHeal |

Apply after Helm:

```bash
kubectl apply -f bootstrap/root/appproject.yaml
kubectl apply -f bootstrap/root/root-application.yaml
```

Replace `https://github.com/<org>/laurel-poc.git` in both files with the real remote.

### 3.4 `gitops/applications/` — App of Apps children

Each file is one `Application` pointing at a directory of raw YAML (or Kustomize). Argo CD’s root app syncs this folder.

| File | `spec.source.path` | Destination namespace | Notes |
| --- | --- | --- | --- |
| `platform-karpenter.yaml` | `platform/karpenter` | (cluster-scoped CRs; dest ns unused but required — use `argocd`) | `AKSNodeClass` + `NodePool` |
| `platform-kyverno.yaml` | `platform/kyverno` | `kyverno` | Set `syncOptions: ServerSideApply=true` |
| `platform-agfc.yaml` | `platform/agfc` | `alb-test-infra` | Exclude `platform/agfc/controller` from this path (Helm, not GitOps) |
| `app-namespaces.yaml` | `apps` with directory filter **or** a tiny folder `apps/` that only has `namespaces.yaml` | cluster | Simpler: put `namespaces.yaml` in `apps/` and give this Application `path: apps` with `directory.include: namespaces.yaml` — or keep namespaces in their own `apps/namespaces.yaml` Application with `path: apps` and `directory.jsonnet` unused. Recommended: `path: apps` and `directory.include: "{namespaces.yaml}"` |
| `app-storefront-l4.yaml` | `apps/storefront-l4` | `poc-l4` | `CreateNamespace=true` if namespaces app did not run yet |
| `app-storefront-l7.yaml` | `apps/storefront-l7` | `poc-l7` | Depends on AGfC `ApplicationLoadBalancer` Ready |
| `app-scale-me.yaml` | `apps/scale-me` | `poc-scale` | Karpenter demo |

Shared child spec (copy per file):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <name>
  namespace: argocd
spec:
  project: laurel-poc
  source:
    repoURL: https://github.com/<org>/laurel-poc.git
    targetRevision: HEAD
    path: <folder>
  destination:
    server: https://kubernetes.default.svc
    namespace: <namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Kyverno child extra sync option:

```yaml
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

AGfC child: do **not** set `path: platform/agfc` if that directory also contains `controller/values.yaml` in a way that Argo tries to apply it as Kubernetes YAML. Keep Helm values under `platform/agfc/controller/` and list only Kubernetes resources next to it, **or** set:

```yaml
  source:
    path: platform/agfc
    directory:
      exclude: "controller/**"
```

Sync waves (optional, recommended):

| Wave annotation | Application |
| --- | --- |
| `argocd.argoproj.io/sync-wave: "-2"` | namespaces |
| `argocd.argoproj.io/sync-wave: "-1"` | kyverno, karpenter |
| `argocd.argoproj.io/sync-wave: "0"` | agfc ApplicationLoadBalancer |
| `argocd.argoproj.io/sync-wave: "1"` | storefront-l4, storefront-l7, scale-me |

Put the annotation on the child `Application` metadata.

### 3.5 `platform/karpenter/` — NAP manifests

| File | Kind | Purpose |
| --- | --- | --- |
| `aksnodeclass.yaml` | `AKSNodeClass` | Azure Linux, disk, maxPods, optional `vnetSubnetID` |
| `nodepool-workload.yaml` | `NodePool` | On-demand D-family user nodes, limits, consolidation |
| `nodepool-spot.yaml` | `NodePool` | Optional Spot pool |

NAP itself is the AKS add-on (`--node-provisioning-mode Auto`). These files only shape nodes. YAML is in [Laurel-POC.md](./Laurel-POC.md) section 4.2.

### 3.6 `platform/kyverno/` — operator + policies as manifests

| File | Role |
| --- | --- |
| `upstream/install.yaml` | Vendored [Kyverno release install.yaml](https://github.com/kyverno/kyverno/releases) (CRDs, Deployments, webhooks). Do not edit by hand |
| `patches/webhook-aks.yaml` | Adds `admissions.enforcer/disabled: "true"` to all webhooks |
| `patches/system-pool.yaml` | `nodeSelector: pool=system` and `CriticalAddonsOnly` toleration on Deployments |
| `policies/*.yaml` | `ClusterPolicy` objects for the POC |
| `kustomization.yaml` | Wires upstream + patches + policies |

Argo CD detects Kustomize when `kustomization.yaml` is present. There is no AKS add-on for Kyverno.

Vendor command (pin the same version in a comment at the top of `kustomization.yaml`):

```bash
curl -L -o platform/kyverno/upstream/install.yaml \
  https://github.com/kyverno/kyverno/releases/download/v1.16.2/install.yaml
```

### 3.7 `platform/agfc/` — Application Gateway for Containers

**Controller (pick one, not both):**

| Path | Where it lives | GitOps? |
| --- | --- | --- |
| AKS add-on | `az aks update --enable-gateway-api --enable-application-load-balancer` in `infra/` | No |
| Helm | `platform/agfc/controller/values.yaml` + `helm install` (see Laurel-POC.md section 6.2) | No — Helm, like Argo CD |

**Manifests Argo CD must sync:**

| File | Kind | Required fields |
| --- | --- | --- |
| `namespace.yaml` | `Namespace` | `alb-test-infra` |
| `applicationloadbalancer.yaml` | `ApplicationLoadBalancer` | `spec.associations` = ARM ID of `snet-agfc` |

Substitute the subscription ID in `applicationloadbalancer.yaml` (Kustomize `replacements` or a documented placeholder). Do not commit a production subscription if the repo is public; use a `kustomization.yaml` with a local overlay that is gitignored, or a clearly marked placeholder.

Gateway and HTTPRoute live with the L7 **application** (`apps/storefront-l7/`) because they route to those Services.

### 3.8 `apps/` — sample workloads

| Path | Kinds | Tests |
| --- | --- | --- |
| `namespaces.yaml` | `Namespace` × 3 (`poc-l4`, `poc-l7`, `poc-scale`) | Isolation |
| `storefront-l4/deployment.yaml` | `Deployment` | L4 workload |
| `storefront-l4/service.yaml` | `Service` `type: LoadBalancer` | Azure Load Balancer frontend |
| `storefront-l7/backend-v1.yaml` | `Deployment` + `Service` ClusterIP | AGfC backend v1 |
| `storefront-l7/backend-v2.yaml` | `Deployment` + `Service` ClusterIP | AGfC backend v2 |
| `storefront-l7/gateway.yaml` | `Gateway` | Listener 80, annotations to `alb-laurel` |
| `storefront-l7/httproute.yaml` | `HTTPRoute` | `/v1`, `/v2`, weighted `/` |
| `scale-me/deployment.yaml` | `Deployment` (1 CPU request) | Karpenter scale-out |

All Deployments must include labels `app` and `owner` (Kyverno) and must not set `privileged: true`.

Full YAML: [Laurel-POC.md](./Laurel-POC.md) sections 6.3, 7.2, and 8.

### 3.9 `ci/` and `.github/workflows/` — Helm CI/CD for Argo CD only

| File | System | Trigger |
| --- | --- | --- |
| `.github/workflows/deploy-argocd.yaml` | GitHub Actions | Push to `main` when `bootstrap/argocd/**` changes; `workflow_dispatch` |
| `ci/azure-pipelines/deploy-argocd.yml` | Azure DevOps | Same path filter |

Both run `helm upgrade --install` with `bootstrap/argocd/values.yaml`. Optionally they `kubectl apply -f bootstrap/root/` so the App of Apps exists after the first pipeline run.

Implement **one** CI system for the POC. Keep the other file as a reference, or delete it.

Required pipeline secrets / service connection: Azure OIDC (or service principal) with permission to get AKS admin credentials. No kubeconfig in Git.

---

## 4. Child Application YAML to create

Copy these into `gitops/applications/`. Replace the repo URL.

### `platform-karpenter.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-karpenter
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: laurel-poc
  source:
    repoURL: https://github.com/<org>/laurel-poc.git
    targetRevision: HEAD
    path: platform/karpenter
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### `platform-kyverno.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-kyverno
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: laurel-poc
  source:
    repoURL: https://github.com/<org>/laurel-poc.git
    targetRevision: HEAD
    path: platform/kyverno
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### `platform-agfc.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-agfc
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: laurel-poc
  source:
    repoURL: https://github.com/<org>/laurel-poc.git
    targetRevision: HEAD
    path: platform/agfc
    directory:
      exclude: "{controller/**,README.md}"
  destination:
    server: https://kubernetes.default.svc
    namespace: alb-test-infra
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### `app-namespaces.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-namespaces
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: laurel-poc
  source:
    repoURL: https://github.com/<org>/laurel-poc.git
    targetRevision: HEAD
    path: apps
    directory:
      include: "namespaces.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
```

### `app-storefront-l4.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-storefront-l4
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: laurel-poc
  source:
    repoURL: https://github.com/<org>/laurel-poc.git
    targetRevision: HEAD
    path: apps/storefront-l4
  destination:
    server: https://kubernetes.default.svc
    namespace: poc-l4
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### `app-storefront-l7.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-storefront-l7
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: laurel-poc
  source:
    repoURL: https://github.com/<org>/laurel-poc.git
    targetRevision: HEAD
    path: apps/storefront-l7
  destination:
    server: https://kubernetes.default.svc
    namespace: poc-l7
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### `app-scale-me.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-scale-me
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: laurel-poc
  source:
    repoURL: https://github.com/<org>/laurel-poc.git
    targetRevision: HEAD
    path: apps/scale-me
  destination:
    server: https://kubernetes.default.svc
    namespace: poc-scale
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 5. Manifest inventory (every file you author)

Use this as a checklist when creating the repo. Vendor files are included.

| Path | API / kind | Source |
| --- | --- | --- |
| `bootstrap/argocd/values.yaml` | Helm values | Authored |
| `bootstrap/root/appproject.yaml` | `argoproj.io/v1alpha1` `AppProject` | Authored |
| `bootstrap/root/root-application.yaml` | `argoproj.io/v1alpha1` `Application` | Authored |
| `gitops/applications/*.yaml` | `Application` × 7 | Authored |
| `platform/karpenter/aksnodeclass.yaml` | `karpenter.azure.com/v1beta1` `AKSNodeClass` | Authored |
| `platform/karpenter/nodepool-workload.yaml` | `karpenter.sh/v1` `NodePool` | Authored |
| `platform/karpenter/nodepool-spot.yaml` | `karpenter.sh/v1` `NodePool` | Authored (optional) |
| `platform/kyverno/upstream/install.yaml` | many (CRDs, Deployments, webhooks) | Vendored release |
| `platform/kyverno/kustomization.yaml` | Kustomize | Authored |
| `platform/kyverno/patches/webhook-aks.yaml` | webhook annotation patch | Authored |
| `platform/kyverno/patches/system-pool.yaml` | Deployment patch | Authored |
| `platform/kyverno/policies/*.yaml` | `kyverno.io/v1` `ClusterPolicy` × 3 | Authored |
| `platform/agfc/controller/values.yaml` | Helm values (AGfC Helm path only) | Authored |
| `platform/agfc/namespace.yaml` | `Namespace` | Authored |
| `platform/agfc/applicationloadbalancer.yaml` | `alb.networking.azure.io/v1` `ApplicationLoadBalancer` | Authored |
| `apps/namespaces.yaml` | `Namespace` × 3 | Authored |
| `apps/storefront-l4/deployment.yaml` | `apps/v1` `Deployment` | Authored |
| `apps/storefront-l4/service.yaml` | `v1` `Service` LoadBalancer | Authored |
| `apps/storefront-l7/backend-v1.yaml` | `Deployment` + `Service` | Authored |
| `apps/storefront-l7/backend-v2.yaml` | `Deployment` + `Service` | Authored |
| `apps/storefront-l7/gateway.yaml` | `gateway.networking.k8s.io/v1` `Gateway` | Authored |
| `apps/storefront-l7/httproute.yaml` | `gateway.networking.k8s.io/v1` `HTTPRoute` | Authored |
| `apps/scale-me/deployment.yaml` | `Deployment` | Authored |
| `.github/workflows/deploy-argocd.yaml` | GitHub Actions | Authored |
| `ci/azure-pipelines/deploy-argocd.yml` | Azure DevOps | Authored |

Helm (Argo CD, optional AGfC controller) also creates in-cluster objects listed in Laurel-POC.md. Those are **not** stored as YAML in this repo.

---

## 6. Create-and-sync order

1. Push an empty-ish repo with `infra/`, `bootstrap/`, `ci/`, docs.
2. Run `infra/00` → `01` → `02`. Cluster exists; NAP default NodePool exists; Argo CD does not.
3. **Manual:** `helm upgrade --install` with `bootstrap/argocd/values.yaml`.  
   **Or CI/CD:** push `bootstrap/argocd/` to `main` and let the workflow run.
4. `kubectl apply -f bootstrap/root/` (or the same CI job).
5. Commit `platform/` and `apps/` and `gitops/applications/`. Root Application creates children. Kyverno and Karpenter CRs land first (sync waves).
6. Enable AGfC add-on **or** Helm controller (`infra/03-*`).
7. Wait until `ApplicationLoadBalancer` is `Deployment=True`.
8. Confirm L4 Service EXTERNAL-IP, L7 Gateway FQDN, and Karpenter scale.

If Kyverno becomes Ready after apps, the first app sync may fail admission; Argo CD retries. Prefer waves so policies exist first.

---

## 7. What not to put in this repo

- Kubeconfig files, Azure client secrets, Argo CD admin passwords.
- Hand-exported YAML from the `MC_` resource group (Load Balancer, public IPs, NICs).
- Open-source Karpenter Helm chart next to NAP.
- A second pipeline that `kubectl apply`s `apps/`.
- Both AGfC add-on enablement and AGfC Helm install as “always on” steps.

---

## 8. Mapping to the original stack

| Technology | Lives in this tree | Install mechanism |
| --- | --- | --- |
| AKS + networking | `infra/` | Azure CLI |
| Argo CD | `bootstrap/argocd`, `ci/`, `.github/` | Helm (manual + CI/CD) |
| Argo CD apps | `bootstrap/root`, `gitops/applications` | Manifests |
| Karpenter / NAP | `infra/` (NAP add-on) + `platform/karpenter` (CRs) | Add-on + manifests |
| Kyverno | `platform/kyverno` | Manifests (Kustomize) |
| AGfC controller | `infra/` add-on **or** `platform/agfc/controller` Helm | Add-on or Helm |
| AGfC Azure + Gateway API | `platform/agfc`, `apps/storefront-l7` | Manifests |
| Azure Load Balancer | AKS default SLB + `apps/storefront-l4/service.yaml` | Add-on (cluster) + Service manifest |
| Sample apps | `apps/` | Manifests via Argo CD |

Once this tree exists in Git, follow [Laurel-POC.md](./Laurel-POC.md) section 9 for the operational runbook and section 10 for the test plan.
