#!/usr/bin/env bash
# Build Copado Builder Version 1 distribution kit:
#   copado-builder-version-1.zip
#
# Contents:
#   README.md, INSTALL.md
#   salesforce/copado-builder-v1-mdapi.zip  (full force-app MDAPI, includes credential shells)
#   copado-functions/                      (Function script + Job Template docs)
#
# Freeze of the current working experience (Build + combined Deploy-Then-Commit).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export NODE_OPTIONS="--require ${ROOT_DIR}/scripts/node25-polyfill.cjs"

DIST_NAME="copado-builder-version-1"
DIST_DIR="${ROOT_DIR}/dist/${DIST_NAME}"
MDAPI_TMP="${ROOT_DIR}/dist/v1-mdapi-build"
OUT_ZIP="${ROOT_DIR}/${DIST_NAME}.zip"
VERSION_DOCS="${ROOT_DIR}/scripts/version-1"

cd "$ROOT_DIR"

echo "==> Cleaning previous Version 1 assembly"
rm -rf "${DIST_DIR}" "${MDAPI_TMP}"
rm -f "${OUT_ZIP}"
mkdir -p "${DIST_DIR}/salesforce" "${DIST_DIR}/copado-functions"

echo "==> Converting force-app → MDAPI (includes Named/External Credential shells for first-time install)"
sf project convert source --root-dir force-app --output-dir "${MDAPI_TMP}"

echo "==> Packaging salesforce/copado-builder-v1-mdapi.zip"
(
  cd "${MDAPI_TMP}"
  zip -r "${DIST_DIR}/salesforce/copado-builder-v1-mdapi.zip" . -x "*.DS_Store"
)

echo "==> Copying Copado Function assets"
cp -R "${ROOT_DIR}/copado-functions/builder-deploy-package" "${DIST_DIR}/copado-functions/"
cp "${ROOT_DIR}/copado-functions/README.md" "${DIST_DIR}/copado-functions/"
cp "${ROOT_DIR}/copado-functions/builder_deploy_then_commit.job-template.md" "${DIST_DIR}/copado-functions/"

echo "==> Copying Version 1 docs"
cp "${VERSION_DOCS}/README.md" "${DIST_DIR}/README.md"
cp "${VERSION_DOCS}/INSTALL.md" "${DIST_DIR}/INSTALL.md"

echo "==> Writing VERSION.txt"
cat > "${DIST_DIR}/VERSION.txt" <<EOF
Copado Builder Version 1
Built: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Experience: Build + combined Deploy-Then-Commit (builder_deploy_then_commit)
Source: force-app + copado-functions (frozen at build time)
EOF

echo "==> Creating ${OUT_ZIP}"
(
  cd "${ROOT_DIR}/dist"
  zip -r "${OUT_ZIP}" "${DIST_NAME}" -x "*.DS_Store"
)

echo "==> Cleaning MDAPI temp"
rm -rf "${MDAPI_TMP}"

echo ""
echo "Created: ${OUT_ZIP}"
echo "Unpacked kit also at: ${DIST_DIR}"
echo "Give installers INSTALL.md inside the zip."
