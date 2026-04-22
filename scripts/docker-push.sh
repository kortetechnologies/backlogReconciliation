#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/deploy_helpers.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [environment]"
    exit 0
fi

load_environment_config "${1:-}"

[[ -n "${REPOSITORY_NAME:-}" ]] || { echo "REPOSITORY_NAME not set"; exit 1; }
[[ -n "${REGISTRY_NAME:-}" ]]   || { echo "REGISTRY_NAME not set"; exit 1; }

VERSION=$("$SCRIPT_DIR/get-version.sh")
LOCAL_TAG="${REPOSITORY_NAME}:${VERSION}"
REMOTE_TAG="${REGISTRY_NAME}.azurecr.io/${REPOSITORY_NAME}:${VERSION}"

docker image inspect "$LOCAL_TAG" &>/dev/null || {
    echo "Local image $LOCAL_TAG not found. Run docker-build.sh first."
    exit 1
}

az acr login --name "$REGISTRY_NAME"
docker tag "$LOCAL_TAG" "$REMOTE_TAG"
docker push "$REMOTE_TAG"

echo "✓ Pushed $REMOTE_TAG"
echo "Next: ./scripts/deploy-aca.sh ${ENVIRONMENT:-production}" >&2
