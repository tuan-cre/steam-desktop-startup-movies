#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "=== Rebuilding plugin ==="
npm run build

echo "Done. Run ./deploy.sh from the Millennium repo and restart Steam."
