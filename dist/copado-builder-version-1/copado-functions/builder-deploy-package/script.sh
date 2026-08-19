#!/usr/bin/env bash
# Copado Function: materialize Copado Builder package JSON and deploy to the
# User Story Org Credential (Dev sandbox), so a subsequent commit step can
# retrieve real metadata from the org.
#
# Required Function parameters (map on the Job Step):
#   DataJson   = {$Context.copado__JobExecution__r.copado__DataJson__c}
#   sessionId  = {$Source.Credential.SessionId}
#   endpoint   = {$Source.Credential.EndpointURL}   # base URL (preferred)
#                or {$Source.Credential.Endpoint}   # script strips SOAP path
#
# Prefer EndpointURL. Credential.Endpoint can be a SOAP URL that breaks CLI auth.

set -euo pipefail

echo "==> Copado Builder: deploy package to Dev org"

if [[ -z "${DataJson:-}" ]]; then
  echo "ERROR: DataJson is empty. Pass Job Execution DataJson into this function."
  exit 1
fi

echo "DataJson length: ${#DataJson}"

USER_STORY_ID=$(jq -r '.userStoryId // empty' <<<"$DataJson")
CONTENT_DOCUMENT_ID=$(jq -r '.contentDocumentId // empty' <<<"$DataJson")
ENVIRONMENT_ID=$(jq -r '.environmentId // empty' <<<"$DataJson")
TARGET_USERNAME=$(jq -r '.targetUsername // empty' <<<"$DataJson")
TARGET_ORG_ID=$(jq -r '.targetOrgId // empty' <<<"$DataJson")
HAS_INLINE=$(jq -r 'if .packageJson then "yes" else "no" end' <<<"$DataJson")

# Prefer Copado Dynamic Expression parameters (Function params → env vars).
# Fallbacks cover alternate naming / env injection.
SESSION_ID="${sessionId:-${SessionId:-${SF_ACCESS_TOKEN:-${accessToken:-}}}}"
ENDPOINT="${endpoint:-${Endpoint:-${SF_INSTANCE_URL:-${instanceUrl:-${endPoint:-}}}}}"

echo "userStoryId=$USER_STORY_ID"
echo "contentDocumentId=$CONTENT_DOCUMENT_ID"
echo "environmentId=$ENVIRONMENT_ID"
echo "targetUsername=$TARGET_USERNAME"
echo "hasSessionId=$([[ -n "$SESSION_ID" ]] && echo yes || echo no)"
echo "endpoint=${ENDPOINT:-<empty>}"
echo "inlinePackage=$HAS_INLINE"

WORK_DIR="${PWD}/builder-package"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

PACKAGE_FILE="package.json"
if [[ "$HAS_INLINE" == "yes" ]]; then
  jq -c '.packageJson | if type=="string" then fromjson else . end' <<<"$DataJson" > "$PACKAGE_FILE"
elif [[ -n "$CONTENT_DOCUMENT_ID" ]]; then
  echo "ERROR: contentDocumentId-only retrieval is not configured in this function image."
  echo "Pass packageJson inside DataJson from Copado Builder (packages are kept small)."
  exit 1
else
  echo "ERROR: DataJson must include packageJson (preferred) or a retrievable contentDocumentId."
  exit 1
fi

FILE_COUNT=$(jq '.files | length' "$PACKAGE_FILE")
echo "Package file count: $FILE_COUNT"
if [[ "$FILE_COUNT" -lt 1 ]]; then
  echo "ERROR: package has no files"
  exit 1
fi

# Materialize force-app paths from package JSON
jq -c '.files[]' "$PACKAGE_FILE" | while read -r row; do
  PATH_VAL=$(jq -r '.path' <<<"$row")
  CONTENT_VAL=$(jq -r '.content' <<<"$row")
  if [[ -z "$PATH_VAL" || "$PATH_VAL" == "null" ]]; then
    continue
  fi
  if [[ "$PATH_VAL" != force-app/* ]]; then
    echo "Skipping non force-app path: $PATH_VAL"
    continue
  fi
  if [[ "$PATH_VAL" == *..* ]]; then
    echo "Skipping path traversal: $PATH_VAL"
    continue
  fi
  mkdir -p "$(dirname "$PATH_VAL")"
  printf '%s' "$CONTENT_VAL" > "$PATH_VAL"
  echo "Wrote $PATH_VAL"
done

if [[ ! -d force-app ]]; then
  echo "ERROR: no force-app directory was written"
  exit 1
fi

# Minimal sfdx-project so sf project deploy works
cat > sfdx-project.json <<'EOF'
{
  "packageDirectories": [{ "path": "force-app", "default": true }],
  "sourceApiVersion": "62.0"
}
EOF

# Resolve a Salesforce CLI: prefer `sf`, fall back to `sfdx`.
CLI=""
if command -v sf >/dev/null 2>&1; then
  CLI="sf"
elif command -v sfdx >/dev/null 2>&1; then
  CLI="sfdx"
else
  echo "ERROR: Neither 'sf' nor 'sfdx' is available in this function image."
  echo "Set this Copado Function's Image to a Salesforce CLI image (the same one your"
  echo "org uses for sfdx_commit_1 / sfdx_deploy_1, e.g. a copado-multicloud-dx image)."
  echo "Current PATH: $PATH"
  exit 1
fi
echo "Using CLI: $CLI"

# Normalize Credential.Endpoint → base instance URL only.
# Copado sometimes returns a SOAP path (.../services/Soap/u/67.0/00D...), and
# `sf org login access-token` then builds a broken ...UACservices/oauth2/userinfo URL.
normalize_instance_url() {
  local url="$1"
  if [[ -z "$url" ]]; then
    echo ""
    return
  fi
  if [[ "$url" != http* ]]; then
    url="https://$url"
  fi
  # Keep scheme + host only
  echo "$url" | sed -E 's#(https?://[^/?#]+).*#\1#'
}

if [[ -n "$ENDPOINT" ]]; then
  ENDPOINT="$(normalize_instance_url "$ENDPOINT")"
  echo "Normalized instance URL: $ENDPOINT"
fi

# Authenticate without `sf org login access-token` (that command calls OAuth
# userinfo and fails with Copado session IDs / SOAP-style endpoints).
# Write an auth file + use SF_ACCESS_TOKEN / SF_INSTANCE_URL instead.
TARGET_ARGS=""
if [[ -n "$SESSION_ID" && -n "$ENDPOINT" ]]; then
  echo "Configuring CLI auth from sessionId + instance URL (no access-token login)"
  export SF_ACCESS_TOKEN="$SESSION_ID"
  export SF_INSTANCE_URL="$ENDPOINT"

  AUTH_USER="${TARGET_USERNAME:-builder.target@copado.local}"
  mkdir -p "${HOME}/.sfdx" "${HOME}/.sf"
  jq -n \
    --arg accessToken "$SESSION_ID" \
    --arg instanceUrl "$ENDPOINT" \
    --arg username "$AUTH_USER" \
    '{
      accessToken: $accessToken,
      instanceUrl: $instanceUrl,
      loginUrl: $instanceUrl,
      username: $username,
      isDevHub: false
    }' > "${HOME}/.sfdx/${AUTH_USER}.json"

  # Alias so --target-org is stable across sf / sfdx
  if [[ -f "${HOME}/.sfdx/alias.json" ]]; then
    jq --arg u "$AUTH_USER" '.orgs.builderTarget = $u' \
      "${HOME}/.sfdx/alias.json" > "${HOME}/.sfdx/alias.json.tmp" \
      && mv "${HOME}/.sfdx/alias.json.tmp" "${HOME}/.sfdx/alias.json"
  else
    jq -n --arg u "$AUTH_USER" '{ orgs: { builderTarget: $u } }' \
      > "${HOME}/.sfdx/alias.json"
  fi

  if [[ "$CLI" == "sf" ]]; then
    TARGET_ARGS="--target-org builderTarget"
  else
    TARGET_ARGS="--targetusername builderTarget"
  fi
elif [[ -n "$SESSION_ID" ]]; then
  echo "WARN: sessionId present but endpoint empty; using session as --target-org"
  TARGET_ARGS="--target-org $SESSION_ID"
elif [[ -n "$TARGET_USERNAME" ]]; then
  echo "Targeting org by username from DataJson: $TARGET_USERNAME"
  TARGET_ARGS="--target-org $TARGET_USERNAME"
elif [[ -n "$TARGET_ORG_ID" ]]; then
  echo "Targeting org by Salesforce Org Id from DataJson: $TARGET_ORG_ID"
  TARGET_ARGS="--target-org $TARGET_ORG_ID"
else
  echo "ERROR: No org session available."
  echo "On the Job Step, add Function parameters:"
  echo '  sessionId = {$Source.Credential.SessionId}'
  echo '  endpoint  = {$Source.Credential.EndpointURL}'
  echo "(EndpointURL is the base URL; Endpoint can include a SOAP path that breaks CLI auth.)"
  exit 1
fi

echo "==> Deploying source to Org Credential target ($TARGET_ARGS)"
if [[ "$CLI" == "sf" ]]; then
  # shellcheck disable=SC2086
  sf project deploy start \
    --source-dir force-app \
    --wait 30 \
    --ignore-conflicts \
    $TARGET_ARGS
else
  # shellcheck disable=SC2086
  sfdx force:source:deploy \
    --sourcepath force-app \
    --wait 30 \
    $TARGET_ARGS
fi

echo "==> Deploy succeeded. Commit step can now retrieve metadata from the Dev org via Copado."
