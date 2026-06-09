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

printf "Name\tSubscriptionId\tResourceGroupId\tSubnetId\tPrivateIP\tRouteTableId\tLocation\n" > "$OUT_PE"

az graph query -q "
Resources
| where type =~ 'microsoft.network/privateendpoints'
| extend nicId      = tolower(tostring(properties.networkInterfaces[0].id))
| extend subnetIdLc = tolower(tostring(properties.subnet.id))
| join kind=leftouter (
    Resources
    | where type =~ 'microsoft.network/networkinterfaces'
    | mv-expand ipc = properties.ipConfigurations
    | extend nid = tolower(id),
             pip = tostring(ipc.properties.privateIPAddress)
    | summarize ips = make_set(pip) by nid
  ) on \$left.nicId == \$right.nid
| join kind=leftouter (
    Resources
    | where type =~ 'microsoft.network/virtualnetworks'
    | mv-expand subnet = properties.subnets
    | project sid  = tolower(tostring(subnet.id)),
              rtId = tostring(subnet.properties.routeTable.id)
  ) on \$left.subnetIdLc == \$right.sid
| project name,
          subId        = subscriptionId,
          rgId         = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup),
          subnetId     = tostring(properties.subnet.id),
          privateIp    = strcat_array(ips, ','),
          routeTableId = rtId,
          location
| order by subId asc, name asc
" --first 1000 \
  --query "data[].[name, subId, rgId, subnetId, privateIp, routeTableId, location]" \
  -o tsv >> "$OUT_PE"

echo "Saved: $OUT_PE"
echo "----- Private Endpoint List -----"
# 空值 (沒有 route table) 顯示為 '-' 以便閱讀
sed 's/\t\t/\t-\t/g; s/\t$/\t-/' "$OUT_PE" | column -t -s $'\t' 2>/dev/null \
  || sed 's/\t\t/\t-\t/g; s/\t$/\t-/' "$OUT_PE"
echo ""

# --- Step 2: 對每個唯一 subnet 查詢 PE network policy + route table 關聯 ------
echo "==> [2/3] Fetching privateEndpointNetworkPolicies + routeTable on each unique subnet"

printf "SubnetId\tPrivateEndpointNetworkPolicies\tRouteTableId\n" > "$OUT_SUBNET"

tmp_all=$(mktemp)
tmp_want=$(mktemp)
trap 'rm -f "$tmp_all" "$tmp_want"' EXIT

# 一次撈出所有 VNet 中的 subnet (policy + RT id)
az graph query -q "
Resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand subnet = properties.subnets
| project subnetId = tolower(tostring(subnet.id)),
          policy   = tostring(subnet.properties.privateEndpointNetworkPolicies),
          rtId     = tostring(subnet.properties.routeTable.id)
" --first 1000 \
  --query "data[].[subnetId, policy, rtId]" \
  -o tsv > "$tmp_all"

# 挑出 PE 所在 subnet (轉小寫,Azure resource ID 不區分大小寫)
tail -n +2 "$OUT_PE" | awk -F'\t' '$4 != "" {print tolower($4)}' | sort -u > "$tmp_want"

# inner-join: 以小寫 subnet ID 比對
awk -F'\t' 'NR==FNR{want[$1]=1; next} ($1 in want){print}' "$tmp_want" "$tmp_all" >> "$OUT_SUBNET"

echo "Saved: $OUT_SUBNET"
echo "----- Subnet PE Network Policy + Route Table -----"
# 空值顯示為 '-' 以便閱讀
sed 's/\t\t/\t-\t/g; s/\t$/\t-/' "$OUT_SUBNET" | column -t -s $'\t' 2>/dev/null \
  || sed 's/\t\t/\t-\t/g; s/\t$/\t-/' "$OUT_SUBNET"
echo ""

# --- Step 3: 把 policy != TARGET_POLICY 的 subnet 改成 TARGET_POLICY ----------
# 但當 TARGET_POLICY 需要 UDR (RouteTableEnabled / Enabled) 時,
# 只處理「已經 associate route table」的 subnet,避免空踢改設定卻沒有效果
echo "==> [3/3] Set privateEndpointNetworkPolicies = ${TARGET_POLICY} on subnets that don't match"

need_rt=0
case "$TARGET_POLICY" in
  RouteTableEnabled|Enabled) need_rt=1 ;;
esac

# OUT_SUBNET 欄: $1=SubnetId, $2=Policy, $3=RouteTableId
mismatch=$(tail -n +2 "$OUT_SUBNET" \
  | awk -F'\t' -v t="$TARGET_POLICY" '$2 != t && $2 != "" && $2 != "ERROR" {print $1"\t"$2"\t"$3}')

if [[ -z "$mismatch" ]]; then
  echo "All subnets already set to ${TARGET_POLICY}. Nothing to change."
else
  if [[ "$need_rt" == "1" ]]; then
    candidate_subnets=$(echo "$mismatch" | awk -F'\t' '$3 != "" {print $1"\t"$2}')
    skipped_no_rt=$(echo "$mismatch" | awk -F'\t' '$3 == "" {print $1"\t"$2}')
  else
    candidate_subnets=$(echo "$mismatch" | awk -F'\t' '{print $1"\t"$2}')
    skipped_no_rt=""
  fi

  if [[ -n "$skipped_no_rt" ]]; then
    skip_count=$(echo "$skipped_no_rt" | wc -l | tr -d ' ')
    echo "Skipping ${skip_count} subnet(s) without an associated Route Table (target=${TARGET_POLICY} needs UDR):"
    echo "$skipped_no_rt" | awk -F'\t' '{printf "  ~ %s  (current: %s, no route table)\n", $1, $2}'
    echo ""
  fi

  if [[ -z "$candidate_subnets" ]]; then
    echo "No remaining subnets to update."
  else
    count=$(echo "$candidate_subnets" | wc -l | tr -d ' ')
    echo "Found ${count} subnet(s) where policy != ${TARGET_POLICY} and (route table present or not required):"
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
fi
echo ""

echo "Done."
echo "  - Target policy:               $TARGET_POLICY"
echo "  - Private Endpoint list:       $OUT_PE"
echo "  - Subnet network policy state: $OUT_SUBNET"
