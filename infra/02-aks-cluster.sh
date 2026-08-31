# NOTE: By default, Git Bash automatically intercepts any argument starting with a forward slash
export MSYS_NO_PATHCONV=1

IDENTITY_ID=$(az identity show -g $RG_NAME -n $IDENTITY_NAME --query id -o tsv)
NODE_SUBNET_ID=$(az network vnet subnet show -g $RG_NAME --vnet-name $VNET_NAME -n snet-aks-nodes --query id -o tsv)

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
  --node-vm-size Standard_D4ds_v5 \
  --os-sku AzureLinux \
  --node-osdisk-type Ephemeral \
  --zones 1 2 3 \
  --nodepool-taints CriticalAddonsOnly=true:NoSchedule \
  --nodepool-labels pool=system \
  --max-pods 110 \
  --generate-ssh-keys