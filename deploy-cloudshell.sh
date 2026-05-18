#!/bin/bash
# =============================================================================
# Cloud Shell deployment script for Auto-Grow Azure Files
# =============================================================================
# Runs entirely from Azure Cloud Shell — no GitHub or external hosting needed.
# Notifications use Azure Communication Services Email (no tenant admin / no
# Mail.Send / no cross-tenant headaches).
#
# What this script does:
#   1. Asks you for the deployment parameters (interactive prompts).
#   2. Deploys main.bicep to create:
#        - Automation Account + modules + empty runbook + schedule
#        - Communication Services + Email Service + Managed Domain
#        - Role assignment (Contributor) on ACS for the AA's managed identity
#   3. Uploads the local Grow-FslogixShare.ps1 content into the runbook.
#   4. Publishes the runbook.
#   5. Grants Storage Account Contributor on the target SA to the MI.
#   6. Links the schedule to the runbook with the right parameters.
#   7. Optionally triggers an immediate test run.
#
# Prerequisites in the same directory:
#   - main.bicep
#   - Grow-FslogixShare.ps1
# =============================================================================

set -e

# ---- Colors for readability ----
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---- Ensure az extensions install without interactive prompts ----
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null 2>&1 || true
az extension add --name automation --only-show-errors >/dev/null 2>&1 || true

echo -e "${BLUE}=== Auto-Grow Azure Files — Cloud Shell deployment ===${NC}"
echo

# ---- Check files exist ----
if [ ! -f main.bicep ]; then
    echo "ERROR: main.bicep not found in current directory."
    exit 1
fi
if [ ! -f Grow-FslogixShare.ps1 ]; then
    echo "ERROR: Grow-FslogixShare.ps1 not found in current directory."
    exit 1
fi

# ---- Subscription selection ----
echo -e "${YELLOW}--- Subscription ---${NC}"
echo "Available subscriptions:"
az account list --query "[].{Name:name, Id:id, Default:isDefault}" -o table
echo
CURRENT_SUB=$(az account show --query id -o tsv)
read -p "Subscription ID to deploy to [$CURRENT_SUB]: " SUB_ID
SUB_ID=${SUB_ID:-$CURRENT_SUB}

az account set --subscription "$SUB_ID"
SUB_NAME=$(az account show --query name -o tsv)
echo "  ✓ Using subscription: $SUB_NAME ($SUB_ID)"
echo

# ---- Interactive prompts ----
read -p "Resource group for the Automation Account (will be created if missing): " RG
read -p "Location (e.g. francecentral, westeurope): " LOCATION
read -p "Automation Account name [aa-autogrow-files]: " AA_NAME
AA_NAME=${AA_NAME:-aa-autogrow-files}

echo
echo -e "${YELLOW}--- Target file share ---${NC}"
read -p "Target storage account resource group: " TARGET_RG
read -p "Target storage account name: " TARGET_SA
read -p "Target file share name: " TARGET_SHARE

echo
echo -e "${YELLOW}--- Scaling policy ---${NC}"
read -p "Trigger threshold % [80]: " THRESHOLD
THRESHOLD=${THRESHOLD:-80}
read -p "Growth factor [1.25]: " FACTOR
FACTOR=${FACTOR:-1.25}
read -p "Max quota cap in GiB [4096]: " MAX_QUOTA
MAX_QUOTA=${MAX_QUOTA:-4096}
read -p "Check frequency (PT15M / PT30M / PT1H) [PT30M]: " INTERVAL
INTERVAL=${INTERVAL:-PT30M}

echo
echo -e "${YELLOW}--- Notifications (Azure Communication Services Email) ---${NC}"
read -p "Recipient email for quota-change alerts (leave empty to disable): " NOTIF_EMAIL
if [ -n "$NOTIF_EMAIL" ]; then
    read -p "ACS data location (Europe / United States / etc.) [Europe]: " ACS_DATA_LOC
    ACS_DATA_LOC=${ACS_DATA_LOC:-Europe}
fi

echo
echo -e "${BLUE}=== Summary ===${NC}"
echo "  Subscription          : $SUB_NAME"
echo "  Automation Account RG : $RG ($LOCATION)"
echo "  Automation Account    : $AA_NAME"
echo "  Target SA             : $TARGET_SA / $TARGET_SHARE (RG: $TARGET_RG)"
echo "  Policy                : trigger=${THRESHOLD}% factor=${FACTOR} cap=${MAX_QUOTA}GiB every ${INTERVAL}"
echo "  Notification email    : ${NOTIF_EMAIL:-<disabled>}"
if [ -n "$NOTIF_EMAIL" ]; then
    echo "  ACS data location     : $ACS_DATA_LOC"
fi
echo
read -p "Proceed? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ---- 1. Ensure resource group exists ----
echo
echo -e "${BLUE}[1/6] Ensuring resource group exists...${NC}"
az group create --name "$RG" --location "$LOCATION" --output none
echo "  ✓ Resource group ready"

# ---- 2. Deploy Bicep (AA + modules + empty runbook + schedule + ACS + RBAC) ----
echo
echo -e "${BLUE}[2/6] Deploying Bicep template (this takes ~3-5 minutes)...${NC}"
DEPLOY_NAME="autogrow-$(date +%s)"

BICEP_PARAMS=(
    automationAccountName="$AA_NAME"
    runbookScriptUri=""
    targetResourceGroupName="$TARGET_RG"
    targetStorageAccountName="$TARGET_SA"
    targetFileShareName="$TARGET_SHARE"
    thresholdPercent="$THRESHOLD"
    growthFactor="$FACTOR"
    maxQuotaGiB="$MAX_QUOTA"
    scheduleInterval="$INTERVAL"
    notificationEmail="$NOTIF_EMAIL"
)
if [ -n "$NOTIF_EMAIL" ]; then
    BICEP_PARAMS+=(acsDataLocation="$ACS_DATA_LOC")
fi

az deployment group create \
    --resource-group "$RG" \
    --name "$DEPLOY_NAME" \
    --template-file main.bicep \
    --parameters "${BICEP_PARAMS[@]}" \
    --output none

echo "  ✓ Infrastructure deployed"

# Fetch outputs we need
PRINCIPAL_ID=$(az deployment group show \
    --resource-group "$RG" --name "$DEPLOY_NAME" \
    --query "properties.outputs.managedIdentityPrincipalId.value" -o tsv)

ACS_ENDPOINT=$(az deployment group show \
    --resource-group "$RG" --name "$DEPLOY_NAME" \
    --query "properties.outputs.acsEndpoint.value" -o tsv)

ACS_SENDER=$(az deployment group show \
    --resource-group "$RG" --name "$DEPLOY_NAME" \
    --query "properties.outputs.acsSenderAddress.value" -o tsv)

if [ -z "$PRINCIPAL_ID" ]; then
    echo "ERROR: could not retrieve managed identity principalId from deployment outputs."
    exit 1
fi

if [ -n "$NOTIF_EMAIL" ]; then
    echo "  ACS endpoint        : $ACS_ENDPOINT"
    echo "  ACS sender address  : $ACS_SENDER"
fi

# ---- 3. Grant Storage Account Contributor on target SA to AA's managed identity ----
echo
echo -e "${BLUE}[3/6] Granting Storage Account Contributor on target storage account...${NC}"

ROLE_ID="17d1049b-9a84-46fb-8f53-869881c3d3ab"

SA_SCOPE=$(az storage account show \
    --resource-group "$TARGET_RG" \
    --name "$TARGET_SA" \
    --query "id" -o tsv)

az role assignment create \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$ROLE_ID" \
    --scope "$SA_SCOPE" \
    --output none 2>/dev/null || echo "  (role assignment may already exist, continuing)"

echo "  ✓ Permission granted on $TARGET_SA"

# ---- 4. Upload runbook content ----
echo
echo -e "${BLUE}[4/6] Uploading runbook content from Grow-FslogixShare.ps1...${NC}"

az automation runbook replace-content \
    --resource-group "$RG" \
    --automation-account-name "$AA_NAME" \
    --name "Grow-FslogixShare" \
    --content @Grow-FslogixShare.ps1 \
    --output none

echo "  ✓ Content uploaded (draft)"

# ---- 5. Publish runbook ----
echo
echo -e "${BLUE}[5/6] Publishing runbook...${NC}"

az automation runbook publish \
    --resource-group "$RG" \
    --automation-account-name "$AA_NAME" \
    --name "Grow-FslogixShare" \
    --output none

echo "  ✓ Runbook published"

# ---- 6. Link schedule to runbook (jobSchedule) ----
echo
echo -e "${BLUE}[6/6] Linking schedule to runbook...${NC}"

JOB_SCHED_GUID=$(cat /proc/sys/kernel/random/uuid)

JOB_SCHED_BODY=$(cat <<EOF
{
  "properties": {
    "runbook": { "name": "Grow-FslogixShare" },
    "schedule": { "name": "AutoGrowSchedule" },
    "parameters": {
      "SubscriptionId": "$SUB_ID",
      "ResourceGroupName": "$TARGET_RG",
      "StorageAccountName": "$TARGET_SA",
      "FileShareName": "$TARGET_SHARE",
      "ThresholdPercent": "$THRESHOLD",
      "GrowthFactor": "$FACTOR",
      "MaxQuotaGiB": "$MAX_QUOTA",
      "NotificationEmail": "$NOTIF_EMAIL",
      "AcsEndpoint": "$ACS_ENDPOINT",
      "AcsSenderAddress": "$ACS_SENDER"
    }
  }
}
EOF
)

az rest --method put \
    --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.Automation/automationAccounts/$AA_NAME/jobSchedules/$JOB_SCHED_GUID?api-version=2023-11-01" \
    --body "$JOB_SCHED_BODY" \
    --output none

echo "  ✓ Schedule linked to runbook"

# ---- Done ----
echo
echo -e "${GREEN}=== DEPLOYMENT COMPLETE ===${NC}"
echo
echo "Note: PowerShell modules (Az.Accounts, Az.Storage) may take 10-15 minutes"
echo "to finish importing. Until then, runbook jobs will fail with 'module not found'."
echo
echo "Check module status with:"
echo "  az automation module list -g $RG --automation-account-name $AA_NAME -o table"
echo
echo "Trigger a test run (after modules are ready):"
echo "  az automation runbook start \\"
echo "    -g $RG --automation-account-name $AA_NAME --name Grow-FslogixShare \\"
echo "    --parameters SubscriptionId=$SUB_ID ResourceGroupName=$TARGET_RG \\"
echo "                 StorageAccountName=$TARGET_SA FileShareName=$TARGET_SHARE \\"
echo "                 ThresholdPercent=$THRESHOLD GrowthFactor=$FACTOR MaxQuotaGiB=$MAX_QUOTA \\"
if [ -n "$NOTIF_EMAIL" ]; then
echo "                 NotificationEmail=$NOTIF_EMAIL \\"
echo "                 AcsEndpoint=$ACS_ENDPOINT \\"
echo "                 AcsSenderAddress=$ACS_SENDER"
fi
echo
echo "View job output:"
echo "  Portal → Automation Account → $AA_NAME → Jobs"
echo

read -p "Trigger a test run now (will fail if modules aren't ready yet)? [y/N] " TESTRUN
if [[ "$TESTRUN" =~ ^[Yy]$ ]]; then
    TEST_PARAMS=(
        "SubscriptionId=$SUB_ID"
        "ResourceGroupName=$TARGET_RG"
        "StorageAccountName=$TARGET_SA"
        "FileShareName=$TARGET_SHARE"
        "ThresholdPercent=$THRESHOLD"
        "GrowthFactor=$FACTOR"
        "MaxQuotaGiB=$MAX_QUOTA"
    )
    if [ -n "$NOTIF_EMAIL" ]; then
        TEST_PARAMS+=(
            "NotificationEmail=$NOTIF_EMAIL"
            "AcsEndpoint=$ACS_ENDPOINT"
            "AcsSenderAddress=$ACS_SENDER"
        )
    fi

    JOB_ID=$(az automation runbook start \
        --resource-group "$RG" \
        --automation-account-name "$AA_NAME" \
        --name "Grow-FslogixShare" \
        --parameters "${TEST_PARAMS[@]}" \
        --query "jobId" -o tsv)
    echo "  Test job started: $JOB_ID"
    echo "  Check status: az automation job show -g $RG --automation-account-name $AA_NAME --job-id $JOB_ID"
fi

echo
echo -e "${GREEN}Done.${NC}"
