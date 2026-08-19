#!/usr/bin/env bash
# Assemble dist/copado-builder-install.zip for sharing with other installers.
# Fresh install = ONE Salesforce MDAPI zip. Copado Function files stay separate
# (not Salesforce metadata).
#
# Run after:
#   ./scripts/build-mdapi-zip.sh --with-credentials
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KIT_DIR="${ROOT_DIR}/dist/copado-builder-install"
OUT_ZIP="${ROOT_DIR}/dist/copado-builder-install.zip"

need() {
  local f="$1"
  if [[ ! -f "${ROOT_DIR}/${f}" ]]; then
    echo "Missing ${f}. Build packages first." >&2
    echo "  ./scripts/build-mdapi-zip.sh --with-credentials" >&2
    exit 1
  fi
}

need INSTALL.md
need README.md
need copado-builder-mdapi.zip
need copado-functions/builder-deploy-package/script.sh

rm -rf "${KIT_DIR}"
mkdir -p "${KIT_DIR}/salesforce" "${KIT_DIR}/copado-functions"

cp "${ROOT_DIR}/INSTALL.md" "${ROOT_DIR}/README.md" "${KIT_DIR}/"
cp "${ROOT_DIR}/copado-builder-mdapi.zip" "${KIT_DIR}/salesforce/"

cat > "${KIT_DIR}/salesforce/README.txt" <<'EOF'
Salesforce deploy (fresh install)
=================================

Deploy ONLY this file:

  copado-builder-mdapi.zip

It includes objects, Apex, LWC, app, Global Action, Remote Site, Named/External
Credential shells, permission set, and default settings.

Incremental update zips (updates-1-schema, updates-2-code, etc.) are NOT in this
kit. Maintainers build them from the Copado Builder source repo when upgrading
an org that already has Builder installed — see INSTALL.md "Updating an existing
install".
EOF

cp -R "${ROOT_DIR}/copado-functions/builder-deploy-package" "${KIT_DIR}/copado-functions/"
cp "${ROOT_DIR}/copado-functions/README.md" "${KIT_DIR}/copado-functions/"

cat > "${KIT_DIR}/START-HERE.txt" <<'EOF'
Copado Builder — install kit
============================

1. Open INSTALL.md and follow the steps in order.
2. Deploy ONE Salesforce zip: salesforce/copado-builder-mdapi.zip
3. Copado Function files are in copado-functions/ (manual setup in Copado —
   not a Salesforce zip).
4. Finish every manual step in INSTALL.md (API key, settings, Function,
   Job Templates, Publisher Layout, Copado AI User Level).
EOF

rm -f "${OUT_ZIP}"
(
  cd "${ROOT_DIR}/dist"
  zip -r copado-builder-install.zip copado-builder-install -x "*.DS_Store"
)

echo "Created: ${OUT_ZIP}"
echo "Give recipients this zip and tell them to open INSTALL.md."
