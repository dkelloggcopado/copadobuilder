#!/usr/bin/env bash
# Deploy Copado Builder to a Salesforce org.
# Usage: ./scripts/deploy.sh [org-alias]
set -euo pipefail

ORG_ALIAS="${1:-copado-prod}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export NODE_OPTIONS="--require ${ROOT_DIR}/scripts/node25-polyfill.cjs"

echo "==> Deploying Copado Builder to org: ${ORG_ALIAS}"
cd "$ROOT_DIR"

sf project deploy start \
  --source-dir force-app \
  --target-org "$ORG_ALIAS" \
  --wait 15 \
  --test-level RunSpecifiedTests \
  --tests CopadoBuilderControllerTest

echo "==> Assigning permission set"
sf org assign permset \
  --name Copado_Builder_User \
  --target-org "$ORG_ALIAS"

echo ""
echo "Deploy complete."
echo ""
echo "POST-DEPLOY (one-time manual steps):"
echo "  1. Setup → Named Credentials → External Credentials → Copado AI API Key"
echo "     → Principals → Default → add your Copado AI Personal Access Key as secret"
echo "  2. Setup → Custom Metadata Types → Copado Builder Settings → Manage Records → Default"
echo "     → set Organization Id, optionally Workspace Id"
echo "     → uncheck Use Mock API when ready for live Copado AI"
echo "  3. App Launcher → Copado Builder"
