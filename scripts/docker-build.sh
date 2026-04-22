#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/deploy_helpers.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [environment]"
    exit 0
fi

load_environment_config "${1:-}"

[[ -n "${REPOSITORY_NAME:-}" ]] || { echo "REPOSITORY_NAME not set"; exit 1; }

VERSION=$("$SCRIPT_DIR/get-version.sh")
IMAGE_TAG="${REPOSITORY_NAME}:${VERSION}"

docker build --platform linux/amd64 -t "$IMAGE_TAG" "$ROOT_DIR"

ARCH=$(docker inspect "$IMAGE_TAG" --format '{{.Architecture}}')
[[ "$ARCH" == "amd64" ]] || { echo "Error: Expected amd64 architecture, got $ARCH"; exit 1; }

echo "$IMAGE_TAG"

if [[ "${BUILD_ALL:-0}" != "1" ]]; then
    echo "Next: ./scripts/docker-push.sh ${1:-}" >&2
fi
