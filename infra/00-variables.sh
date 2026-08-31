# Run the script as follows:
# source infra/00-variables.sh

export LOCATION="eastus2"
export RG_NAME="rg-gasper-laurel-poc"
export CLUSTER_NAME="aks-gasper-laurel-poc"
export VNET_NAME="vnet-gasper-laurel-poc"
export IDENTITY_NAME="id-aks-gasper-laurel-poc"
export K8S_VERSION="$(az aks get-versions --location $LOCATION --query 'values[0].version' -o tsv)"