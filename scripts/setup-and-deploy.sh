#!/usr/bin/env bash
# Login + deploy in one flow. Run this in your Mac terminal.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ALIAS="${1:-copado-prod}"

"${ROOT_DIR}/scripts/login-prod.sh" "$ALIAS"
"${ROOT_DIR}/scripts/deploy.sh" "$ALIAS"
