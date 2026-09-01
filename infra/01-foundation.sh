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

# NOTE: By default, Git Bash automatically intercepts any argument starting with a forward slash
export MSYS_NO_PATHCONV=1

az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "$VNET_ID"