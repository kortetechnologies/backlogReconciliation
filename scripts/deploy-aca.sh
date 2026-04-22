#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/deploy_helpers.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then
    echo "Usage: $0 <environment>"
    exit 0
fi

ENVIRONMENT="$1"
load_environment_config "$ENVIRONMENT"

check_azure_auth
ensure_resource_group
ensure_acr_registry

VERSION=$("$SCRIPT_DIR/get-version.sh")
IMAGE_TAG="${REGISTRY_NAME}.azurecr.io/${REPOSITORY_NAME}:${VERSION}"

echo ""
echo "=== Deploying ACA Job ${CONTAINER_APP_JOB} (${ENVIRONMENT}) ==="
echo "Version:        $VERSION"
echo "Image:          $IMAGE_TAG"
echo "ACA Env:        $CONTAINER_APPS_ENV"
echo "Resource Group: $RESOURCE_GROUP"
echo "Cron:           $JOB_CRON"
echo ""

require_secrets_from_env
ensure_aca_environment
get_acr_credentials

if az containerapp job show -n "$CONTAINER_APP_JOB" -g "$RESOURCE_GROUP" &>/dev/null; then
    echo "Updating Container Apps job..."
    az containerapp job update \
        -n "$CONTAINER_APP_JOB" \
        -g "$RESOURCE_GROUP" \
        --image "$IMAGE_TAG" \
        --cpu "${JOB_CPU:-0.5}" \
        --memory "${JOB_MEMORY:-1Gi}" \
        -o none

    az containerapp job secret set \
        -n "$CONTAINER_APP_JOB" \
        -g "$RESOURCE_GROUP" \
        --secrets \
            "storage-conn=$AZURE_STORAGE_CONNECTION_STRING" \
            "api-auth-password=$API_AUTH_PASSWORD" \
        -o none

    az containerapp job registry set \
        -n "$CONTAINER_APP_JOB" \
        -g "$RESOURCE_GROUP" \
        --server "${REGISTRY_NAME}.azurecr.io" \
        --username "$ACR_USERNAME" \
        --password "$ACR_PASSWORD" \
        -o none
else
    echo "Creating Container Apps job..."
    az containerapp job create \
        -n "$CONTAINER_APP_JOB" \
        -g "$RESOURCE_GROUP" \
        --environment "$CONTAINER_APPS_ENV" \
        --trigger-type Schedule \
        --cron-expression "$JOB_CRON" \
        --image "$IMAGE_TAG" \
        --cpu "${JOB_CPU:-0.5}" \
        --memory "${JOB_MEMORY:-1Gi}" \
        --registry-server "${REGISTRY_NAME}.azurecr.io" \
        --registry-username "$ACR_USERNAME" \
        --registry-password "$ACR_PASSWORD" \
        --secrets \
            "storage-conn=$AZURE_STORAGE_CONNECTION_STRING" \
            "api-auth-password=$API_AUTH_PASSWORD" \
        --env-vars \
            "AZURE_STORAGE_CONNECTION_STRING=secretref:storage-conn" \
            "API_AUTH_PASSWORD=secretref:api-auth-password" \
            "API_AUTH_USER=${API_AUTH_USER:-brandon-svc}" \
        -o none
fi

setup_managed_identity

if [[ "${START_NOW:-0}" == "1" ]]; then
    echo "Starting job immediately..."
    az containerapp job start -n "$CONTAINER_APP_JOB" -g "$RESOURCE_GROUP" -o none
    echo "✓ Job started"
fi

echo ""
echo "✓ Deployment complete"
echo "To check executions:"
echo "  az containerapp job execution list -g $RESOURCE_GROUP -n $CONTAINER_APP_JOB -o table"
