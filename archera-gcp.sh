#!/usr/bin/env bash
#
# Archera GCP Onboarding Script
# Automates the setup steps from Archera's GCP deployment guide.
#
# Prerequisites:
#   - gcloud CLI authenticated as org Owner
#   - bq CLI available (comes with gcloud SDK)
#   - Permissions: Org Owner on the target GCP organization
#
# What this script does:
#   1. Collects/validates Org ID, Billing Account, Project ID
#   2. Enables required APIs
#   3. Creates BigQuery datasets for billing exports if they don't exist
#   4. Prints instructions for configuring billing exports (Console-only)
#   5. Pre-checks/fixes org IAM policy constraints for Archera's external SA
#   6. Runs the Archera Infrastructure Manager deployment inline
#
# What you still need to do manually after this script:
#   - Configure billing exports in the GCP Console (step 4 above)
#   - Subscribe to "Archera - Subscription" in GCP Marketplace
#   - Complete "Sign up with provider" via Clazar
#   - Complete registration on Archera's site
#
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BOLD}═══ $* ═══${NC}\n"; }

# ─── Preflight ────────────────────────────────────────────────────────────────
command -v gcloud >/dev/null 2>&1 || { err "gcloud CLI not found. Install the Google Cloud SDK first."; exit 1; }
command -v bq >/dev/null 2>&1     || { err "bq CLI not found. It should come with the Google Cloud SDK."; exit 1; }

header "Archera GCP Onboarding"

# ─── Step 1: Organization ID ─────────────────────────────────────────────────
header "Step 1: Organization & Project IDs"

# Try to auto-detect org
DETECTED_ORGS=$(gcloud organizations list --format="value(ID,DISPLAY_NAME)" 2>/dev/null || true)
ORG_COUNT=$(echo "$DETECTED_ORGS" | grep -c . || true)

if [[ "$ORG_COUNT" -eq 1 ]]; then
    ORG_ID=$(echo "$DETECTED_ORGS" | awk '{print $1}')
    ORG_NAME=$(echo "$DETECTED_ORGS" | awk '{$1=""; print $0}' | xargs)
    ok "Detected organization: ${ORG_NAME} (${ORG_ID})"
    read -rp "Use this organization? [Y/n]: " confirm
    if [[ "$confirm" == [nN] ]]; then
        read -rp "Enter Organization ID: " ORG_ID
    fi
elif [[ "$ORG_COUNT" -gt 1 ]]; then
    info "Multiple organizations found:"
    echo "$DETECTED_ORGS" | nl -ba
    read -rp "Enter the Organization ID to use: " ORG_ID
else
    warn "Could not auto-detect organization."
    read -rp "Enter Organization ID: " ORG_ID
fi

# Validate org ID
if ! gcloud organizations describe "$ORG_ID" --format="value(name)" &>/dev/null; then
    err "Cannot access organization ${ORG_ID}. Check your permissions."
    exit 1
fi
ok "Organization ID: ${ORG_ID}"

# ─── Step 2-3: Billing Account ────────────────────────────────────────────────
header "Step 2-3: Billing Account"

BILLING_ACCOUNTS=$(gcloud billing accounts list --format="value(name.basename(),displayName)" --filter="open=true" 2>/dev/null || true)
BILLING_COUNT=$(echo "$BILLING_ACCOUNTS" | grep -c . || true)

if [[ "$BILLING_COUNT" -eq 0 ]]; then
    err "No active billing accounts found. You need billing account access."
    exit 1
elif [[ "$BILLING_COUNT" -eq 1 ]]; then
    BILLING_ACCOUNT_ID=$(echo "$BILLING_ACCOUNTS" | cut -f1)
    BILLING_NAME=$(echo "$BILLING_ACCOUNTS" | cut -f2-)
    ok "Detected billing account: ${BILLING_NAME} (${BILLING_ACCOUNT_ID})"
    read -rp "Use this billing account? [Y/n]: " confirm
    if [[ "$confirm" == [nN] ]]; then
        read -rp "Enter Billing Account ID: " BILLING_ACCOUNT_ID
        BILLING_NAME=""
    fi
else
    info "Multiple billing accounts found:"
    echo ""
    local_idx=1
    while IFS= read -r line; do
        local_id=$(echo "$line" | cut -f1)
        local_name=$(echo "$line" | cut -f2-)
        printf "  %2d) %s  (%s)\n" "$local_idx" "$local_name" "$local_id"
        local_idx=$((local_idx + 1))
    done <<< "$BILLING_ACCOUNTS"
    echo ""
    read -rp "Enter number or Billing Account ID: " billing_pick

    if [[ "$billing_pick" =~ ^[0-9]+$ ]] && [[ "$billing_pick" -ge 1 ]] && [[ "$billing_pick" -le "$BILLING_COUNT" ]]; then
        line=$(echo "$BILLING_ACCOUNTS" | sed -n "${billing_pick}p")
        BILLING_ACCOUNT_ID=$(echo "$line" | cut -f1)
        BILLING_NAME=$(echo "$line" | cut -f2-)
    else
        BILLING_ACCOUNT_ID="$billing_pick"
        BILLING_NAME=""
    fi
fi

if [[ -n "${BILLING_NAME:-}" ]]; then
    ok "Billing Account: ${BILLING_NAME} (${BILLING_ACCOUNT_ID})"
else
    ok "Billing Account ID: ${BILLING_ACCOUNT_ID}"
fi

# ─── Project ID ───────────────────────────────────────────────────────────────
# Supports: exact project ID, substring search, or creating a new project.
# Note: BILLING_ACCOUNT_ID must be set before this section (needed for new projects).

create_project() {
    local proj_id="$1"
    read -rp "Enter a display name for the project [${proj_id}]: " proj_name
    proj_name="${proj_name:-$proj_id}"
    info "Creating project '${proj_name}' (${proj_id}) under org ${ORG_ID}..."
    if gcloud projects create "$proj_id" --name="$proj_name" --organization="$ORG_ID"; then
        ok "Created project: ${proj_id}"
        PROJECT_ID="$proj_id"
        info "Linking billing account ${BILLING_ACCOUNT_ID} to project..."
        if gcloud billing projects link "$proj_id" --billing-account="$BILLING_ACCOUNT_ID"; then
            ok "Billing account linked."
        else
            err "Failed to link billing account. You may need to do this manually."
        fi
        return 0
    else
        err "Failed to create project '${proj_id}'."
        return 1
    fi
}

select_project() {
    local input="$1"
    # First try exact match
    if gcloud projects describe "$input" --format="value(projectId)" &>/dev/null; then
        PROJECT_ID="$input"
        return 0
    fi
    # Otherwise treat as substring search (grep locally — gcloud filter is unreliable)
    info "Searching for projects matching '${input}'..."
    local matches
    matches=$(gcloud projects list --format="value(PROJECT_ID,NAME)" 2>/dev/null \
        | grep -i "$input" || true)
    local match_count
    match_count=$(echo "$matches" | grep -c . || true)

    if [[ "$match_count" -eq 0 ]]; then
        warn "No projects found matching '${input}'."
        return 1
    elif [[ "$match_count" -eq 1 ]]; then
        PROJECT_ID=$(echo "$matches" | awk '{print $1}')
        local proj_name
        proj_name=$(echo "$matches" | awk '{$1=""; print $0}' | xargs)
        ok "Found project: ${proj_name} (${PROJECT_ID})"
        read -rp "Use this project? [Y/n]: " confirm
        [[ "$confirm" == [nN] ]] && return 1
        return 0
    else
        info "Multiple projects match '${input}':"
        echo "$matches" | nl -ba
        read -rp "Enter the exact Project ID from the list above: " PROJECT_ID
        return 0
    fi
}

prompt_for_project() {
    echo "  [S] Search for an existing project"
    echo "  [N] Create a new project"
    read -rp "Choose [S/n]: " choice
    choice="${choice:-S}"

    if [[ "$choice" == [nN] ]]; then
        read -rp "Enter new Project ID (lowercase, hyphens ok): " new_proj_id
        until create_project "$new_proj_id"; do
            read -rp "Try again — enter new Project ID: " new_proj_id
        done
    else
        read -rp "Enter Project ID or search term (substring match): " proj_input
        until select_project "$proj_input"; do
            read -rp "Try again — enter Project ID or search term: " proj_input
        done
    fi
}

CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
if [[ -n "$CURRENT_PROJECT" ]]; then
    info "Current gcloud project: ${CURRENT_PROJECT}"
    read -rp "Use this project for Archera resources? [Y/n]: " confirm
    if [[ "$confirm" != [nN] ]]; then
        PROJECT_ID="$CURRENT_PROJECT"
    else
        prompt_for_project
    fi
else
    prompt_for_project
fi

# Set the project
gcloud config set project "$PROJECT_ID" --quiet
ok "Project ID: ${PROJECT_ID}"

# ─── Enable required APIs ─────────────────────────────────────────────────────
header "Enabling Required APIs"

APIS=(
    "bigquery.googleapis.com"
    "bigquerydatatransfer.googleapis.com"
    "billingbudgets.googleapis.com"
    "cloudbilling.googleapis.com"
    "config.googleapis.com"           # Infrastructure Manager
    "iam.googleapis.com"
    "cloudresourcemanager.googleapis.com"
    "storage.googleapis.com"
    "storagetransfer.googleapis.com"
    "cloudcommerceprocurement.googleapis.com"
)

for api in "${APIS[@]}"; do
    if gcloud services list --enabled --filter="config.name=${api}" --format="value(config.name)" 2>/dev/null | grep -q "$api"; then
        ok "Already enabled: ${api}"
    else
        info "Enabling ${api}..."
        gcloud services enable "$api" --quiet
        ok "Enabled: ${api}"
    fi
done

# ─── Step 4-6: Billing Export Datasets ────────────────────────────────────────
header "Step 4-6: Billing Export Datasets"

# Archera requires:
#   - Detailed usage cost export -> a BigQuery dataset
#   - Pricing export -> can be same dataset as above
#   - CUD export -> MUST be a separate dataset

# ── Try to detect already-configured billing exports ──
info "Checking for existing billing export configuration..."

# gcloud beta billing exports list isn't available, but we can look for well-known
# tables that GCP creates in datasets when exports are enabled:
#   - Detailed usage cost: gcp_billing_export_resource_v1_*
#   - Pricing:             cloud_pricing_export
#   - CUD:                 committed_use_discount_*

# List all datasets in the project
info "Scanning BigQuery datasets in project ${PROJECT_ID}..."
EXISTING_DATASETS=$(bq ls --format=prettyjson --project_id="$PROJECT_ID" 2>/dev/null \
    | grep -o '"datasetId": "[^"]*"' | sed 's/"datasetId": "//;s/"//' || true)
EXISTING_COUNT=$(echo "$EXISTING_DATASETS" | grep -c . || true)

DETECTED_BILLING_DS=""
DETECTED_PRICING_DS=""
DETECTED_CUD_DS=""

if [[ "$EXISTING_COUNT" -gt 0 ]]; then
    ok "Found ${EXISTING_COUNT} dataset(s) in project:"
    echo "$EXISTING_DATASETS" | nl -ba
    echo ""

    # Probe each dataset for known export tables
    info "Probing datasets for existing billing export tables..."
    while IFS= read -r ds; do
        [[ -z "$ds" ]] && continue
        tables=$(bq ls --format=prettyjson "${PROJECT_ID}:${ds}" 2>/dev/null || true)

        if echo "$tables" | grep -q "gcp_billing_export_resource_v1_"; then
            DETECTED_BILLING_DS="$ds"
            ok "  ${ds} — contains Detailed Usage Cost export"
        fi
        if echo "$tables" | grep -q "cloud_pricing_export"; then
            DETECTED_PRICING_DS="$ds"
            ok "  ${ds} — contains Pricing export"
        fi
        if echo "$tables" | grep -q "committed_use_discount_"; then
            DETECTED_CUD_DS="$ds"
            ok "  ${ds} — contains CUD export"
        fi
    done <<< "$EXISTING_DATASETS"
    echo ""
fi

# ── Helper: pick an existing dataset or create a new one ──
# Usage: pick_or_create_dataset "label" "default_name" "detected_name" RESULT_VAR
pick_or_create_dataset() {
    local label="$1"
    local default_name="$2"
    local detected="$3"
    local _varname="$4"

    echo ""
    info "${label}:"

    # If we auto-detected one, offer it first
    if [[ -n "$detected" ]]; then
        ok "Detected existing export in dataset: ${detected}"
        read -rp "  Use '${detected}'? [Y/n]: " confirm
        if [[ "$confirm" != [nN] ]]; then
            eval "$_varname=\"$detected\""
            ok "Using: ${!_varname}"
            return
        fi
    fi

    if [[ "$EXISTING_COUNT" -gt 0 ]]; then
        echo "  [S] Select an existing dataset"
        echo "  [C] Create a new dataset"
        read -rp "  Choose [S/c]: " choice
        choice="${choice:-S}"
    else
        choice="C"
    fi

    if [[ "$choice" == [sS] && "$EXISTING_COUNT" -gt 0 ]]; then
        echo ""
        echo "$EXISTING_DATASETS" | nl -ba
        echo ""
        read -rp "  Enter dataset name or number from list: " ds_pick

        if [[ "$ds_pick" =~ ^[0-9]+$ ]] && [[ "$ds_pick" -ge 1 ]] && [[ "$ds_pick" -le "$EXISTING_COUNT" ]]; then
            eval "$_varname=\"$(echo "$EXISTING_DATASETS" | sed -n "${ds_pick}p" | xargs)\""
        else
            if echo "$EXISTING_DATASETS" | grep -qx "$ds_pick"; then
                eval "$_varname=\"$ds_pick\""
            else
                warn "Dataset '${ds_pick}' not found in project. Treating as new dataset name."
                eval "$_varname=\"$ds_pick\""
            fi
        fi
        ok "Selected: ${!_varname}"
    else
        read -rp "  Dataset name [${default_name}]: " new_name
        new_name="${new_name:-$default_name}"
        eval "$_varname=\"$new_name\""

        if bq show --dataset "${PROJECT_ID}:${!_varname}" &>/dev/null; then
            ok "Dataset already exists: ${PROJECT_ID}:${!_varname}"
        else
            read -rp "  BigQuery location (e.g., US, EU) [US]: " bq_loc
            bq_loc="${bq_loc:-US}"
            info "Creating dataset ${PROJECT_ID}:${!_varname} in ${bq_loc}..."
            bq mk --dataset --location="$bq_loc" "${PROJECT_ID}:${!_varname}"
            ok "Created dataset: ${PROJECT_ID}:${!_varname}"
        fi
    fi
}

BILLING_DATASET=""
PRICING_DATASET=""
CUD_DATASET=""

pick_or_create_dataset "Detailed Usage Cost export dataset" "billing_export" "$DETECTED_BILLING_DS" BILLING_DATASET

# If pricing was detected in the same dataset as billing, default to that
if [[ -n "$DETECTED_PRICING_DS" && "$DETECTED_PRICING_DS" == "$BILLING_DATASET" ]]; then
    info "Pricing export is already in the same dataset as billing (${BILLING_DATASET})."
    PRICING_DATASET="$BILLING_DATASET"
    ok "Pricing export dataset: ${PRICING_DATASET}"
else
    info "Pricing export can use the same dataset as Detailed Usage Cost."
    read -rp "Use '${BILLING_DATASET}' for Pricing export too? [Y/n]: " same_pricing
    if [[ "$same_pricing" == [nN] ]]; then
        pick_or_create_dataset "Pricing export dataset" "pricing_export" "$DETECTED_PRICING_DS" PRICING_DATASET
    else
        PRICING_DATASET="$BILLING_DATASET"
        ok "Pricing export dataset: ${PRICING_DATASET} (same as billing)"
    fi
fi

pick_or_create_dataset "CUD export dataset (MUST be separate)" "billing_export_cud" "$DETECTED_CUD_DS" CUD_DATASET

# Validate CUD is separate
if [[ "$CUD_DATASET" == "$BILLING_DATASET" || "$CUD_DATASET" == "$PRICING_DATASET" ]]; then
    err "CUD dataset MUST be different from the billing/pricing dataset per Archera requirements."
    exit 1
fi

BILLING_DATASET_FULL="${PROJECT_ID}.${BILLING_DATASET}"
PRICING_DATASET_FULL="${PROJECT_ID}.${PRICING_DATASET}"
CUD_DATASET_FULL="${PROJECT_ID}.${CUD_DATASET}"

# ─── Configure Billing Exports ────────────────────────────────────────────────
header "Configuring Billing Exports"

warn "Billing export toggle via CLI has limited support."
warn "If the exports aren't already configured, set them up in the Console:"
echo ""
echo "  1. Go to: https://console.cloud.google.com/billing/${BILLING_ACCOUNT_ID}/export"
echo "  2. 'Detailed usage cost' export -> dataset: ${BILLING_DATASET} in project ${PROJECT_ID}"
echo "  3. 'Pricing' export            -> dataset: ${PRICING_DATASET} in project ${PROJECT_ID}"
echo "  4. 'Committed Use Discounts'   -> dataset: ${CUD_DATASET} in project ${PROJECT_ID}"
echo ""
echo "  If you already configured these manually, just confirm and continue."
echo ""
read -rp "Press Enter once billing exports are configured..."

# ─── Summary of IDs ───────────────────────────────────────────────────────────
header "Collected IDs for Archera Onboarding"

echo -e "${BOLD}Organization ID:${NC}           ${ORG_ID}"
echo -e "${BOLD}Project ID:${NC}                ${PROJECT_ID}"
echo -e "${BOLD}Billing Account ID:${NC}        ${BILLING_ACCOUNT_ID}"
echo -e "${BOLD}Billing Export Project ID:${NC}  ${PROJECT_ID}"
echo -e "${BOLD}Billing Export Dataset ID:${NC}  ${BILLING_DATASET_FULL}"
echo -e "${BOLD}Pricing Export Dataset ID:${NC}  ${PRICING_DATASET_FULL}"
echo -e "${BOLD}CUD Export Dataset ID:${NC}      ${CUD_DATASET_FULL}"

echo ""
info "Save these values — you'll need them in the Archera onboarding form."

# ─── Step 7: Org IAM Policy Pre-check ────────────────────────────────────────
header "Step 7a: Org IAM Policy Pre-check"

ARCHERA_SA="application@archera.iam.gserviceaccount.com"
ARCHERA_CUSTOMER_ID="C02c8qgso"

info "Checking org policy constraints that could block Archera's external service account..."

# Check iam.managed.allowedPolicyMembers
MANAGED_POLICY=$(gcloud org-policies describe iam.managed.allowedPolicyMembers \
    --organization="$ORG_ID" --format=json 2>/dev/null || echo "{}")

if echo "$MANAGED_POLICY" | grep -q "allowedMemberSubjects"; then
    if echo "$MANAGED_POLICY" | grep -q "$ARCHERA_SA"; then
        ok "iam.managed.allowedPolicyMembers already includes ${ARCHERA_SA}"
    else
        warn "iam.managed.allowedPolicyMembers is set but does NOT include Archera's SA."
        info "Adding serviceAccount:${ARCHERA_SA} to allowedMemberSubjects..."
        read -rp "Proceed? [Y/n]: " confirm
        if [[ "$confirm" != [nN] ]]; then
            # Get current policy YAML, add the SA, and apply
            POLICY_FILE=$(mktemp)
            gcloud org-policies describe iam.managed.allowedPolicyMembers \
                --organization="$ORG_ID" --format=json > "$POLICY_FILE" 2>/dev/null

            # Use gcloud org-policies set-custom-constraint or set-policy
            # The managed constraint uses set-policy with the spec
            if gcloud org-policies set-policy "$POLICY_FILE" \
                --update-mask="spec.rules" 2>/dev/null; then
                ok "Updated iam.managed.allowedPolicyMembers"
            else
                warn "Could not auto-update the policy. Adding manually:"
                echo ""
                echo "  gcloud org-policies describe iam.managed.allowedPolicyMembers \\"
                echo "    --organization=${ORG_ID}"
                echo ""
                echo "  Then add 'serviceAccount:${ARCHERA_SA}' to allowedMemberSubjects"
                echo "  and apply with gcloud org-policies set-policy."
                echo ""
                read -rp "Press Enter once you've updated the policy (or to continue anyway)..."
            fi
            rm -f "$POLICY_FILE"
        fi
    fi
else
    ok "iam.managed.allowedPolicyMembers: not set or no restrictions (OK)"
fi

# Check iam.allowedPolicyMemberDomains
DOMAIN_POLICY=$(gcloud org-policies describe iam.allowedPolicyMemberDomains \
    --organization="$ORG_ID" --format=json 2>/dev/null || echo "{}")

if echo "$DOMAIN_POLICY" | grep -q "allowedValues\|values"; then
    if echo "$DOMAIN_POLICY" | grep -q "$ARCHERA_CUSTOMER_ID"; then
        ok "iam.allowedPolicyMemberDomains already includes ${ARCHERA_CUSTOMER_ID}"
    else
        warn "iam.allowedPolicyMemberDomains is set but does NOT include Archera's customer ID."
        info "Adding ${ARCHERA_CUSTOMER_ID} to allowedValues..."
        read -rp "Proceed? [Y/n]: " confirm
        if [[ "$confirm" != [nN] ]]; then
            POLICY_FILE=$(mktemp)
            gcloud org-policies describe iam.allowedPolicyMemberDomains \
                --organization="$ORG_ID" --format=json > "$POLICY_FILE" 2>/dev/null

            if gcloud org-policies set-policy "$POLICY_FILE" \
                --update-mask="spec.rules" 2>/dev/null; then
                ok "Updated iam.allowedPolicyMemberDomains"
            else
                warn "Could not auto-update the policy. Adding manually:"
                echo ""
                echo "  gcloud org-policies describe iam.allowedPolicyMemberDomains \\"
                echo "    --organization=${ORG_ID}"
                echo ""
                echo "  Then add '${ARCHERA_CUSTOMER_ID}' to allowedValues"
                echo "  and apply with gcloud org-policies set-policy."
                echo ""
                read -rp "Press Enter once you've updated the policy (or to continue anyway)..."
            fi
            rm -f "$POLICY_FILE"
        fi
    fi
else
    ok "iam.allowedPolicyMemberDomains: not set or no restrictions (OK)"
fi

# ─── Step 7b: Archera Infrastructure Manager Deployment ──────────────────────
header "Step 7b: Archera Infrastructure Manager Deployment"

echo "Archera provides a unique GCS URL from their onboarding page."
echo "It looks like: gs://archera-production-onboarding/<unique-id>/"
echo ""
read -rp "Paste the GCS URL (or full gsutil command, or press Enter to skip): " GCS_INPUT

# Extract just the gs:// URL if they pasted the full gsutil command
if [[ -n "$GCS_INPUT" ]]; then
    GCS_SOURCE=$(echo "$GCS_INPUT" | grep -oE 'gs://[^ |]+' | head -1)
    # Ensure trailing slash and strip deploy.sh if present
    GCS_SOURCE="${GCS_SOURCE%/deploy.sh}"
    GCS_SOURCE="${GCS_SOURCE%/}/"

    if [[ -z "$GCS_SOURCE" || "$GCS_SOURCE" == "/" ]]; then
        err "Could not parse a gs:// URL from your input."
        exit 1
    fi

    ok "GCS source: ${GCS_SOURCE}"

    DEPLOYMENT_ID="$(echo "$GCS_SOURCE" | sed 's|gs://||;s|/.*||')"
    SERVICE_ACCOUNT_NAME="infra-admin-${DEPLOYMENT_ID/-onboarding/}"
    SERVICE_ACCOUNT="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
    LOCATION="us-central1"

    EXPORT_DATASETS="[\"${CUD_DATASET_FULL}\",\"${BILLING_DATASET_FULL}\"]"

    info "Deployment ID:    ${DEPLOYMENT_ID}"
    info "Service Account:  ${SERVICE_ACCOUNT}"
    info "Export Datasets:  ${EXPORT_DATASETS}"
    echo ""
    read -rp "Continue with deployment? [Y/n]: " confirm

    if [[ "$confirm" != [nN] ]]; then
        export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

        # Create temporary service account
        info "Creating deployment service account..."
        if gcloud iam service-accounts describe "${SERVICE_ACCOUNT}" --project="${PROJECT_ID}" &>/dev/null; then
            ok "Service account already exists."
        else
            gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
                --display-name="Archera Infrastructure Administrator Service Account" \
                --project="${PROJECT_ID}" --quiet --no-user-output-enabled
            ok "Created service account: ${SERVICE_ACCOUNT}"
        fi

        # Cleanup trap: delete the temporary SA on exit
        cleanup_sa() {
            info "Cleaning up temporary service account..."
            gcloud iam service-accounts delete "${SERVICE_ACCOUNT}" --quiet --no-user-output-enabled 2>/dev/null || true
        }
        trap cleanup_sa EXIT

        # Grant roles
        info "Granting Owner role on project ${PROJECT_ID}..."
        gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
            --member="serviceAccount:${SERVICE_ACCOUNT}" \
            --role="roles/owner" --condition=None \
            --quiet --no-user-output-enabled
        ok "Granted Owner on project."

        info "Granting Role Administrator on project..."
        gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
            --member="serviceAccount:${SERVICE_ACCOUNT}" \
            --role="roles/iam.roleAdmin" --condition=None \
            --quiet --no-user-output-enabled
        ok "Granted Role Administrator."

        info "Granting Organization Administrator on org ${ORG_ID}..."
        gcloud organizations add-iam-policy-binding "${ORG_ID}" \
            --member="serviceAccount:${SERVICE_ACCOUNT}" \
            --role="roles/resourcemanager.organizationAdmin" --condition=None \
            --quiet --no-user-output-enabled
        ok "Granted Organization Administrator."

        info "Granting Organization Role Administrator..."
        gcloud organizations add-iam-policy-binding "${ORG_ID}" \
            --member="serviceAccount:${SERVICE_ACCOUNT}" \
            --role="roles/iam.organizationRoleAdmin" --condition=None \
            --quiet --no-user-output-enabled
        ok "Granted Organization Role Administrator."

        info "Granting Billing Administrator on ${BILLING_ACCOUNT_ID}..."
        gcloud billing accounts add-iam-policy-binding "${BILLING_ACCOUNT_ID}" \
            --member="serviceAccount:${SERVICE_ACCOUNT}" \
            --role="roles/billing.admin" \
            --quiet --no-user-output-enabled
        ok "Granted Billing Administrator."

        # Write Terraform inputs
        TFVARS_FILE=$(mktemp)
        cat > "$TFVARS_FILE" <<TFEOF
org_id = "${ORG_ID}"
billing_account_id = "${BILLING_ACCOUNT_ID}"
billing_project = "${PROJECT_ID}"
export_datasets = ${EXPORT_DATASETS}
TFEOF
        ok "Wrote Terraform inputs."

        # Run Infrastructure Manager deployment
        info "Initiating Infrastructure Manager deployment: ${DEPLOYMENT_ID}..."
        if gcloud infra-manager deployments apply \
            "projects/${PROJECT_ID}/locations/${LOCATION}/deployments/${DEPLOYMENT_ID}" \
            --gcs-source="${GCS_SOURCE}" \
            --inputs-file="$TFVARS_FILE" \
            --service-account="projects/${PROJECT_ID}/serviceAccounts/${SERVICE_ACCOUNT}" \
            --location="${LOCATION}" \
            --quiet; then

            STATUS=$(gcloud infra-manager deployments describe "${DEPLOYMENT_ID}" \
                --location="${LOCATION}" --format="value(state)" 2>/dev/null || echo "UNKNOWN")

            if [[ "$STATUS" == "ACTIVE" ]]; then
                ok "Infrastructure deployment succeeded! Status: ${STATUS}"
                gcloud infra-manager deployments describe "${DEPLOYMENT_ID}" \
                    --location="${LOCATION}" \
                    --format="json(terraformBlueprint.outputs)" 2>/dev/null || true
            else
                err "Deployment reached state: ${STATUS}"
                ERROR_DETAIL=$(gcloud infra-manager deployments describe "${DEPLOYMENT_ID}" \
                    --location="${LOCATION}" --format="value(stateDetail)" 2>/dev/null || true)
                [[ -n "$ERROR_DETAIL" ]] && err "Detail: ${ERROR_DETAIL}"
                echo ""
                echo "  View logs: https://console.cloud.google.com/infra-manager/locations/${LOCATION}/deployments/${DEPLOYMENT_ID}?project=${PROJECT_ID}"
            fi
        else
            err "Infrastructure Manager deployment failed."
            echo ""
            echo "  View logs: https://console.cloud.google.com/infra-manager/locations/${LOCATION}/deployments/${DEPLOYMENT_ID}?project=${PROJECT_ID}"
            echo ""
            warn "You can retry with DEBUG=true for more detail."
        fi

        rm -f "$TFVARS_FILE"
    else
        warn "Skipped deployment."
    fi
else
    warn "Skipped. Get the GCS URL from Archera's onboarding page when ready."
fi

# ─── Steps 8-10: Manual Steps ─────────────────────────────────────────────────
header "Remaining Manual Steps"

echo "The following steps must be done in the GCP Console / browser:"
echo ""
echo "  ${BOLD}Step 8:${NC} Subscribe to Archera"
echo "    → Search 'Archera' in GCP Marketplace"
echo "    → Subscribe to 'Archera - Subscription'"
echo "    → Make sure billing account ${BILLING_ACCOUNT_ID} is selected"
echo ""
echo "  ${BOLD}Step 9:${NC} Sign up with Provider"
echo "    → Click 'Sign up with provider' after subscribing"
echo "    → You'll be redirected to clazar.io to sign in"
echo ""
echo "  ${BOLD}Step 10:${NC} Complete Registration"
echo "    → Fill in company name and details on Archera's registration page"
echo "    → Or log into your existing Archera account"
echo ""

ok "Script complete. Refer to the ID summary above when filling out Archera's onboarding form."
