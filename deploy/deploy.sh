#!/usr/bin/env bash
###############################################################################
# Azure GxP Pharmaceutical Infrastructure - deployment
#
# Builds a segmented "small pharma" network with QA/QC/MFG/PKG departments,
# compliance-hardened storage, Key Vault, Log Analytics and governance.
# All resources are free or near-zero cost (no VMs).
#
# Usage:   az login && ./deploy.sh
# Options: LOCATION=eastus  RG=rg-pharma-lab  SUFFIX=<unique>  ./deploy.sh
###############################################################################
set -euo pipefail

LOCATION="${LOCATION:-eastus}"
RG="${RG:-rg-pharma-lab}"
SUFFIX="${SUFFIX:-$RANDOM}"
SA_DATA="stpharmadata${SUFFIX}"
SA_AUDIT="stpharmaaudit${SUFFIX}"
KV="kv-pharma-${SUFFIX}"

echo ">> Deploying to '$RG' ($LOCATION)  data=$SA_DATA  audit=$SA_AUDIT  kv=$KV"
az provider register --namespace Microsoft.KeyVault >/dev/null || true

# 1) Resource group with compliance tags ------------------------------------
az group create -n "$RG" -l "$LOCATION" \
  --tags env=lab industry=pharma compliance=GxP dataClassification=Confidential costCenter=RND -o none

# 2) Segmented virtual network ----------------------------------------------
az network vnet create -g "$RG" -n vnet-pharma -l "$LOCATION" \
  --address-prefixes 10.30.0.0/16 --subnet-name snet-corp --subnet-prefixes 10.30.1.0/24 -o none
for s in app=10.30.2.0/24 data=10.30.3.0/24 research=10.30.4.0/24 mgmt=10.30.5.0/24 \
         qa=10.30.6.0/24 qc=10.30.7.0/24 mfg=10.30.8.0/24 pkg=10.30.9.0/24; do
  az network vnet subnet create -g "$RG" --vnet-name vnet-pharma \
    -n "snet-${s%%=*}" --address-prefixes "${s##*=}" -o none
done

# 3) NSGs (one per subnet, departments tagged) + ASGs + associations --------
for n in corp app data research mgmt; do az network nsg create -g "$RG" -n "nsg-$n" -l "$LOCATION" -o none; done
for n in qa qc mfg pkg; do
  AREA=$([ "$n" = qa ] || [ "$n" = qc ] && echo Quality || echo Operations)
  az network nsg create -g "$RG" -n "nsg-$n" -l "$LOCATION" \
    --tags Department="${n^^}" GxP=true area="$AREA" -o none
done
for a in web app db research qa qc mfg pkg; do az network asg create -g "$RG" -n "asg-$a" -l "$LOCATION" -o none; done
for n in corp app data research mgmt qa qc mfg pkg; do
  az network vnet subnet update -g "$RG" --vnet-name vnet-pharma -n "snet-$n" --network-security-group "nsg-$n" -o none
done

# 4) Resolve ASG IDs (robust across CLI versions) ---------------------------
id() { az network asg show -g "$RG" -n "asg-$1" --query id -o tsv; }
WEB=$(id web); APP=$(id app); DB=$(id db); RES=$(id research)
QA=$(id qa); QC=$(id qc); MFG=$(id mfg); PKG=$(id pkg); MGMT=10.30.5.0/24

# 5) Tiered application-path rules ------------------------------------------
az network nsg rule create -g "$RG" --nsg-name nsg-corp -n allow-https-in --priority 100 \
  --direction Inbound --access Allow --protocol Tcp --source-address-prefixes Internet \
  --destination-asgs "$WEB" --destination-port-ranges 443 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-app -n allow-web-to-app --priority 100 \
  --direction Inbound --access Allow --protocol Tcp --source-asgs "$WEB" \
  --destination-asgs "$APP" --destination-port-ranges 8443 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-data -n allow-app-to-sql --priority 100 \
  --direction Inbound --access Allow --protocol Tcp --source-asgs "$APP" \
  --destination-asgs "$DB" --destination-port-ranges 1433 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-data -n deny-other-to-data --priority 200 \
  --direction Inbound --access Deny --protocol '*' --source-address-prefixes VirtualNetwork \
  --destination-asgs "$DB" --destination-port-ranges '*' -o none
az network nsg rule create -g "$RG" --nsg-name nsg-research -n allow-mgmt-only --priority 100 \
  --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "$MGMT" \
  --destination-asgs "$RES" --destination-port-ranges 22 3389 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-research -n deny-vnet --priority 4000 \
  --direction Inbound --access Deny --protocol '*' --source-address-prefixes VirtualNetwork --destination-port-ranges '*' -o none
az network nsg rule create -g "$RG" --nsg-name nsg-mgmt -n allow-ssh-rdp-in --priority 100 \
  --direction Inbound --access Allow --protocol Tcp --source-address-prefixes VirtualNetwork --destination-port-ranges 22 3389 -o none

# 6) GxP department rules: QA oversight, QC->MFG testing, MFG<->PKG line -----
# QA: admin in, deny rest
az network nsg rule create -g "$RG" --nsg-name nsg-qa -n allow-mgmt --priority 100 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "$MGMT" --destination-asgs "$QA" --destination-port-ranges 22 3389 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-qa -n deny-vnet --priority 4000 --direction Inbound --access Deny --protocol '*' --source-address-prefixes VirtualNetwork --destination-port-ranges '*' -o none
# QC: QA oversight + admin + deny rest
az network nsg rule create -g "$RG" --nsg-name nsg-qc -n allow-qa-oversight --priority 100 --direction Inbound --access Allow --protocol Tcp --source-asgs "$QA" --destination-asgs "$QC" --destination-port-ranges 443 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-qc -n allow-mgmt --priority 110 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "$MGMT" --destination-asgs "$QC" --destination-port-ranges 22 3389 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-qc -n deny-vnet --priority 4000 --direction Inbound --access Deny --protocol '*' --source-address-prefixes VirtualNetwork --destination-port-ranges '*' -o none
# MFG: QA oversight + QC testing + PKG line + admin + deny rest
az network nsg rule create -g "$RG" --nsg-name nsg-mfg -n allow-qa-oversight --priority 100 --direction Inbound --access Allow --protocol Tcp --source-asgs "$QA" --destination-asgs "$MFG" --destination-port-ranges 443 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-mfg -n allow-qc-testing --priority 110 --direction Inbound --access Allow --protocol Tcp --source-asgs "$QC" --destination-asgs "$MFG" --destination-port-ranges 8443 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-mfg -n allow-pkg-integration --priority 120 --direction Inbound --access Allow --protocol Tcp --source-asgs "$PKG" --destination-asgs "$MFG" --destination-port-ranges 8443 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-mfg -n allow-mgmt --priority 130 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "$MGMT" --destination-asgs "$MFG" --destination-port-ranges 22 3389 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-mfg -n deny-vnet --priority 4000 --direction Inbound --access Deny --protocol '*' --source-address-prefixes VirtualNetwork --destination-port-ranges '*' -o none
# PKG: QA oversight + MFG line + admin + deny rest
az network nsg rule create -g "$RG" --nsg-name nsg-pkg -n allow-qa-oversight --priority 100 --direction Inbound --access Allow --protocol Tcp --source-asgs "$QA" --destination-asgs "$PKG" --destination-port-ranges 443 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-pkg -n allow-mfg-integration --priority 110 --direction Inbound --access Allow --protocol Tcp --source-asgs "$MFG" --destination-asgs "$PKG" --destination-port-ranges 8443 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-pkg -n allow-mgmt --priority 120 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "$MGMT" --destination-asgs "$PKG" --destination-port-ranges 22 3389 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-pkg -n deny-vnet --priority 4000 --direction Inbound --access Deny --protocol '*' --source-address-prefixes VirtualNetwork --destination-port-ranges '*' -o none

# 7) Compliance-hardened storage + per-department record containers ---------
for SA in "$SA_DATA" "$SA_AUDIT"; do
  az storage account create -n "$SA" -g "$RG" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --https-only true --allow-blob-public-access false -o none
done
az storage account blob-service-properties update --account-name "$SA_DATA" -g "$RG" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 -o none
for c in research-data clinical-trials qa-records qc-test-results mfg-batch-records pkg-labeling; do
  az storage container create --account-name "$SA_DATA" -n "$c" --auth-mode key -o none
done
az storage container create --account-name "$SA_AUDIT" -n audit-logs --auth-mode key -o none

# 8) Key Vault + Log Analytics ----------------------------------------------
az keyvault create -n "$KV" -g "$RG" -l "$LOCATION" --enable-rbac-authorization true --retention-days 90 -o none
az monitor log-analytics workspace create -g "$RG" -n law-pharma -l "$LOCATION" -o none

# 9) Governance: data-residency policy + lock on the data store -------------
RGID=$(az group show -n "$RG" --query id -o tsv)
az policy assignment create --name pharma-allowed-locations --scope "$RGID" \
  --policy e56962a6-4747-49cd-b67b-bf8b01975c4c \
  --params '{"listOfAllowedLocations":{"value":["'"$LOCATION"'"]}}' -o none
az lock create -n protect-research-data --lock-type CanNotDelete -g "$RG" \
  --resource "$SA_DATA" --resource-type Microsoft.Storage/storageAccounts -o none

echo ">> Done. Review with:  az resource list -g $RG -o table"
