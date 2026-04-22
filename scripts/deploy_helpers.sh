#!/usr/bin/env bash
set -euo pipefail

load_environment_config() {
    local env_name="${1:-}"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    [[ -f "$script_dir/environments/common.env" ]] && source "$script_dir/environments/common.env"

    if [[ -n "$env_name" ]]; then
        local env_file="$script_dir/environments/${env_name}.env"
        [[ -f "$env_file" ]] || { echo "Environment configuration not found: $env_file"; exit 1; }
        source "$env_file"
    fi
}

check_azure_auth() {
    az account show &>/dev/null || { echo "Not authenticated to Azure. Run: az login"; exit 1; }
    local sub
    sub=$(az account show --query name -o tsv)
    echo "✓ Authenticated to Azure (Subscription: $sub)"
}

ensure_resource_group() {
    local rg="${1:-$RESOURCE_GROUP}"
    local loc="${2:-$LOCATION}"
    if ! az group show -n "$rg" &>/dev/null; then
        echo "Creating resource group: $rg in $loc"
        az group create -n "$rg" -l "$loc" -o none
        echo "✓ Created resource group: $rg"
    else
        echo "✓ Resource group exists: $rg"
    fi
}

ensure_acr_registry() {
    local acr="${1:-$REGISTRY_NAME}"
    local acr_rg="${ACR_RESOURCE_GROUP:-$RESOURCE_GROUP}"
    local sku="${ACR_SKU:-Standard}"

    local actual_rg
    actual_rg=$(az acr show -n "$acr" --query resourceGroup -o tsv 2>/dev/null || true)

    if [[ -z "$actual_rg" ]]; then
        echo "Creating ACR: $acr in $acr_rg (SKU: $sku)"
        az acr create -n "$acr" -g "$acr_rg" -l "${LOCATION:-centralus}" --sku "$sku" --admin-enabled true -o none
        echo "✓ Created ACR: $acr"
    elif [[ "$actual_rg" != "$acr_rg" ]]; then
        echo "Note: ACR $acr exists in $actual_rg (using as-is)"
    else
        echo "✓ ACR exists: $acr"
    fi
}

get_acr_credentials() {
    local acr="${1:-$REGISTRY_NAME}"
    ACR_USERNAME=$(az acr credential show -n "$acr" --query username -o tsv)
    ACR_PASSWORD=$(az acr credential show -n "$acr" --query "passwords[0].value" -o tsv)
}

require_secrets_from_env() {
    local kv="${KEY_VAULT_NAME:-}"

    if [[ -z "${AZURE_STORAGE_CONNECTION_STRING:-}" ]]; then
        [[ -n "$kv" ]] || { echo "AZURE_STORAGE_CONNECTION_STRING not set and KEY_VAULT_NAME not configured"; exit 1; }
        local secret_name="${KV_SECRET_AZURE_STORAGE:-azure-storage-connection-string-reconciliation}"
        echo "Fetching $secret_name from Key Vault $kv..."
        AZURE_STORAGE_CONNECTION_STRING=$(az keyvault secret show --vault-name "$kv" --name "$secret_name" --query value -o tsv)
    fi

    if [[ -z "${API_AUTH_PASSWORD:-}" ]]; then
        [[ -n "$kv" ]] || { echo "API_AUTH_PASSWORD not set and KEY_VAULT_NAME not configured"; exit 1; }
        local secret_name="${KV_SECRET_API_AUTH_PASSWORD:-api-auth-password-reconciliation}"
        echo "Fetching $secret_name from Key Vault $kv..."
        API_AUTH_PASSWORD=$(az keyvault secret show --vault-name "$kv" --name "$secret_name" --query value -o tsv)
    fi
}

ensure_aca_environment() {
    local env_name="${1:-$CONTAINER_APPS_ENV}"
    local rg="${2:-$RESOURCE_GROUP}"
    local loc="${3:-$LOCATION}"

    if ! az containerapp env show -n "$env_name" -g "$rg" &>/dev/null; then
        echo "Creating ACA environment: $env_name"
        az containerapp env create -n "$env_name" -g "$rg" -l "$loc" -o none
        echo "✓ Created ACA environment: $env_name"
    else
        echo "✓ Container Apps environment exists: $env_name"
    fi
}

ensure_role_assignment() {
    local principal_id="$1"
    local role="$2"
    local scope="$3"

    if ! az role assignment list --assignee "$principal_id" --role "$role" --scope "$scope" --query '[0].id' -o tsv 2>/dev/null | grep -q .; then
        az role assignment create --assignee "$principal_id" --role "$role" --scope "$scope" -o none
        echo "✓ Granted: $role"
    else
        echo "✓ Already assigned: $role"
    fi
}

setup_managed_identity() {
    local job_name="${1:-$CONTAINER_APP_JOB}"
    local rg="${2:-$RESOURCE_GROUP}"

    echo "Setting up managed identity for $job_name..."
    az containerapp job identity assign --system-assigned -n "$job_name" -g "$rg" -o none

    local principal_id
    principal_id=$(az containerapp job show -n "$job_name" -g "$rg" --query "identity.principalId" -o tsv)

    local acr_id
    acr_id=$(az acr show -n "$REGISTRY_NAME" --query id -o tsv)
    ensure_role_assignment "$principal_id" "AcrPull" "$acr_id"

    if [[ -n "${KEY_VAULT_NAME:-}" ]]; then
        local kv_id
        kv_id=$(az keyvault show -n "$KEY_VAULT_NAME" --query id -o tsv)
        local rbac_enabled
        rbac_enabled=$(az keyvault show -n "$KEY_VAULT_NAME" --query properties.enableRbacAuthorization -o tsv)
        if [[ "$rbac_enabled" == "true" ]]; then
            ensure_role_assignment "$principal_id" "Key Vault Secrets User" "$kv_id"
        else
            az keyvault set-policy -n "$KEY_VAULT_NAME" --object-id "$principal_id" --secret-permissions get list -o none
            echo "✓ Key Vault access policy set"
        fi
    fi

    echo "✓ Managed identity configured"
}
