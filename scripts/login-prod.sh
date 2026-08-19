#!/usr/bin/env bash
# Log in to a production Salesforce org (login.salesforce.com)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export NODE_OPTIONS="--require ${ROOT_DIR}/scripts/node25-polyfill.cjs"

ALIAS="${1:-copado-prod}"

echo "Opening browser to log in to production..."
echo "Alias: ${ALIAS}"
echo "Instance: https://login.salesforce.com"
echo ""

sf org login web \
  --instance-url https://login.salesforce.com \
  --alias "$ALIAS" \
  --set-default \
  --browser chrome

echo ""
echo "Login complete. Run: ./scripts/deploy.sh ${ALIAS}"
