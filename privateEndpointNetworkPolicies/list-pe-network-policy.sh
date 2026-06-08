#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 1) 列出所有可存取訂閱裡的 Private Endpoint (含所屬 RG ID、Subnet ID)
# 2) 對每個 PE 所在 subnet 撈出 privateEndpointNetworkPolicies 設定
# 3) 把 policy 不等於 TARGET_POLICY 的 subnet 改成 TARGET_POLICY
#
# TARGET_POLICY 可選值:
#   Disabled                     -> NSG/UDR 都不套用 PE
#   Enabled                      -> NSG/UDR 都套用 PE
#   NetworkSecurityGroupEnabled  -> 只啟用 NSG
#   RouteTableEnabled            -> 只啟用 Route Table (UDR)  (預設)
#
# Usage:
# ./list-pe-network-policy.sh                                  # dry-run, 預設目標 = RouteTableEnabled
# APPLY=1 ./list-pe-network-policy.sh                          # 實際套用 RouteTableEnabled
# APPLY=1 TARGET_POLICY=Enabled ./list-pe-network-policy.sh    # 切回全開 (NSG+UDR)
# APPLY=1 TARGET_POLICY=NetworkSecurityGroupEnabled ./list-pe-network-policy.sh  # 只開 NSG
# APPLY=1 TARGET_POLICY=Disabled ./list-pe-network-policy.sh   # 全關
# ------------------------------------------------------------------------------
set -euo pipefail

TARGET_POLICY="${TARGET_POLICY:-RouteTableEnabled}"
case "$TARGET_POLICY" in
  Disabled|Enabled|NetworkSecurityGroupEnabled|RouteTableEnabled) ;;
  *) echo "ERROR: invalid TARGET_POLICY='$TARGET_POLICY'. Allowed: Disabled | Enabled | NetworkSecurityGroupEnabled | RouteTableEnabled"; exit 1 ;;
esac

APPLY="${APPLY:-0}"

# Git Bash / MSYS 會把以 '/' 開頭的參數當作路徑做轉換,會破壞 Azure resource ID
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

OUT_PE="${OUT_PE:-private-endpoints.tsv}"
OUT_SUBNET="${OUT_SUBNET:-subnet-pe-network-policies.tsv}"

# --- 前置檢查 -----------------------------------------------------------------
command -v az >/dev/null 2>&1 || { echo "ERROR: 找不到 az CLI"; exit 1; }

if ! az account show >/dev/null 2>&1; then
  echo "ERROR: Azure CLI 尚未登入,請先執行: az login"
  exit 1
fi

if ! az extension show -n resource-graph >/dev/null 2>&1; then
  echo "Installing Azure CLI extension: resource-graph ..."
  az extension add -n resource-graph -y >/dev/null
fi

# --- Step 1: 列出所有 Private Endpoint --------------------------------------
echo "==> [1/3] Listing all Private Endpoints (cross-subscription via Resource Graph)"

printf "Name\tSubscriptionId\tResourceGroupId\tSubnetId\tPrivateIP\tLocation\n" > "$OUT_PE"

az graph query -q "
Resources
| where type =~ 'microsoft.network/privateendpoints'
| extend nicId = tolower(tostring(properties.networkInterfaces[0].id))
| join kind=leftouter (
    Resources
    | where type =~ 'microsoft.network/networkinterfaces'
    | mv-expand ipc = properties.ipConfigurations
    | extend nid = tolower(id),
             pip = tostring(ipc.properties.privateIPAddress)
    | summarize ips = make_set(pip) by nid
  ) on \$left.nicId == \$right.nid
| project name,
          subId     = subscriptionId,
          rgId      = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup),
          subnetId  = tostring(properties.subnet.id),
          privateIp = strcat_array(ips, ','),
          location
| order by subId asc, name asc
" --first 1000 \
  --query "data[].[name, subId, rgId, subnetId, privateIp, location]" \
  -o tsv >> "$OUT_PE"

echo "Saved: $OUT_PE"
echo "----- Private Endpoint List -----"
column -t -s $'\t' "$OUT_PE" 2>/dev/null || cat "$OUT_PE"
echo ""

# --- Step 2: 對每個唯一 subnet 查詢 PE network policy 設定 ------------------
echo "==> [2/3] Fetching privateEndpointNetworkPolicies on each unique subnet"

printf "SubnetId\tPrivateEndpointNetworkPolicies\n" > "$OUT_SUBNET"

# 跳過 header,取 SubnetId 欄,去重
tail -n +2 "$OUT_PE" | awk -F'\t' '$4 != "" {print $4}' | sort -u | while read -r sid; do
  policy=$(az network vnet subnet show --ids "$sid" \
            --query "privateEndpointNetworkPolicies" \
            -o tsv 2>/dev/null || echo "ERROR")
  printf "%s\t%s\n" "$sid" "$policy" >> "$OUT_SUBNET"
done

echo "Saved: $OUT_SUBNET"
echo "----- Subnet PE Network Policy -----"
column -t -s $'\t' "$OUT_SUBNET" 2>/dev/null || cat "$OUT_SUBNET"
echo ""

# --- Step 3: 把 policy != TARGET_POLICY 的 subnet 改成 TARGET_POLICY ----------
echo "==> [3/3] Set privateEndpointNetworkPolicies = ${TARGET_POLICY} on subnets that don't match"

candidate_subnets=$(tail -n +2 "$OUT_SUBNET" \
  | awk -F'\t' -v t="$TARGET_POLICY" '$2 != t && $2 != "" && $2 != "ERROR" {print $1"\t"$2}')

if [[ -z "$candidate_subnets" ]]; then
  echo "All subnets already set to ${TARGET_POLICY}. Nothing to change."
else
  count=$(echo "$candidate_subnets" | wc -l | tr -d ' ')
  echo "Found ${count} subnet(s) where policy != ${TARGET_POLICY}:"
  echo "$candidate_subnets" | awk -F'\t' '{printf "  - %s  (current: %s)\n", $1, $2}'
  echo ""

  if [[ "$APPLY" != "1" ]]; then
    echo "DRY-RUN. Re-run with APPLY=1 to actually update, e.g.:"
    echo "  APPLY=1 TARGET_POLICY=${TARGET_POLICY} ./list-pe-network-policy.sh"
  else
    echo "Applying updates (target=${TARGET_POLICY}) ..."
    updated_subnets=()
    failed_subnets=()
    while IFS=$'\t' read -r sid current; do
      [[ -z "$sid" ]] && continue
      echo "  -> $sid  (${current} -> ${TARGET_POLICY})"
      if az network vnet subnet update --ids "$sid" \
           --private-endpoint-network-policies "$TARGET_POLICY" \
           -o none 2>/tmp/pe_err.$$; then
        echo "     OK"
        updated_subnets+=("$sid")
      else
        echo "     FAILED: $(cat /tmp/pe_err.$$)"
        failed_subnets+=("$sid")
      fi
      rm -f /tmp/pe_err.$$
    done <<< "$candidate_subnets"

    echo ""
    echo "----- Modified Subnets (${#updated_subnets[@]}) -----"
    if [[ ${#updated_subnets[@]} -eq 0 ]]; then
      echo "  (none)"
    else
      for s in "${updated_subnets[@]}"; do echo "  ✓ $s"; done
    fi
    if [[ ${#failed_subnets[@]} -gt 0 ]]; then
      echo ""
      echo "----- Failed Subnets (${#failed_subnets[@]}) -----"
      for s in "${failed_subnets[@]}"; do echo "  ✗ $s"; done
    fi
  fi
fi
echo ""

echo "Done."
echo "  - Target policy:               $TARGET_POLICY"
echo "  - Private Endpoint list:       $OUT_PE"
echo "  - Subnet network policy state: $OUT_SUBNET"
