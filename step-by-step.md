# Laurel POC — first deployment (step by step)

Run these commands from the **repository root**. Use **Helm for AGfC**, not the AKS add-on. Do not mix the two on the same cluster.

Install the ALB Controller **before** Argo CD syncs `platform-agfc`. Git already has the manifests; after Argo CD exists, do not `kubectl apply` `apps/` or `platform/`.

---

## 0. Variables (must match Git)

`$VNET_NAME` must match `spec.associations` in `platform/agfc/applicationloadbalancer.yaml`. A mismatch causes `LinkedAuthorizationFailed` on `Microsoft.Network/virtualNetworks/subnets/join/action`.

```bash
export LOCATION="eastus2"
export RG_NAME="rg-gasper-laurel-poc"
export CLUSTER_NAME="aks-gasper-laurel-poc"
export VNET_NAME="vnet-gasper-laurel-poc"
export IDENTITY_NAME="id-aks-laurel-poc"
export K8S_VERSION="$(az aks get-versions --location $LOCATION --query 'values[0].version' -o tsv)"
```

---

## 1. Providers and CLI extensions

```bash
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking
az provider register --namespace Microsoft.KubernetesConfiguration

az extension add --name aks-preview --upgrade
az extension add --name alb
```

Azure CLI **2.76.0 or later** is required (NAP). Helm 3.x and `kubectl` must be installed.

---

## 2. Foundation (resource group, identity, VNet, subnets)

```bash
az group create --name $RG_NAME --location $LOCATION

az identity create \
  --name $IDENTITY_NAME \
  --resource-group $RG_NAME \
  --location $LOCATION

sleep 60

IDENTITY_ID=$(az identity show -g $RG_NAME -n $IDENTITY_NAME --query id -o tsv)
IDENTITY_PRINCIPAL=$(az identity show -g $RG_NAME -n $IDENTITY_NAME --query principalId -o tsv)

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

echo "$AGFC_SUBNET_ID"
```

`echo` must print the **same** ARM ID as `spec.associations` in Git. If it does not, stop and fix Git (or `$VNET_NAME`) before continuing.

Grant the **cluster** identity Network Contributor on the VNet:

```bash
az role assignment create \
  --assignee-object-id $IDENTITY_PRINCIPAL \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope $VNET_ID
```

---

## 3. AKS cluster (no AGfC add-on)

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

Grant yourself cluster admin (required with `--enable-azure-rbac`), then get credentials:

```bash
CLUSTER_ID=$(az aks show -g $RG_NAME -n $CLUSTER_NAME --query id -o tsv)

az role assignment create \
  --assignee-object-id $(az ad signed-in-user show --query id -o tsv) \
  --assignee-principal-type User \
  --role "Azure Kubernetes Service RBAC Cluster Admin" \
  --scope $CLUSTER_ID

az aks get-credentials --resource-group $RG_NAME --name $CLUSTER_NAME --overwrite-existing

kubectl get nodes -o wide
kubectl get pods -n kube-system | grep -E "cilium|konnectivity"
kubectl get nodepools.karpenter.sh
```

Expected: two system nodes Ready, tainted `CriticalAddonsOnly`, labeled `pool=system`. Cilium running. Default Karpenter `NodePool` present. **No** `alb-controller` yet. **No** Argo CD yet.

---

## 4. Argo CD (Helm)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 7.8.23 \
  --values bootstrap/argocd/values.yaml \
  --wait \
  --timeout 10m

kubectl get pods -n argocd
kubectl get crd | grep argoproj.io
```

Optional UI (do not expose Argo CD on a public LoadBalancer):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

kubectl -n argocd port-forward svc/argocd-server 8080:80
# http://localhost:8080  user: admin
```

---

## 5. AGfC controller (Helm) — before GitOps syncs the ALB

Do **not** run `az aks update --enable-application-load-balancer`.

### 5.1 Identity, roles, federation

```bash
az identity create --resource-group $RG_NAME --name azure-alb-identity
sleep 60

ALB_PRINCIPAL=$(az identity show -g $RG_NAME -n azure-alb-identity --query principalId -o tsv)
ALB_CLIENT_ID=$(az identity show -g $RG_NAME -n azure-alb-identity --query clientId -o tsv)
MC_RESOURCE_GROUP=$(az aks show -g $RG_NAME -n $CLUSTER_NAME --query nodeResourceGroup -o tsv)
MC_RESOURCE_GROUP_ID=$(az group show -n $MC_RESOURCE_GROUP --query id -o tsv)
AKS_OIDC_ISSUER=$(az aks show -g $RG_NAME -n $CLUSTER_NAME --query oidcIssuerProfile.issuerUrl -o tsv)

az role assignment create \
  --assignee-object-id $ALB_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --scope $MC_RESOURCE_GROUP_ID --role "AppGw for Containers Configuration Manager"

az role assignment create \
  --assignee-object-id $ALB_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --scope $MC_RESOURCE_GROUP_ID --role "Network Contributor"

az role assignment create \
  --assignee-object-id $ALB_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --scope $AGFC_SUBNET_ID --role "Network Contributor"

az identity federated-credential create \
  --name azure-alb-identity \
  --identity-name azure-alb-identity \
  --resource-group $RG_NAME \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject "system:serviceaccount:azure-alb-system:alb-controller-sa"
```

Network Contributor on `$AGFC_SUBNET_ID` (the subnet ARM ID from step 2) is required for `subnets/join/action`. Granting it on a **different** VNet name does not work.

### 5.2 Install and pin the chart

`--set` overrides the placeholder `clientID` in `platform/agfc/controller/values.yaml`. `--version 1.11.4` pins the chart.

```bash
helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
  --namespace azure-alb-system \
  --create-namespace \
  --version 1.11.4 \
  --values platform/agfc/controller/values.yaml \
  --set albController.podIdentity.clientID="$ALB_CLIENT_ID"

kubectl get pods -n azure-alb-system
kubectl get gatewayclass azure-alb-external
```

Expected: two `alb-controller-*` pods Running. `GatewayClass` `azure-alb-external` is `Accepted=True`.

---

## 6. Bootstrap GitOps (one-time)

Helm installs Argo CD. It does not watch Git until you apply the AppProject and root Application.

```bash
kubectl apply -f bootstrap/root/appproject.yaml
kubectl apply -f bootstrap/root/root-application.yaml
kubectl get applications -n argocd
```

Argo CD then syncs children from `gitops/applications/`:

| Application | Path | What it creates |
| --- | --- | --- |
| `app-namespaces` | `apps` (`namespaces.yaml`) | `poc-l4`, `poc-l7`, `poc-scale` |
| `platform-kyverno` | `platform/kyverno` | Kyverno + policies |
| `platform-karpenter` | `platform/karpenter` | `AKSNodeClass` / `NodePool` |
| `platform-agfc` | `platform/agfc` (excludes `controller/**`) | `alb-test-infra` + `ApplicationLoadBalancer` `alb-laurel` |
| `app-storefront-l4` | `apps/storefront-l4` | L4 Deployment + LoadBalancer Service |
| `app-storefront-l7` | `apps/storefront-l7` | backends, Gateway, HTTPRoute |
| `app-scale-me` | `apps/scale-me` | Karpenter scale demo |

`platform-agfc` is the app that creates `alb-laurel`. It must **not** apply `controller/values.yaml`.

---

## 7. Wait for Application Gateway for Containers

```bash
kubectl get applicationloadbalancer alb-laurel -n alb-test-infra -o jsonpath="{.spec.associations}{'\n'}"
```

That value must equal `$AGFC_SUBNET_ID` from step 2.

```bash
kubectl describe applicationloadbalancer alb-laurel -n alb-test-infra
```

Wait until `Accepted=True` and `Deployment=True` (often 5–6 minutes). Do **not** delete the CR while Azure is still creating or deleting the Traffic Controller.

Then:

```bash
kubectl get gateway gateway-laurel -n poc-l7
```

Expected: `CLASS` `azure-alb-external`, `PROGRAMMED=True`, `ADDRESS` set to a `*.alb.azure.com` FQDN.

If `PROGRAMMED` stays `Unknown`, the ALB is not Ready yet, or the controller never reconciled the Gateway (`kubectl describe gateway gateway-laurel -n poc-l7`).

---

## 8. Smoke test L7

```bash
FQDN=$(kubectl get gateway gateway-laurel -n poc-l7 -o jsonpath="{.status.addresses[0].value}")
echo "$FQDN"
```

Resolve `$FQDN` to an IP, then:

```bash
curl -sS --resolve storefront.example.local:80:<IP> http://storefront.example.local/v1
curl -sS --resolve storefront.example.local:80:<IP> http://storefront.example.local/v2
```

Expected: distinct `http-echo` texts (`backend-v1` vs `backend-v2`).

L4 (Azure Load Balancer):

```bash
kubectl get svc -n poc-l4
```

---

## Do not

- Enable the AGfC AKS add-on on this cluster (`--enable-application-load-balancer`).
- `kubectl apply` `apps/` or `platform/` after step 6 — Argo CD owns those.
- Put Gateway / HTTPRoute under `platform/agfc/` — they live in `apps/storefront-l7/`.
- Recreate `alb-laurel` while the Azure Traffic Controller is still `Deleting`.
