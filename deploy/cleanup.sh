#!/usr/bin/env bash
###############################################################################
# Tear down the GxP pharmaceutical lab.
# Removes the CanNotDelete lock first (otherwise the RG delete is blocked),
# then deletes the entire resource group.
#
# Usage: RG=rg-pharma-lab ./cleanup.sh
###############################################################################
set -euo pipefail
RG="${RG:-rg-pharma-lab}"

echo ">> Removing resource locks in $RG ..."
for L in $(az lock list -g "$RG" --query "[].id" -o tsv); do
  az lock delete --ids "$L" && echo "   removed: $L"
done

echo ">> Deleting resource group $RG ..."
az group delete --name "$RG" --yes --no-wait
echo ">> Delete started. Verify with:  az group exists -n $RG   (should return false)"
