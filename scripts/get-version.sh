#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

version=""
if command -v git &>/dev/null; then
    version=$(git -C "$ROOT_DIR" describe --tags --dirty --always 2>/dev/null || true)
fi

if [[ -z "$version" ]]; then
    version=$(date +%Y%m%d%H%M%S)
fi

echo "${version//+/-}"
