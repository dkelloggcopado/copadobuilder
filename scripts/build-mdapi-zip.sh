#!/usr/bin/env bash
# Build Metadata API deploy zip (package.xml at zip root).
# By default excludes Named/External Credentials so redeploy doesn't wipe API keys.
# Pass --with-credentials to include them (first-time setup only).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export NODE_OPTIONS="--require ${ROOT_DIR}/scripts/node25-polyfill.cjs"

INCLUDE_CREDS=false
if [[ "${1:-}" == "--with-credentials" ]]; then
  INCLUDE_CREDS=true
fi

cd "$ROOT_DIR"
rm -rf mdapi-deploy
sf project convert source --root-dir force-app --output-dir mdapi-deploy

if [[ "$INCLUDE_CREDS" != "true" ]]; then
  rm -rf mdapi-deploy/namedCredentials mdapi-deploy/externalCredentials
  # Strip credential types from package.xml (portable enough for BSD/macOS sed)
  python3 - <<'PY'
from pathlib import Path
import re
p = Path("mdapi-deploy/package.xml")
text = p.read_text()
text = re.sub(
    r"\s*<types>\s*<members>Copado_AI_API_Key</members>\s*<name>ExternalCredential</name>\s*</types>",
    "",
    text,
)
text = re.sub(
    r"\s*<types>\s*<members>Copado_AI_API</members>\s*<name>NamedCredential</name>\s*</types>",
    "",
    text,
)
p.write_text(text)
print("Excluded Named/External Credentials from zip (preserves org API key).")
PY
fi

cd mdapi-deploy
rm -f ../copado-builder-mdapi.zip
zip -r ../copado-builder-mdapi.zip . -x "*.DS_Store"

echo "Created: ${ROOT_DIR}/copado-builder-mdapi.zip"
echo "Upload this zip to Copado/Salesforce MDAPI deploy (package.xml is at zip root)."
