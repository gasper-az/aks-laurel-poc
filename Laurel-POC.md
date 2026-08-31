# Laurel POC — AKS platform stack

This document is the implementation plan for a **proof-of-concept AKS cluster** built only for this exercise. It covers cluster configuration, how each technology is installed and tested, the manifests you must author, sample applications, and official documentation.

**Install order for this POC:** create the cluster, **install Argo CD first with Helm**, then manage every other operator and workload as GitOps manifests. Where Azure provides an AKS add-on, both the add-on path and the manifest path are documented. Pick **one** path per component on a given cluster; do not mix them.

Repo folder layout, file names, and CI pipeline files are defined in [Laurel-POC-architecture.md](./Laurel-POC-architecture.md).

The stack under test:

| Technology | Role in the POC | How this POC installs it |
| --- | --- | --- |
| Azure Kubernetes Service (AKS) | Managed Kubernetes control plane and node lifecycle | Azure CLI at cluster create |
| Argo CD | GitOps continuous delivery | **Helm first** (manual and CI/CD). Azure extension is an alternative, not the default |
| Azure Load Balancer (Standard SKU) | Layer 4 inbound services and cluster egress SNAT | AKS-managed at cluster create. Workload frontends are **Service manifests** |
| Application Gateway for Containers (AGfC) | Layer 7 HTTP(S) ingress via Gateway API | **AKS add-on** *or* Helm controller. Azure/Kubernetes resources are **manifests** in both cases |
| Karpenter (AKS Node Auto-Provisioning) | Just-in-time node provisioning | **NAP add-on** at cluster create (recommended). Node shape is **manifests** (`NodePool`, `AKSNodeClass`) |
| Kyverno | Admission policy engine | **Manifests** (upstream `install.yaml` + AKS patches + `ClusterPolicy`). No AKS add-on |

---

## 1. Recommended architecture (POC)

### 1.1 Cluster SKU: AKS Standard, not Automatic

Microsoft recommends **AKS Automatic** for most production workloads because Node Auto-Provisioning (NAP / Karpenter) is preconfigured. This POC should use **AKS Standard** instead.

Reasons:

- You need explicit control of networking, node pools, add-ons, and operators.
- Argo CD is installed with Helm and then used as the delivery plane for everything else.
- Kyverno, Karpenter `NodePool` / `AKSNodeClass`, Azure Load Balancer `Service` objects, and Application Gateway for Containers Gateway API objects must be visible YAML.
- AKS Automatic hides or constrains several of those knobs.

NAP (managed Karpenter) is enabled on Standard with `--node-provisioning-mode Auto`. Do **not** also install the open-source Karpenter Helm chart. AKS NAP already deploys and manages Karpenter in the control plane, based on [Karpenter](https://karpenter.sh) and the [AKS Karpenter provider](https://github.com/Azure/karpenter-provider-azure).

### 1.2 Target topology

```text
Git repository  ──(Helm CI/CD or manual helm)──►  Argo CD  (installed first)
                         │
                         └──(GitOps sync)──►  Kyverno, Karpenter CRs, AGfC CRs, sample apps

Internet
  │
  ├─ Azure Load Balancer (Standard, L4)
  │     └─ Service type LoadBalancer  →  storefront-l4 pods
  │
  └─ Application Gateway for Containers (L7)
        └─ Gateway + HTTPRoute        →  backend-v1 / backend-v2 pods

AKS cluster (Standard tier)
  ├─ System node pool (fixed, tainted CriticalAddonsOnly)
  │     kube-system, argocd, kyverno, alb-controller
  └─ NAP / Karpenter user nodes (on demand)
        sample applications, scale-out test

VNet 10.10.0.0/16
  ├─ snet-aks-nodes   10.10.0.0/22     nodes (system + NAP)
  ├─ snet-agfc        10.10.4.0/24     AGfC association (delegated, exactly /24)
  └─ Overlay pod CIDR 10.244.0.0/16    pods (not VNet-routable)
     Service CIDR     10.0.0.0/16      ClusterIP services
```

### 1.3 Best practices this POC should follow

These are Day-0 decisions that are hard or impossible to change later. Apply them even though the cluster is temporary.

| Area | Decision for this POC | Why |
| --- | --- | --- |
| Control plane SKU | Standard tier | Zone-redundant API server, 99.95% SLA |
| Region | One AGfC-supported region with 3 availability zones (recommended: `eastus2` or `westeurope`) | AGfC is region-limited; zones improve NAP node placement |
| Zones | `1 2 3` on the system pool | Spread system add-ons |
| Identity | User-assigned managed identity | Required for custom VNet + NAP; service principals are **not** supported with NAP |
| Auth to API server | Microsoft Entra ID + Kubernetes RBAC | No local accounts in production patterns; fine for POC too |
| Workload identity | OIDC issuer + workload identity enabled | Required by AGfC (add-on or Helm) |
| Networking plugin | Azure CNI Overlay | Pod IPs from overlay CIDR; VNet stays small; required/supported by AGfC and NAP |
| Data plane / policy | Cilium (`--network-dataplane cilium`, `--network-policy cilium`) | Microsoft recommendation with NAP; eBPF, NetworkPolicy, no kube-proxy |
| Load balancer SKU | Standard (default) | Required for NAP on a custom VNet; Basic is unsupported |
| Outbound type | `loadBalancer` (default) | Simplest for a public POC; cannot be changed after NAP is enabled |
| API server | Public, authorized IP ranges if you have a stable office/VPN IP | Private cluster is better for production, more moving parts for a POC |
| System pool | Dedicated, 2 nodes, 4+ vCPU, Azure Linux, `CriticalAddonsOnly` taint | Platform pods stay off Karpenter nodes |
| User compute | NAP / Karpenter only | Demonstrates Karpenter; do not enable cluster autoscaler (incompatible with NAP) |
| Node OS | Azure Linux 3 (`AzureLinux`) | Smaller image, faster boot; Azure Linux 2.0 is retired |
| Disks | Ephemeral OS where the SKU allows | Faster Karpenter scale-up |
| Delivery | Helm for Argo CD only; GitOps manifests for the rest | Matches the POC goal: test Helm for Argo, manifests for operators |
| Secrets | No long-lived kubeconfigs in Git; no secrets in YAML | Use Azure login in CI; Argo admin secret stays in-cluster |
| Observability | Optional Container Insights + Managed Prometheus | Useful, not required to prove the stack |

Production items you can skip for this POC: private API server, Azure Firewall egress, WAF (optional extra), Fleet Manager, LTS/Premium tier, reserved instances.

---

## 2. Prerequisites

### 2.1 People, tools, and Azure access

| Prerequisite | Detail |
| --- | --- |
| Azure subscription | Contributor (or equivalent) on a resource group you can create and delete |
| Azure CLI | **2.76.0 or later** (NAP requirement). Check with `az --version` |
| CLI extensions | `aks-preview`, `alb`. Add `k8s-extension` only if you try the Argo CD Azure extension alternative |
| kubectl | Matching a currently supported AKS Kubernetes version |
| Helm | **3.x required** — this is how Argo CD is installed |
| Git | Source of truth for Helm values, operator manifests, and applications |
| CI system (optional second path) | GitHub Actions or Azure DevOps with permission to `az aks get-credentials` and `helm upgrade` |
| Quota | At least ~16–32 D-series vCPUs in the target region (system pool + NAP scale test) |
| Region | Must be in the [AGfC supported regions](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/overview#supported-regions) list |

Register providers and (where still required) preview features:

```bash
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking
az provider register --namespace Microsoft.KubernetesConfiguration

az extension add --name aks-preview --upgrade
az extension add --name alb

# Only needed if you use the AGfC AKS add-on path (preview)
az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview
az feature register --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview
```

Wait until `az feature show` reports `Registered`, then run `az provider register --namespace Microsoft.ContainerService` again.

Suggested local variables. Replace names and IDs before running anything:

```bash
export LOCATION="eastus2"
export RG_NAME="rg-laurel-poc"
export CLUSTER_NAME="aks-laurel-poc"
export VNET_NAME="vnet-laurel-poc"
export IDENTITY_NAME="id-aks-laurel-poc"
export K8S_VERSION="$(az aks get-versions --location $LOCATION --query 'values[0].version' -o tsv)"
```

### 2.2 Azure resources this POC needs

Create these **before** `az aks create`. AKS also creates a managed node resource group (`MC_<rg>_<cluster>_<region>`) that you must not edit by hand.

| Resource | Purpose |
| --- | --- |
| Resource group | All POC resources; delete the group to tear everything down |
| User-assigned managed identity | Cluster identity for VNet join, NAP, and Azure RBAC |
| Virtual network `10.10.0.0/16` | Shared network for nodes and AGfC |
| Subnet `snet-aks-nodes` `/22` | System nodes and Karpenter nodes |
| Subnet `snet-agfc` `/24` | Application Gateway for Containers association. **Must be `/24`**. Delegated to `Microsoft.ServiceNetworking/trafficControllers` |
| AKS cluster (Standard) | Control plane + system pool + NAP |
| Standard Azure Load Balancer | Created by AKS in the `MC_` group. Used for L4 services and egress |
| Public IP(s) on that load balancer | Outbound SNAT; extra frontend IPs appear when you create `LoadBalancer` Services |
| Application Gateway for Containers | Created from an `ApplicationLoadBalancer` CR after the ALB Controller is installed (add-on or Helm) |
| AGfC Frontend + Association | Created with the Gateway / ApplicationLoadBalancer resources |
| AGfC controller identity | Add-on creates `applicationloadbalancer-<cluster>`. Helm path requires you to create `azure-alb-identity` |
| Optional: Log Analytics workspace | Control plane logs including Karpenter events |
| Optional: Azure Container Registry | Only if you want private images |

Do **not** create: Basic Load Balancer, a second cluster autoscaler, Windows node pools, dual-stack/IPv6, or a self-hosted Karpenter Helm release next to NAP.

### 2.3 How the AKS cluster must be configured (networking)

This is the most important Day-0 section. Recreating the cluster is the only way to change most of these settings.

#### Virtual network and CIDRs

Use a **bring-your-own VNet**. AKS-managed VNets work, and the AGfC add-on can auto-create `aks-appgateway`, but a custom VNet makes subnet sizes, delegation, and NSGs explicit — which is the point of this POC.

| Space | CIDR | Notes |
| --- | --- | --- |
| VNet | `10.10.0.0/16` | Change if your org already uses this range |
| Node subnet | `10.10.0.0/22` (1024 IPs) | Nodes only. Overlay pods do **not** consume these IPs |
| AGfC subnet | `10.10.4.0/24` | Microsoft requires **/24**. One AGfC deployment per subnet. Delegate to `Microsoft.ServiceNetworking/trafficControllers` |
| Pod overlay CIDR | `10.244.0.0/16` | Must not overlap the VNet or the service CIDR |
| Service CIDR | `10.0.0.0/16` | ClusterIP range. Must not overlap the VNet |
| DNS service IP | `10.0.0.10` | Must sit inside the service CIDR |

AGfC and the AKS cluster **must be in the same VNet**. Peering AGfC in another VNet is not supported.

Do **not** use kubenet. AGfC does not support it.

#### Data plane

```text
--network-plugin azure
--network-plugin-mode overlay
--network-dataplane cilium
--network-policy cilium
```

Effects:

- Pods get IPs from `10.244.0.0/16`, not from the node subnet.
- AGfC (ALB Controller ≥ 1.7.9) extends overlay routing to the AGfC subnet so it can reach pods directly.
- kube-proxy is not used; Cilium handles service routing.

#### Ingress vs L4

| Path | Component | When to use in the POC |
| --- | --- | --- |
| Layer 4 | Azure Load Balancer + `Service` `type: LoadBalancer` | TCP/UDP, simple public IP, outbound SNAT |
| Layer 7 | Application Gateway for Containers + Gateway API | HTTP path/host routing, TLS, optional WAF |

Keep L4 and L7 sample apps on separate Services so each front door is testable on its own.

#### Egress

Keep the default outbound type `loadBalancer`. NAP **does not allow changing outbound type after cluster creation**.

#### API server

Public API server is enough. If you have a stable public IP, lock it down:

```bash
--api-server-authorized-ip-ranges "<your-public-ip>/32"
```

#### NSGs

Start without custom NSGs. If a review requires them:

- Node subnet: allow Azure Load Balancer probes (`AzureLoadBalancer` service tag), allow AGfC subnet → nodes, allow nodes → Internet 443, allow intra-VNet.
- AGfC subnet: allow Internet → 80/443 inbound.

#### Identity and RBAC on the network

The cluster user-assigned identity needs **Network Contributor** on the VNet (or at least on `snet-aks-nodes`) so AKS and Karpenter can attach NICs.

The AGfC controller identity needs:

- **AppGw for Containers Configuration Manager** on the `MC_` resource group.
- **Network Contributor** on the AGfC subnet (`Microsoft.Network/virtualNetworks/subnets/join/action`).

The add-on assigns these for you. The Helm/manifest path requires you to assign them (section 6).

### 2.4 Create the Azure foundation

```bash
az group create --name $RG_NAME --location $LOCATION

az identity create \
  --name $IDENTITY_NAME \
  --resource-group $RG_NAME \
  --location $LOCATION

IDENTITY_ID=$(az identity show -g $RG_NAME -n $IDENTITY_NAME --query id -o tsv)
IDENTITY_PRINCIPAL=$(az identity show -g $RG_NAME -n $IDENTITY_NAME --query principalId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az network vnet create \
  --name $VNET_NAME \
  --resource-group $RG_NAME \
  --location $LOCATION \
  --address-prefixes 10.10.0.0/16

az network vnet subnet create \
  --resource-group $RG_NAME \
  --vnet-name $VNET_NAME \
  --name snet-aks-nodes \
  --address-prefixes 10.10.0.0/22

az network vnet subnet create \
  --resource-group $RG_NAME \
  --vnet-name $VNET_NAME \
  --name snet-agfc \
  --address-prefixes 10.10.4.0/24 \
  --delegations Microsoft.ServiceNetworking/trafficControllers

VNET_ID=$(az network vnet show -g $RG_NAME -n $VNET_NAME --query id -o tsv)
NODE_SUBNET_ID=$(az network vnet subnet show -g $RG_NAME --vnet-name $VNET_NAME -n snet-aks-nodes --query id -o tsv)
AGFC_SUBNET_ID=$(az network vnet subnet show -g $RG_NAME --vnet-name $VNET_NAME -n snet-agfc --query id -o tsv)

az role assignment create \
  --assignee-object-id $IDENTITY_PRINCIPAL \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope $VNET_ID
```

### 2.5 Create the AKS cluster

Do **not** enable the AGfC add-on at create time. Argo CD is installed first. AGfC is added later, either as an add-on or via Helm, so you can compare both paths.

NAP (Karpenter) **is** enabled at create because it is a cluster feature, not a GitOps operator you install with YAML.

```bash
az aks create \
  --resource-group $RG_NAME \
  --name $CLUSTER_NAME \
  --location $LOCATION \
  --sku base \
  --tier standard \
  --kubernetes-version "$K8S_VERSION" \
  --assign-identity "$IDENTITY_ID" \
  --enable-managed-identity \
  --enable-aad \
  --enable-azure-rbac \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane cilium \
  --network-policy cilium \
  --pod-cidr 10.244.0.0/16 \
  --service-cidr 10.0.0.0/16 \
  --dns-service-ip 10.0.0.10 \
  --vnet-subnet-id "$NODE_SUBNET_ID" \
  --load-balancer-sku standard \
  --outbound-type loadBalancer \
  --node-provisioning-mode Auto \
  --nodepool-name system \
  --node-count 2 \
  --node-vm-size Standard_D4s_v5 \
  --os-sku AzureLinux \
  --node-osdisk-type Ephemeral \
  --zones 1 2 3 \
  --nodepool-taints CriticalAddonsOnly=true:NoSchedule \
  --nodepool-labels pool=system \
  --max-pods 110 \
  --generate-ssh-keys
```

Then:

```bash
az aks get-credentials --resource-group $RG_NAME --name $CLUSTER_NAME --overwrite-existing

kubectl get nodes -o wide
kubectl get pods -n kube-system | grep -E "cilium|konnectivity"
kubectl get nodepools.karpenter.sh
```

Expected:

- Two system nodes, Ready, tainted `CriticalAddonsOnly`, labeled `pool=system`.
- Cilium running; no kube-proxy.
- Default Karpenter `NodePool` named `default` (and usually `system-surge`).
- **No** `alb-controller` yet. **No** Argo CD yet.

---

## 3. Argo CD first (Helm)

Argo CD is the first in-cluster operator. After it is healthy, every other YAML in this POC is applied by Argo CD from Git — not by ad-hoc `kubectl apply`, except for the one-time bootstrap `Application`.

You will test **two ways to install/upgrade Argo CD itself with Helm**:

| Path | When to use | What runs Helm |
| --- | --- | --- |
| **Manual** | Laptop bootstrap, debugging, first cluster | You, against `bootstrap/argocd/values.yaml` |
| **CI/CD** | Repeatable installs and chart/value upgrades | GitHub Actions or Azure DevOps, same values file |

Those two paths only manage **Argo CD**. They do not deploy sample apps. Apps and other operators are GitOps after Argo exists.

Do not expose Argo CD on a public Load Balancer for this POC unless you add Entra ID SSO. Use port-forward.

### 3.1 Required Helm values

Pin a chart version (`helm search repo argo/argo-cd --versions`). The values below are the contract for both manual and CI/CD installs. File: `bootstrap/argocd/values.yaml`.

```yaml
# bootstrap/argocd/values.yaml
# POC: single-cluster GitOps control plane on the AKS system node pool.
global:
  domain: argocd.local
  nodeSelector:
    pool: system
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists

crds:
  install: true
  keep: false

dex:
  enabled: false

notifications:
  enabled: false

applicationSet:
  replicas: 1

controller:
  replicas: 1
  metrics:
    enabled: true

server:
  replicas: 1
  extraArgs:
    - --insecure
  service:
    type: ClusterIP

repoServer:
  replicas: 1

redis-ha:
  enabled: false

redis:
  enabled: true

configs:
  params:
    server.insecure: true
    application.namespaces: argocd
  cm:
    timeout.reconciliation: 60s
    application.instanceLabelKey: argocd.argoproj.io/instance
```

Why these fields:

| Value | Purpose |
| --- | --- |
| `global.nodeSelector.pool=system` | Keep Argo CD off Karpenter nodes |
| `global.tolerations` for `CriticalAddonsOnly` | System pool is tainted |
| `redis-ha.enabled=false` | HA Redis wants 3+ nodes; this POC has a 2-node system pool |
| `controller/server/repoServer.replicas=1` | POC size |
| `dex.enabled=false` | Skip SSO until you add Entra ID |
| `server.extraArgs: --insecure` plus `configs.params.server.insecure` | TLS terminated at port-forward only |
| `crds.install=true` | Helm owns Application/AppProject CRDs |
| `application.namespaces: argocd` | Applications live in `argocd` (App of Apps) |

Related Kubernetes objects Helm will create (you do not author these by hand):

| Kind | Typical name | Purpose |
| --- | --- | --- |
| Namespace | `argocd` | Isolation |
| CustomResourceDefinition | `applications.argoproj.io`, `appprojects.argoproj.io`, `applicationsets.argoproj.io` | GitOps APIs |
| Deployment | `argocd-server`, `argocd-repo-server`, `argocd-applicationset-controller`, `argocd-redis` | Control plane |
| StatefulSet | `argocd-application-controller` | Desired vs live state |
| Service | `argocd-server`, `argocd-repo-server`, `argocd-redis` | In-cluster access |
| ConfigMap | `argocd-cm`, `argocd-cmd-params-cm`, `argocd-rbac-cm` | Settings |
| Secret | `argocd-secret`, `argocd-initial-admin-secret` | TLS and admin password |
| ServiceAccount / Role / ClusterRole / Bindings | several | RBAC |

### 3.2 Manual Helm install

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.23 \
  --values bootstrap/argocd/values.yaml \
  --wait \
  --timeout 10m
```

Replace `7.8.23` with the version you pin in Git. Verify:

```bash
kubectl get pods -n argocd
kubectl get crd | grep argoproj.io

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

kubectl -n argocd port-forward svc/argocd-server 8080:80
# Open http://localhost:8080  user: admin
```

Upgrade later with the same command (`helm upgrade --install` is idempotent).

Uninstall (only if you are throwing away the GitOps plane):

```bash
helm uninstall argocd -n argocd
kubectl delete namespace argocd
```

### 3.3 CI/CD Helm install

The pipeline does exactly what the manual command does: authenticate to Azure, get AKS credentials, `helm upgrade --install` with the **same** values file. Trigger it when `bootstrap/argocd/**` changes.

Required CI identity:

- Federated credential (workload identity) or a service principal with **Azure Kubernetes Service Cluster Admin** (or equivalent) on the cluster.
- No kubeconfig stored as a pipeline secret.

#### GitHub Actions

File: `.github/workflows/deploy-argocd.yaml`

```yaml
name: deploy-argocd
on:
  push:
    branches: [main]
    paths:
      - bootstrap/argocd/**
      - .github/workflows/deploy-argocd.yaml
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

env:
  AZURE_RESOURCE_GROUP: rg-laurel-poc
  AKS_CLUSTER_NAME: aks-laurel-poc
  ARGOCD_NAMESPACE: argocd
  ARGOCD_CHART_VERSION: 7.8.23

jobs:
  helm-upgrade:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Azure login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Get AKS credentials
        uses: azure/aks-set-context@v4
        with:
          resource-group: ${{ env.AZURE_RESOURCE_GROUP }}
          cluster-name: ${{ env.AKS_CLUSTER_NAME }}
          admin: true

      - name: Helm upgrade --install Argo CD
        run: |
          helm repo add argo https://argoproj.github.io/argo-helm
          helm repo update
          helm upgrade --install argocd argo/argo-cd \
            --namespace "${ARGOCD_NAMESPACE}" \
            --create-namespace \
            --version "${ARGOCD_CHART_VERSION}" \
            --values bootstrap/argocd/values.yaml \
            --wait \
            --timeout 10m

      - name: Verify
        run: kubectl get pods -n argocd
```

GitHub secrets (or environment variables) needed: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`. Create an app registration and federated credential for `repo:<org>/<repo>:ref:refs/heads/main`.

#### Azure DevOps

File: `ci/azure-pipelines/deploy-argocd.yml`

```yaml
trigger:
  branches:
    include: [main]
  paths:
    include:
      - bootstrap/argocd/**
      - ci/azure-pipelines/deploy-argocd.yml

pool:
  vmImage: ubuntu-latest

variables:
  azureServiceConnection: laurel-poc-azure
  resourceGroup: rg-laurel-poc
  aksName: aks-laurel-poc
  argocdChartVersion: 7.8.23

steps:
  - task: AzureCLI@2
    displayName: Helm upgrade --install Argo CD
    inputs:
      azureSubscription: $(azureServiceConnection)
      scriptType: bash
      scriptLocation: inlineScript
      inlineScript: |
        az aks get-credentials -g "$(resourceGroup)" -n "$(aksName)" --admin --overwrite-existing
        helm repo add argo https://argoproj.github.io/argo-helm
        helm repo update
        helm upgrade --install argocd argo/argo-cd \
          --namespace argocd \
          --create-namespace \
          --version "$(argocdChartVersion)" \
          --values bootstrap/argocd/values.yaml \
          --wait \
          --timeout 10m
        kubectl get pods -n argocd
```

The Azure DevOps service connection must be able to get admin kubeconfig for the cluster.

#### What CI/CD is *not* for

Do not add `kubectl apply -f apps/` to this pipeline. After Argo CD is installed, a Git commit under `platform/` or `apps/` is enough. Argo CD reconciles. That is the GitOps half of the POC.

### 3.4 Bootstrap manifests (required after Helm)

Helm installs the control plane. It does not watch Git until you create an `AppProject` and a root `Application`. Apply these **once** after Helm succeeds (manually or as a last CI step). After that, Argo CD manages children from Git.

#### AppProject

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: laurel-poc
  namespace: argocd
spec:
  description: Laurel POC GitOps project
  sourceRepos:
    - https://github.com/<org>/laurel-poc.git
  destinations:
    - namespace: "*"
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
```

Fields that matter:

| Field | Purpose |
| --- | --- |
| `sourceRepos` | Git URLs Argo CD may pull. Tighten to this repo only |
| `destinations` | Cluster + namespaces this project may deploy to |
| `clusterResourceWhitelist` | Allow CRDs, ClusterPolicy, NodePool (cluster-scoped) |

#### Root Application (App of Apps)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: laurel-poc-root
  namespace: argocd
spec:
  project: laurel-poc
  source:
    repoURL: https://github.com/<org>/laurel-poc.git
    targetRevision: HEAD
    path: gitops/applications
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

`gitops/applications/` contains child `Application` manifests (Kyverno, Karpenter CRs, AGfC CRs, sample apps). Each child is documented in [Laurel-POC-architecture.md](./Laurel-POC-architecture.md).

Child `Application` shape (repeat per component):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-kyverno
  namespace: argocd
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

`ServerSideApply=true` is recommended for Kyverno CRDs and large install manifests.

Apply bootstrap:

```bash
kubectl apply -f bootstrap/root/appproject.yaml
kubectl apply -f bootstrap/root/root-application.yaml
kubectl get applications -n argocd
```

Or add those two files as a final CI step after Helm.

### 3.5 Alternative: Azure Argo CD cluster extension (not the default)

AKS/Arc can install Argo CD as extension type `Microsoft.ArgoCD` (preview). Do **not** use this on the same cluster as the Helm release. It is documented so you can compare later:

```bash
az extension add -n k8s-extension
az k8s-extension create \
  --resource-group $RG_NAME \
  --cluster-name $CLUSTER_NAME \
  --cluster-type managedClusters \
  --name argocd \
  --extension-type Microsoft.ArgoCD \
  --release-train Preview \
  --config "redis-ha.enabled=false" \
  --config "controller.replicas=1" \
  --config "server.replicas=1"
```

This POC’s test plan assumes **Helm**.

### 3.6 How to verify Argo CD

| Check | Command / action | Expected |
| --- | --- | --- |
| Pods | `kubectl get pods -n argocd` | All Running |
| CRDs | `kubectl get crd \| grep argoproj` | Application, AppProject, ApplicationSet |
| UI | port-forward + admin login | UI loads |
| Root app | `kubectl get application laurel-poc-root -n argocd` | Synced/Healthy after Git is populated |
| GitOps loop | Commit a replica change under `apps/` | Cluster matches Git without `kubectl apply` |

---

## 4. Karpenter operator

**Preferred path:** AKS Node Auto-Provisioning add-on (already enabled at cluster create) plus **manifests** for `AKSNodeClass` and `NodePool`. Argo CD syncs those manifests.

There is no supported “install Karpenter with a YAML Deployment on AKS” next to NAP. Self-hosted Karpenter is the migration-away-from path, not this POC.

### 4.1 AKS add-on (NAP)

Enabled with `--node-provisioning-mode Auto` (section 2.5). On an existing cluster:

```bash
az aks update \
  --name $CLUSTER_NAME \
  --resource-group $RG_NAME \
  --node-provisioning-mode Auto
```

What the add-on provides (you do not author these):

- Karpenter controller in the AKS control plane
- CRDs: `NodePool`, `NodeClaim`, `AKSNodeClass`
- Default `NodePool` `default` and usually `system-surge`

Limitations: no Windows, no IPv6, no service principals, no `az aks stop`, no outbound-type change, no cluster autoscaler alongside NAP.

### 4.2 Manifests you must author

These are the required custom resources. Sync them with Argo CD from `platform/karpenter/`.

#### AKSNodeClass

API: `karpenter.azure.com/v1beta1`. Azure-specific node settings. Every `NodePool` must reference one.

| Field | Required | Purpose |
| --- | --- | --- |
| `spec.imageFamily` | No | `Ubuntu` (default) or `AzureLinux` |
| `spec.osDiskSizeGB` | No | OS disk; default 128; min 30 |
| `spec.maxPods` | No | 10–250; Overlay default is 250 |
| `spec.vnetSubnetID` | No | Full ARM ID of the node subnet; omit to use cluster `--vnet-subnet-id` |
| `spec.fipsMode` | No | `FIPS` or `Disabled` |
| `spec.artifactStreaming.enabled` | No | Requires Premium ACR |

```yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: laurel-default
spec:
  imageFamily: AzureLinux
  osDiskSizeGB: 128
  maxPods: 110
  # vnetSubnetID: /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-laurel-poc/providers/Microsoft.Network/virtualNetworks/vnet-laurel-poc/subnets/snet-aks-nodes
```

#### NodePool

API: `karpenter.sh/v1`. Scheduling and disruption policy.

| Field | Required | Purpose |
| --- | --- | --- |
| `spec.template.spec.nodeClassRef` | Yes | Points at an `AKSNodeClass` (`group`, `kind`, `name`) |
| `spec.template.spec.requirements` | Yes | SKU, arch, OS, capacity-type, zones |
| `spec.limits` | Recommended | Cap CPU/memory so the POC cannot empty the subscription quota |
| `spec.disruption.consolidationPolicy` | No | `WhenEmptyOrUnderutilized` for the scale-in demo |
| `spec.disruption.consolidateAfter` | No | How long to wait before removing underused nodes |
| `spec.weight` | No | Higher wins when several pools match |
| `spec.replicas` | No | Static pool size; not used in this POC |

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workload
spec:
  weight: 10
  limits:
    cpu: "32"
    memory: 64Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
  template:
    metadata:
      labels:
        intent: workload
    spec:
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: laurel-default
      expireAfter: Never
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.azure.com/sku-family
          operator: In
          values: ["D"]
        - key: karpenter.azure.com/sku-cpu
          operator: Lt
          values: ["9"]
        - key: kubernetes.azure.com/mode
          operator: In
          values: ["user"]
```

Optional Spot pool:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workload-spot
spec:
  weight: 20
  limits:
    cpu: "16"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
  template:
    spec:
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: laurel-default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: karpenter.azure.com/sku-family
          operator: In
          values: ["D"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
```

If both Spot and on-demand match, NAP prefers Spot. NAP requires **at least one** `NodePool`. Do not delete `default` until `workload` is Accepted.

### 4.3 Self-hosted Karpenter manifests (not used)

Open-source Karpenter is a Deployment + rbac + webhook in `kube-system` (or `karpenter`). On AKS you would also need the Azure provider and permissions to create VMs. Microsoft’s supported path is NAP. If a Helm chart is already installed, migrate with `az aks update --node-provisioning-mode Auto` and do not keep both controllers.

### 4.4 How to verify

```bash
kubectl get nodepool
kubectl get aksnodeclass
kubectl get nodeclaims
kubectl get nodes -l karpenter.sh/nodepool -o wide
kubectl get events --field-selector source=karpenter-events
```

Scale `scale-me` (section 8). A `NodeClaim` and a new node should appear, then consolidate after scale-in.

Karpenter logs (control plane):

```kusto
AKSControlPlane
| where Category == "karpenter-events"
```

---

## 5. Kyverno operator

There is **no AKS add-on** for Kyverno. This POC installs it with **manifests**: vendor the upstream `install.yaml`, patch it for AKS, then add `ClusterPolicy` objects. Argo CD syncs the folder `platform/kyverno/`.

Do not install Kyverno in `kube-system`. Do not co-locate unrelated apps in the `kyverno` namespace.

### 5.1 Required upstream resources (install.yaml)

Pin a tagged release. Example (replace the version when you vendor):

```bash
curl -L -o platform/kyverno/upstream/install.yaml \
  https://github.com/kyverno/kyverno/releases/download/v1.16.2/install.yaml
```

Only tagged release YAML is supported. `install.yaml` typically includes:

| Kind | Names (typical) | Purpose |
| --- | --- | --- |
| Namespace | `kyverno` | Dedicated namespace |
| CustomResourceDefinition | `clusterpolicies.kyverno.io`, `policies.kyverno.io`, `policyexceptions.kyverno.io`, `updaterequests.kyverno.io`, `clustercleanuppolicies.kyverno.io`, `cleanuppolicies.kyverno.io`, `globalcontextentries.kyverno.io` | Policy APIs |
| ServiceAccount | `kyverno-admission-controller`, `kyverno-background-controller`, `kyverno-cleanup-controller`, `kyverno-reports-controller` | Per-controller identity |
| ClusterRole / ClusterRoleBinding / Role / RoleBinding | several, often aggregated | API permissions |
| ConfigMap | `kyverno`, `kyverno-metrics` | Webhook exclude lists, metrics |
| Deployment | `kyverno-admission-controller`, `kyverno-background-controller`, `kyverno-cleanup-controller`, `kyverno-reports-controller` | Controllers |
| Service | `kyverno-svc`, `kyverno-svc-metrics`, plus per-controller services | Webhook endpoint |
| ValidatingWebhookConfiguration | `kyverno-resource-validating-webhook-cfg`, `kyverno-policy-validating-webhook-cfg`, `kyverno-exception-validating-webhook-cfg`, `kyverno-cleanup-validating-webhook-cfg` | Admission |
| MutatingWebhookConfiguration | `kyverno-resource-mutating-webhook-cfg`, `kyverno-policy-mutating-webhook-cfg` | Mutation |

You do not rewrite those objects. You **patch** them.

### 5.2 Required AKS patches (manifests you author)

AKS Admission Enforcer fights Kyverno webhooks unless they carry `admissions.enforcer/disabled: "true"`. Kyverno Helm sets this by default since 1.12; the raw `install.yaml` may not. Set it explicitly.

System-pool placement also needs `nodeSelector` and `CriticalAddonsOnly` tolerations.

Kustomize overlay (`platform/kyverno/kustomization.yaml`):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kyverno
resources:
  - upstream/install.yaml
  - policies/disallow-privileged.yaml
  - policies/require-labels.yaml
  - policies/add-env-label.yaml
patches:
  - path: patches/webhook-aks.yaml
    target:
      kind: ValidatingWebhookConfiguration
  - path: patches/webhook-aks.yaml
    target:
      kind: MutatingWebhookConfiguration
  - path: patches/system-pool.yaml
    target:
      kind: Deployment
      namespace: kyverno
```

`platform/kyverno/patches/webhook-aks.yaml`:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: unused
  annotations:
    admissions.enforcer/disabled: "true"
```

`platform/kyverno/patches/system-pool.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unused
  namespace: kyverno
spec:
  template:
    spec:
      nodeSelector:
        pool: system
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
```

Argo CD `Application` for this folder should use `ServerSideApply=true`. For Helm-style ignoreDifferences on aggregated ClusterRoles, see Kyverno’s Argo CD platform notes if you later switch Kyverno to Helm. Manifest + SSA is enough for the POC.

Optional: scale admission replicas down to 2 in a patch if the upstream manifest wants more than the system pool can host.

### 5.3 Required policy manifests

These are the policies this POC must demonstrate.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
  annotations:
    policies.kyverno.io/title: Disallow Privileged
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: privileged-containers
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["poc-l4", "poc-l7", "poc-scale"]
      validate:
        message: Privileged containers are not allowed in POC application namespaces.
        pattern:
          spec:
            =(securityContext):
              =(privileged): false
            containers:
              - =(securityContext):
                  =(privileged): false
```

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-app-owner-labels
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-labels
      match:
        any:
          - resources:
              kinds: ["Deployment"]
              namespaces: ["poc-l4", "poc-l7", "poc-scale"]
      validate:
        message: Deployments must have labels app and owner.
        pattern:
          metadata:
            labels:
              app: "?*"
              owner: "?*"
```

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-env-label
spec:
  rules:
    - name: add-env-poc
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["poc-l4", "poc-l7", "poc-scale"]
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              +(env): poc
```

`ClusterPolicy` fields used here:

| Field | Purpose |
| --- | --- |
| `spec.validationFailureAction` | `Enforce` blocks; `Audit` only reports |
| `spec.background` | Also scan existing objects |
| `spec.rules[].match` | Scope to kinds and namespaces |
| `spec.rules[].validate.pattern` | Allow-list shape (`?*` = required non-empty) |
| `spec.rules[].mutate.patchStrategicMerge` | Additive labels; `+(env)` means set if missing |

### 5.4 How to verify

```bash
kubectl get pods -n kyverno
kubectl get validatingwebhookconfigurations | grep kyverno
kubectl get clusterpolicies

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: should-fail
  namespace: poc-l7
spec:
  replicas: 1
  selector:
    matchLabels:
      app: should-fail
  template:
    metadata:
      labels:
        app: should-fail
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          securityContext:
            privileged: true
EOF
```

Expect admission denial (missing `owner` and/or `privileged: true`). Sample apps in section 8 must still be admitted.

---

## 6. Application Gateway for Containers

AGfC has **two controller install paths**. The Kubernetes traffic manifests (`ApplicationLoadBalancer`, `Gateway`, `HTTPRoute`) are the same either way. Do not run the add-on and Helm on the same cluster.

| Path | Controller location | Identity | When to use |
| --- | --- | --- | --- |
| **AKS add-on** | `kube-system`, managed by AKS | `applicationloadbalancer-<cluster>` created for you | Less Azure glue; updates managed; **required** on AKS Automatic |
| **Helm / manifests** | `azure-alb-system`, you own the chart | You create `azure-alb-identity` + federated credential | Custom namespace, versions, node selectors |

After the controller is running, Argo CD syncs the Gateway API manifests from `platform/agfc/` and `apps/storefront-l7/`.

### 6.1 AKS add-on

```bash
az aks update \
  --name $CLUSTER_NAME \
  --resource-group $RG_NAME \
  --enable-gateway-api \
  --enable-application-load-balancer
```

Verify:

```bash
kubectl get pods -n kube-system | grep alb-controller
kubectl get gatewayclass azure-alb-external -o yaml
```

`GatewayClass` `azure-alb-external` must show `Accepted=True`. Controller pods: two replicas named `alb-controller-*`.

Add-on identity (do not edit): federated credential namespace `kube-system`, service account `alb-controller-sa`. Roles on the `MC_` group: Network Contributor, AppGw for Containers Configuration Manager, Reader.

On an AKS-managed VNet the add-on creates subnet `aks-appgateway`. This POC uses BYO VNet, so you already created `snet-agfc` with the correct delegation. If the `ApplicationLoadBalancer` stays pending, grant the add-on identity **Network Contributor** on `snet-agfc`.

Disable:

```bash
az aks update -g $RG_NAME -n $CLUSTER_NAME \
  --disable-gateway-api --disable-application-load-balancer
```

### 6.2 Helm / manifest controller (alternative)

Create identity and federation (Azure, not Kubernetes YAML):

```bash
IDENTITY_RESOURCE_NAME="azure-alb-identity"
CONTROLLER_NAMESPACE="azure-alb-system"

az identity create --resource-group $RG_NAME --name $IDENTITY_RESOURCE_NAME
sleep 60
ALB_PRINCIPAL=$(az identity show -g $RG_NAME -n $IDENTITY_RESOURCE_NAME --query principalId -o tsv)
ALB_CLIENT_ID=$(az identity show -g $RG_NAME -n $IDENTITY_RESOURCE_NAME --query clientId -o tsv)
MC_RESOURCE_GROUP=$(az aks show -g $RG_NAME -n $CLUSTER_NAME --query nodeResourceGroup -o tsv)
MC_RESOURCE_GROUP_ID=$(az group show -n $MC_RESOURCE_GROUP --query id -o tsv)
AKS_OIDC_ISSUER=$(az aks show -g $RG_NAME -n $CLUSTER_NAME --query oidcIssuerProfile.issuerUrl -o tsv)

az role assignment create --assignee-object-id $ALB_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --scope $MC_RESOURCE_GROUP_ID --role "AppGw for Containers Configuration Manager"
az role assignment create --assignee-object-id $ALB_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --scope $MC_RESOURCE_GROUP_ID --role "Network Contributor"
az role assignment create --assignee-object-id $ALB_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --scope $AGFC_SUBNET_ID --role "Network Contributor"

az identity federated-credential create \
  --name azure-alb-identity \
  --identity-name $IDENTITY_RESOURCE_NAME \
  --resource-group $RG_NAME \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject "system:serviceaccount:${CONTROLLER_NAMESPACE}:alb-controller-sa"
```

Helm values (`platform/agfc/controller/values.yaml`) if you install the controller with Helm instead of the add-on:

```yaml
albController:
  namespace: azure-alb-system
  podIdentity:
    clientID: "<ALB_CLIENT_ID>"
  controller:
    replicaCount: 2
    nodeSelector:
      pool: system
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
  installGatewayApiCRDs: true
```

```bash
helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
  --namespace azure-alb-system \
  --create-namespace \
  --version 1.11.4 \
  --values platform/agfc/controller/values.yaml
```

Pin `--version` from the [ALB Controller release notes](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/alb-controller-release-notes). Helm creates:

| Kind | Name | Purpose |
| --- | --- | --- |
| Namespace | `azure-alb-system` | Controller isolation |
| Deployment | `alb-controller`, bootstrap components | Program Azure from Gateway API |
| ServiceAccount | `alb-controller-sa` | Workload identity subject |
| CRDs | `applicationloadbalancers.alb.networking.azure.io`, Gateway API CRDs if enabled | Traffic APIs |
| GatewayClass | `azure-alb-external` | Marks Gateways this controller owns |

This POC still prefers **manifests for AGfC traffic objects**. The controller install is the only Helm exception besides Argo CD, and only if you skip the AKS add-on.

### 6.3 Manifests you must author (both paths)

#### Namespace for the Azure ALB resource

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: alb-test-infra
```

#### ApplicationLoadBalancer

API: `alb.networking.azure.io/v1`. Creates the Azure Traffic Controller and association. `spec.associations` is a list of **subnet ARM IDs** (the `/24` delegated subnet).

```yaml
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: alb-laurel
  namespace: alb-test-infra
spec:
  associations:
    - /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-laurel-poc/providers/Microsoft.Network/virtualNetworks/vnet-laurel-poc/subnets/snet-agfc
```

Wait until `status.conditions` has `Accepted=True` and `Deployment=True` (often 5–6 minutes):

```bash
kubectl get applicationloadbalancer alb-laurel -n alb-test-infra -o yaml -w
```

Azure names: `alb-<8 chars>` and `as-<8 chars>`. To choose Azure names, use the BYO ARM deployment instead of this CR.

#### Gateway

API: `gateway.networking.k8s.io/v1`. Listeners: ports **80 and 443 only**.

Required annotations when the ALB is controller-managed:

- `alb.networking.azure.io/alb-namespace`
- `alb.networking.azure.io/alb-name`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway-laurel
  namespace: poc-l7
  annotations:
    alb.networking.azure.io/alb-namespace: alb-test-infra
    alb.networking.azure.io/alb-name: alb-laurel
spec:
  gatewayClassName: azure-alb-external
  listeners:
    - name: http-listener
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
```

BYO frontend alternative: annotation `alb.networking.azure.io/alb-id` (Azure resource ID) and `spec.addresses` of type `alb.networking.azure.io/alb-frontend`.

`status.addresses[0].value` is the `*.alb.azure.com` FQDN. `Programmed=True` means Azure accepted the listener.

#### HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: storefront-route
  namespace: poc-l7
spec:
  parentRefs:
    - name: gateway-laurel
  hostnames:
    - storefront.example.local
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: backend-v1
          port: 8080
    - matches:
        - path:
            type: PathPrefix
            value: /v2
      backendRefs:
        - name: backend-v2
          port: 8080
    - backendRefs:
        - name: backend-v1
          port: 8080
          weight: 80
        - name: backend-v2
          port: 8080
          weight: 20
```

| Field | Purpose |
| --- | --- |
| `parentRefs` | Attaches the route to the Gateway |
| `hostnames` | SNI / Host header |
| `rules[].matches` | Path, header, or query |
| `rules[].backendRefs` | ClusterIP Service name + port. AGfC targets **pod IPs**, not a LoadBalancer Service |
| `weight` | Traffic split |

Keep Gateway, HTTPRoute, and backend Services in `poc-l7`. Cross-namespace refs need a `ReferenceGrant` (`gateway.networking.k8s.io`, currently `v1beta1` / `v1alpha1` depending on the AGfC controller version).

### 6.4 How to verify

```bash
kubectl get gateway gateway-laurel -n poc-l7 -o yaml
FQDN=$(kubectl get gateway gateway-laurel -n poc-l7 -o jsonpath='{.status.addresses[0].value}')
# Linux: dig +short "$FQDN"
# Windows: (Resolve-DnsName $FQDN).IPAddress
curl -sS --resolve storefront.example.local:80:<IP> http://storefront.example.local/v1
curl -sS --resolve storefront.example.local:80:<IP> http://storefront.example.local/v2
```

---

## 7. Azure Load Balancer

AKS always creates a **Standard SKU Azure Load Balancer** in the `MC_` group when outbound type is `loadBalancer`. That is the AKS-managed “add-on” for L4. There is no Helm chart and no operator Deployment to apply.

You still author **Service manifests** for inbound frontends. Argo CD syncs them with the L4 sample app.

### 7.1 Cluster / add-on configuration

Set at create (already in section 2.5):

```text
--load-balancer-sku standard
--outbound-type loadBalancer
```

SKU cannot be changed later. Basic SKU is unsupported with NAP on a custom VNet.

Optional multiple SLBs (not required):

```bash
az aks loadbalancer add \
  --resource-group $RG_NAME \
  --cluster-name $CLUSTER_NAME \
  --name slb-apps \
  --primary-agent-pool-name system
```

Services can then set annotation `service.beta.kubernetes.io/azure-load-balancer-configurations`. Skip this unless you are specifically testing multi-SLB.

### 7.2 Manifests you must author

Kubernetes `Service` `type: LoadBalancer`. Important fields and annotations:

| Field / annotation | Purpose |
| --- | --- |
| `spec.type: LoadBalancer` | Ask cloud-provider to allocate an SLB frontend |
| `spec.selector` | Pods to include |
| `spec.ports` | Frontend port → `targetPort` |
| `service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path` | HTTP probe path |
| `service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout` | Idle timeout minutes |
| `service.beta.kubernetes.io/azure-load-balancer-internal: "true"` | Private frontend in the node subnet |
| `service.beta.kubernetes.io/azure-load-balancer-ipv4` | Pin a pre-created public IP |
| `spec.externalTrafficPolicy` | `Cluster` (simple) vs `Local` (preserves client IP, changes probes) |

Do not use deprecated `spec.loadBalancerIP`.

Public:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: storefront-l4
  namespace: poc-l4
  labels:
    app: storefront-l4
    owner: laurel-poc
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /
    service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: "4"
spec:
  type: LoadBalancer
  selector:
    app: storefront-l4
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
```

Internal:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: storefront-l4-internal
  namespace: poc-l4
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  selector:
    app: storefront-l4
  ports:
    - name: http
      port: 80
      targetPort: 8080
```

The cloud-provider creates a frontend IP on the existing Standard Load Balancer. You do not create an Azure Load Balancer ARM template.

### 7.3 How to verify

```bash
kubectl get svc -n poc-l4 storefront-l4 -w
curl -sS "http://$(kubectl get svc storefront-l4 -n poc-l4 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/"
```

The same IP appears on the SLB in the `MC_` resource group.

---

## 8. Sample applications

These apps exist to exercise the stack. Deploy them **with Argo CD** after Kyverno policies and the `ApplicationLoadBalancer` are Ready. Full file mapping is in [Laurel-POC-architecture.md](./Laurel-POC-architecture.md).

### 8.1 Namespaces

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: poc-l4
  labels:
    purpose: azure-load-balancer
---
apiVersion: v1
kind: Namespace
metadata:
  name: poc-l7
  labels:
    purpose: application-gateway-for-containers
---
apiVersion: v1
kind: Namespace
metadata:
  name: poc-scale
  labels:
    purpose: karpenter-nap
```

### 8.2 L4 app — Azure Load Balancer

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront-l4
  namespace: poc-l4
  labels:
    app: storefront-l4
    owner: laurel-poc
spec:
  replicas: 2
  selector:
    matchLabels:
      app: storefront-l4
  template:
    metadata:
      labels:
        app: storefront-l4
        owner: laurel-poc
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: storefront-l4
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:8080", "-text=laurel-poc L4 via Azure Load Balancer"]
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65534
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 10
```

Pair with the public `Service` in section 7.2.

### 8.3 L7 apps — Application Gateway for Containers

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-v1
  namespace: poc-l7
  labels:
    app: backend-v1
    owner: laurel-poc
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend-v1
  template:
    metadata:
      labels:
        app: backend-v1
        owner: laurel-poc
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:8080", "-text=backend-v1 via Application Gateway for Containers"]
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65534
          readinessProbe:
            httpGet:
              path: /
              port: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-v2
  namespace: poc-l7
  labels:
    app: backend-v2
    owner: laurel-poc
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend-v2
  template:
    metadata:
      labels:
        app: backend-v2
        owner: laurel-poc
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:8080", "-text=backend-v2 via Application Gateway for Containers"]
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65534
          readinessProbe:
            httpGet:
              path: /
              port: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: backend-v1
  namespace: poc-l7
  labels:
    app: backend-v1
    owner: laurel-poc
spec:
  selector:
    app: backend-v1
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: backend-v2
  namespace: poc-l7
  labels:
    app: backend-v2
    owner: laurel-poc
spec:
  selector:
    app: backend-v2
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```

AGfC uses ClusterIP Services. Add the Gateway and HTTPRoute from section 6.3 in the same Argo application or a sibling folder.

### 8.4 Karpenter scale app

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scale-me
  namespace: poc-scale
  labels:
    app: scale-me
    owner: laurel-poc
spec:
  replicas: 1
  selector:
    matchLabels:
      app: scale-me
  template:
    metadata:
      labels:
        app: scale-me
        owner: laurel-poc
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "1"
              memory: 1Gi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65534
```

Scale by committing `replicas: 6` (GitOps) or, during a live demo, `kubectl scale`. Then scale back to `1` and watch consolidation.

---

## 9. Suggested implementation order

| Step | Action | Success signal |
| --- | --- | --- |
| 0 | Register providers/features, check quota and region | Features `Registered`; D-series quota sufficient |
| 1 | Create RG, identity, VNet, subnets, role assignment | Subnet `snet-agfc` shows delegation |
| 2 | Create AKS Standard cluster with NAP, Cilium Overlay, **no** AGfC add-on yet | Nodes Ready; default `NodePool` exists |
| 3 | **Install Argo CD with Helm** (manual *or* CI/CD) using `bootstrap/argocd/values.yaml` | Pods in `argocd` Running; CRDs present |
| 4 | Apply `AppProject` + root `Application` | `laurel-poc-root` Synced |
| 5 | Commit Karpenter `AKSNodeClass` / `NodePool` manifests | `kubectl get nodepool workload` |
| 6 | Commit Kyverno overlay + policies | Webhooks annotated; privileged deploy denied |
| 7 | Enable AGfC **add-on** *or* Helm controller (one path) | `GatewayClass azure-alb-external` Accepted |
| 8 | Commit `ApplicationLoadBalancer`, Gateway, HTTPRoute, sample apps | Apps Healthy; L4 IP and L7 FQDN work |
| 9 | Test L4 curl and L7 `/v1` `/v2` | Distinct echo texts |
| 10 | Scale `scale-me` via Git | New Karpenter node; scale-in consolidates |
| 11 | Change a replica in Git | Argo CD self-heal without kubectl |

---

## 10. Test plan (capabilities to prove)

| Capability | Test | Expected result |
| --- | --- | --- |
| AKS Standard + Overlay + Cilium | `kubectl get nodes`; Cilium DS | Ready nodes; no kube-proxy |
| Argo CD Helm manual | `helm upgrade --install` from a laptop | Pods Running; UI via port-forward |
| Argo CD Helm CI/CD | Push `bootstrap/argocd/values.yaml` | Pipeline helm upgrade succeeds |
| GitOps (not CI) for apps | Commit replica change under `apps/` | Application Synced; no pipeline kubectl |
| Azure Load Balancer L4 | Curl public IP of `storefront-l4` | HTTP 200 and L4 echo text |
| AGfC controller (chosen path) | `kubectl get gatewayclass azure-alb-external` | `Accepted=True` |
| L7 path routing | Curl `/v1` and `/v2` via Gateway FQDN | v1 vs v2 echo text |
| L7 traffic split | Curl `/` many times | Mix of v1 (~80%) and v2 (~20%) |
| Karpenter provision | Scale `scale-me` to 6 | `NodeClaim` + node `karpenter.sh/nodepool=workload` |
| Karpenter consolidate | Scale back to 1 | Extra nodes drained after `consolidateAfter` |
| Kyverno enforce | Privileged / unlabeled Deployment | Admission denial |
| Kyverno mutate | Inspect a running pod | Label `env=poc` |
| Isolation | `kubectl get pods -o wide` | Argo/Kyverno/ALB on system nodes; apps on NAP nodes |

---

## 11. Cost, operations, and teardown

NAP clusters **cannot be stopped**. Leave the cluster up for the demo window or delete it.

```bash
az aks update -g $RG_NAME -n $CLUSTER_NAME \
  --disable-gateway-api --disable-application-load-balancer

az group delete --name $RG_NAME --yes --no-wait
```

Cost drivers: system VMs (2 × D4s_v5), Karpenter VMs, Standard Load Balancer + public IPs, AGfC capacity units, control plane Standard tier.

---

## 12. Known constraints (do not fight these in the POC)

- AGfC ALB Controller **AKS add-on is preview**. Helm controller is the customization path; the Azure AGfC resource is GA in listed regions.
- Azure Argo CD extension is **preview**. This POC uses Helm instead.
- AGfC subnet must be `/24`; one deployment per subnet; same VNet as AKS.
- Overlay + NVA/Azure Firewall cannot inspect overlay pod traffic the way flat CNI can.
- NAP: no Windows, no IPv6, no cluster stop, no outbound-type change, no cluster autoscaler, no service principals.
- Azure Linux 2.0 is retired; use Azure Linux 3 / `AzureLinux`.
- Do not hand-edit NICs, NSGs, or the Load Balancer inside the `MC_` group.
- Do not mix AGfC add-on and AGfC Helm on one cluster. Do not mix Argo Helm and the Azure Argo extension.

---

## 13. Links (evidence and documentation)

### AKS cluster, SKU, and Day-0

- [AKS intro](https://learn.microsoft.com/en-us/azure/aks/what-is-aks)
- [AKS Automatic vs Standard](https://learn.microsoft.com/en-us/azure/aks/intro-aks-automatic)
- [Supported Kubernetes versions](https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions)
- [Planned maintenance](https://learn.microsoft.com/en-us/azure/aks/planned-maintenance)
- [Azure Linux on AKS](https://learn.microsoft.com/en-us/azure/aks/use-azure-linux)
- [Ephemeral OS disks](https://learn.microsoft.com/en-us/azure/aks/concepts-storage#ephemeral-os-disk)
- [Workload identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Microsoft Entra ID and Azure RBAC for AKS](https://learn.microsoft.com/en-us/azure/aks/manage-azure-rbac)
- [Start/stop cluster](https://learn.microsoft.com/en-us/azure/aks/start-stop-cluster) (not usable with NAP)

### Networking

- [Azure CNI Overlay](https://learn.microsoft.com/en-us/azure/aks/azure-cni-overlay)
- [Azure CNI powered by Cilium](https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium)
- [AKS networking concepts](https://learn.microsoft.com/en-us/azure/aks/concepts-network)
- [Configure authorized IP ranges](https://learn.microsoft.com/en-us/azure/aks/api-server-authorized-ip-ranges)
- [Egress outbound types](https://learn.microsoft.com/en-us/azure/aks/egress-outboundtype)

### Azure Load Balancer

- [Public Standard Load Balancer on AKS](https://learn.microsoft.com/en-us/azure/aks/load-balancer-standard)
- [Internal load balancer on AKS](https://learn.microsoft.com/en-us/azure/aks/internal-lb)
- [Azure Load Balancer overview](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-overview)
- [Multiple Standard Load Balancers on AKS](https://learn.microsoft.com/en-us/azure/aks/use-multiple-standard-load-balancer)
- [`az aks loadbalancer` CLI](https://learn.microsoft.com/en-us/cli/azure/aks/loadbalancer)

### Application Gateway for Containers

- [AGfC overview and supported regions](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/overview)
- [AGfC components (add-on vs Helm)](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/application-gateway-for-containers-components)
- [Quickstart: ALB Controller AKS add-on](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-addon)
- [Quickstart: ALB Controller Helm](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-helm)
- [ALB Controller Helm chart values](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/alb-controller-helm-chart)
- [Create AGfC managed by ALB Controller](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-create-application-gateway-for-containers-managed-by-alb-controller)
- [AGfC container networking](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/container-networking)
- [AGfC FAQ](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/faq)
- [Multi-site hosting with Gateway API](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/how-to-multiple-site-hosting-gateway-api)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)

### Karpenter / Node Auto-Provisioning

- [NAP overview](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning)
- [Enable or disable NAP](https://learn.microsoft.com/en-us/azure/aks/use-node-auto-provisioning)
- [NAP in a custom VNet](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning-custom-vnet)
- [NAP networking](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning-networking)
- [NAP NodePools](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning-node-pools)
- [AKSNodeClass](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning-aksnodeclass)
- [Karpenter docs](https://karpenter.sh/docs/)
- [AKS Karpenter provider (GitHub)](https://github.com/Azure/karpenter-provider-azure)

### Kyverno

- [Kyverno installation (Helm and YAML)](https://kyverno.io/docs/installation/installation/)
- [Kyverno platform notes (AKS Admission Enforcer, Argo CD)](https://kyverno.io/docs/installation/platform-notes/)
- [Kyverno policies library](https://kyverno.io/policies/)
- [AKS Admission Enforcer FAQ](https://learn.microsoft.com/en-us/azure/aks/faq#can-admission-controller-webhooks-impact-kube-system-and-internal-aks-namespaces)

### Argo CD / GitOps

- [Argo CD official docs](https://argo-cd.readthedocs.io/en/stable/)
- [Argo CD Helm install](https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/)
- [Declarative setup (Application, AppProject)](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
- [App of Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Argo Helm chart](https://github.com/argoproj/argo-helm)
- [GitOps with Argo CD on AKS / Arc](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/conceptual-gitops-argocd)
- [Tutorial: Argo CD Azure extension](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/tutorial-use-gitops-argocd)
- [GitHub Action `azure/login`](https://github.com/Azure/login)
- [GitHub Action `azure/aks-set-context`](https://github.com/Azure/aks-set-context)

### Observability (optional)

- [Container Insights](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-overview)
- [AKS control plane logs](https://learn.microsoft.com/en-us/azure/aks/monitor-aks#aks-control-plane-logs)

---

## 14. Decision log (why these defaults)

| Question | Choice | Rationale |
| --- | --- | --- |
| Automatic or Standard? | Standard | POC must expose NAP, Kyverno, Argo CD, L4 SLB, and AGfC as configurable pieces |
| Argo CD first? | Yes, via Helm | GitOps plane exists before other operators; tests Helm manual and CI/CD |
| Argo extension or Helm? | Helm | Explicit request; extension remains a documented alternative |
| Self-hosted Karpenter or NAP? | NAP + NodePool manifests | Microsoft-supported path |
| Overlay or VNet-routable CNI? | Overlay | Scales without burning VNet IPs; AGfC and NAP both support it |
| Cilium or Azure NPM? | Cilium | NAP recommendation; replaces kube-proxy |
| AGfC add-on or Helm? | Document both; pick one | Add-on is simpler; Helm is the manifest-aligned controller install |
| AGfC managed CR or BYO ARM? | Managed `ApplicationLoadBalancer` CR | Kubernetes-native for GitOps |
| Kyverno Helm or YAML? | YAML + Kustomize patches | No AKS add-on; matches “manifests for other operators” |
| Who deploys apps? | Argo CD from Git | CI/CD only installs/upgrades Argo CD |
| Public or private API? | Public + optional IP allowlist | Faster POC |
| How many sample apps? | Three | One per data path (L4, L7, scale), plus Kyverno negative tests |

This cluster is disposable. When the POC is finished, delete `rg-laurel-poc` rather than trying to stop it.
