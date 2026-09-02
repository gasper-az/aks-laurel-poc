# NOTE: By default, Git Bash automatically intercepts any argument starting with a forward slash
export MSYS_NO_PATHCONV=1

ALB_IDENTITY_NAME="azure-alb-identity"
CONTROLLER_NAMESPACE="azure-alb-system"

az identity create --resource-group $RG_NAME --name $ALB_IDENTITY_NAME
sleep 60

ALB_PRINCIPAL=$(az identity show -g $RG_NAME -n $ALB_IDENTITY_NAME --query principalId -o tsv)
ALB_CLIENT_ID=$(az identity show -g $RG_NAME -n $ALB_IDENTITY_NAME --query clientId -o tsv)
MC_RESOURCE_GROUP_ID=$(az group show -n $(az aks show -g $RG_NAME -n $CLUSTER_NAME --query nodeResourceGroup -o tsv) --query id -o tsv)
AKS_OIDC_ISSUER=$(az aks show -g $RG_NAME -n $CLUSTER_NAME --query oidcIssuerProfile.issuerUrl -o tsv)
AGFC_SUBNET_ID=$(az network vnet subnet show -g $RG_NAME --vnet-name $VNET_NAME -n snet-agfc --query id -o tsv)

# RBAC
az role assignment create --assignee-object-id $ALB_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --scope $MC_RESOURCE_GROUP_ID --role "AppGw for Containers Configuration Manager"

az role assignment create --assignee-object-id $ALB_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --scope $MC_RESOURCE_GROUP_ID --role "Network Contributor"

az role assignment create --assignee-object-id $ALB_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --scope $AGFC_SUBNET_ID --role "Network Contributor"

az role assignment create \
  --assignee-object-id a95ba583-3c80-4ada-97ad-9ea6d18773d6 \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "/subscriptions/a7c38d21-c587-4bd0-9913-67218cfdc5bf/resourceGroups/rg-gasper-laurel-poc/providers/Microsoft.Network/virtualNetworks/vnet-laurel-poc/subnets/snet-agfc"

# Federated Identity
az identity federated-credential create \
  --name $ALB_IDENTITY_NAME \
  --identity-name $ALB_IDENTITY_NAME \
  --resource-group $RG_NAME \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject "system:serviceaccount:${CONTROLLER_NAMESPACE}:alb-controller-sa"


echo "Load Balancer Identity's Client ID: $ALB_CLIENT_ID"