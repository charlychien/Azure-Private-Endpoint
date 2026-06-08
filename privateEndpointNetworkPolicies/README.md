# list-pe-network-policy.sh

A small Bash utility for **auditing and managing `privateEndpointNetworkPolicies`** on every subnet that hosts a Private Endpoint (PE) across all Azure subscriptions you can access.

## What it does

The script runs three sequential steps:

1. **List all Private Endpoints** across every accessible subscription (via Azure Resource Graph) and write them to `private-endpoints.tsv`. Each PE row includes its name, subscription id, resource-group id, subnet id, **private IP(s)**, and location.
2. **Inspect each unique subnet** referenced by those PEs and fetch the current `privateEndpointNetworkPolicies` value. Results go to `subnet-pe-network-policies.tsv`.
3. **Reconcile** — find subnets whose policy ≠ `TARGET_POLICY` and (optionally) update them to `TARGET_POLICY`. By default this is a **dry-run**; set `APPLY=1` to actually apply changes.

## Why `privateEndpointNetworkPolicies` matters

This subnet-level setting controls whether NSGs and Route Tables are evaluated for traffic destined to a Private Endpoint hosted in the subnet:

| Value | NSG applies to PE | UDR / Route Table applies to PE |
|---|:---:|:---:|
| `Disabled` | ✗ | ✗ |
| `Enabled` | ✓ | ✓ |
| `NetworkSecurityGroupEnabled` | ✓ | ✗ |
| `RouteTableEnabled` *(script default)* | ✗ | ✓ |

In an ALZ + vWAN + Routing Intent design, `RouteTableEnabled` is often the desired setting so PE traffic is still subject to UDR (e.g., to keep it from being unnecessarily steered through Azure Firewall), while avoiding the operational cost of maintaining NSG rules for every PE.

## Prerequisites

- **Azure CLI** (`az`) installed and on `PATH`
- Logged in: `az login`
- Network role with permission to:
  - Read PEs / VNets / Subnets across the target subscriptions (e.g. *Reader*)
  - **Write** to subnets (only needed for `APPLY=1`) — typically *Network Contributor* on the VNet
- `resource-graph` Azure CLI extension — installed automatically by the script if missing
- A POSIX-style shell. Tested on **Git Bash for Windows**, WSL, Linux, macOS, and Azure Cloud Shell
- Optional: `column` (for prettier tables; falls back to `cat` if absent)

> Note for Windows users: when running under Git Bash / MSYS, the script exports `MSYS_NO_PATHCONV=1` and `MSYS2_ARG_CONV_EXCL='*'` to stop MSYS from mangling Azure resource IDs (which start with `/subscriptions/...`).

## Usage

```bash
# Dry-run (default target = RouteTableEnabled)
./list-pe-network-policy.sh

# Actually apply changes (RouteTableEnabled)
APPLY=1 ./list-pe-network-policy.sh

# Apply a different target policy
APPLY=1 TARGET_POLICY=Enabled                      ./list-pe-network-policy.sh   # NSG + UDR
APPLY=1 TARGET_POLICY=NetworkSecurityGroupEnabled  ./list-pe-network-policy.sh   # NSG only
APPLY=1 TARGET_POLICY=Disabled                     ./list-pe-network-policy.sh   # both off
```

If your environment is not bash by default (Windows PowerShell), invoke Git Bash directly:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -lc "cd /c/path/to/testing-area && ./list-pe-network-policy.sh"
```

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `TARGET_POLICY` | `RouteTableEnabled` | Desired value to converge subnets to. Must be one of `Disabled`, `Enabled`, `NetworkSecurityGroupEnabled`, `RouteTableEnabled`. |
| `APPLY` | `0` | Set to `1` to actually call `az network vnet subnet update`. Anything else = dry-run. |
| `OUT_PE` | `private-endpoints.tsv` | Output path for the Step-1 PE list. |
| `OUT_SUBNET` | `subnet-pe-network-policies.tsv` | Output path for the Step-2 subnet policy state. |

## Output files

Both files are tab-separated and overwritten on each run.

### `private-endpoints.tsv`

| Column | Notes |
|---|---|
| `Name` | PE resource name |
| `SubscriptionId` | Subscription holding the PE |
| `ResourceGroupId` | Full `/subscriptions/.../resourceGroups/<name>` path |
| `SubnetId` | Full subnet resource ID (may be in a different subscription) |
| `PrivateIP` | One or more IPs assigned to the PE NIC, comma-separated (PEs with multiple sub-resources, e.g. AMPLS or Storage, will list each) |
| `Location` | Azure region |

### `subnet-pe-network-policies.tsv`

| Column | Notes |
|---|---|
| `SubnetId` | Each **unique** subnet referenced by a PE |
| `PrivateEndpointNetworkPolicies` | Current value (`Disabled`, `Enabled`, `NetworkSecurityGroupEnabled`, `RouteTableEnabled`, or `ERROR` if the lookup failed) |

## Step 3 console output

Step 3 prints two summary blocks at the end of an `APPLY=1` run:

```
----- Modified Subnets (N) -----
  ✓ <subnet id>
  ...

----- Failed Subnets (N) -----        # only when there were failures
  ✗ <subnet id>
```

The script always exits 0 even when individual subnet updates fail, so check the `Failed Subnets` section in CI pipelines.

## Safety notes

- **Idempotent**: subnets already at `TARGET_POLICY` are skipped (Step 3 prints `All subnets already set to ... Nothing to change.`).
- **`set -euo pipefail`** — the script aborts on unexpected errors.
- **Dry-run by default** — you must explicitly opt in with `APPLY=1`.
- **Changing this setting affects live traffic.** Moving from `Disabled` to `Enabled` (or `NetworkSecurityGroupEnabled`) can break existing PE traffic if NSGs in the subnet do not permit it. Validate NSG/UDR before applying broadly.
- The script does not modify NSGs, route tables, or PE configuration — only the `privateEndpointNetworkPolicies` field on each subnet.

## Limitations

- Resource Graph results are capped at `--first 1000` — sufficient for most environments; raise / paginate if you have more PEs.
- Only PEs visible to the signed-in identity (across all reachable tenants/subs) appear; PEs in subscriptions you cannot read are silently excluded.
- Cross-tenant PEs are not specially handled.

## Files in this folder

- [list-pe-network-policy.sh](list-pe-network-policy.sh) — the script
- `private-endpoints.tsv` — generated, Step 1 output
- `subnet-pe-network-policies.tsv` — generated, Step 2 output
