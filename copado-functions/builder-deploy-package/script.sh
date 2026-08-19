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

# Layout deploys are full replaces. AI packages often ship stubs and/or invent
# English layout names (Account-Account Layout) that do not exist in localized orgs.
# Retrieve the live org layout (discovering the real fullName when needed), merge
# package custom fields, and rewrite the package path. If that fails, skip the stub.
#
# v6: top-level helpers + stash stub before retrieve (sf crashes when force-app
# already has Layout filenames with spaces) + Metadata API SOAP fallback.
echo "==> builder_deploy_package layout-merge v6"
# Apex scrapes these lines from the Job Result to rewrite Build package / USM
# so Commit retrieves the live Layout fullName (not the invented English default).
REMAP_FILE="${WORK_DIR}/builder_layout_remap.json"
echo '[]' > "$REMAP_FILE"
MERGE_JS="${WORK_DIR}/_merge_layout.js"

record_layout_remap() {
  local from_name="$1"
  local to_name="$2"
  if [[ -z "$from_name" || -z "$to_name" ]]; then
    return 0
  fi
  echo "BUILDER_LAYOUT_REMAP|${from_name}|${to_name}"
  if command -v jq >/dev/null 2>&1; then
    jq -c --arg f "$from_name" --arg t "$to_name" \
      '. + [{from:$f,to:$t}]' "$REMAP_FILE" > "${REMAP_FILE}.tmp" \
      && mv "${REMAP_FILE}.tmp" "$REMAP_FILE"
  fi
}

# Resolve a live Layout fullName for object prefix (e.g. Account) when package name is wrong.
discover_layout_name() {
  local object_api="$1"
  local preferred="$2"
  local list_json names
  # shellcheck disable=SC2086
  list_json="$(sf org list metadata --metadata-type Layout $TARGET_ARGS --json 2>/dev/null || true)"
  if [[ -z "$list_json" ]]; then
    return 1
  fi
  names="$(jq -r --arg p "${object_api}-" '
    (.result // [])
    | map(.fullName // empty)
    | map(select(startswith($p)))
    | .[]
  ' <<<"$list_json" 2>/dev/null || true)"
  if [[ -z "$names" ]]; then
    return 1
  fi
  echo "Discovered ${object_api} layouts:" >&2
  echo "$names" | sed 's/^/  - /' >&2
  if [[ -n "$preferred" ]] && grep -Fxq "$preferred" <<<"$names"; then
    echo "$preferred"
    return 0
  fi
  local pick
  pick="$(grep -Fv "${object_api}-${object_api} Layout" <<<"$names" | head -n 1 || true)"
  if [[ -z "$pick" ]]; then
    pick="$(head -n 1 <<<"$names")"
  fi
  if [[ -n "$pick" ]]; then
    echo "$pick"
    return 0
  fi
  return 1
}

# Find a retrieved layout file whose basename matches member (spaces-safe).
find_retrieved_layout() {
  local retrieve_dir="$1"
  local member="$2"
  local f base
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    base="${base%.layout-meta.xml}"
    base="${base%.layout}"
    if [[ "$base" == "$member" ]]; then
      echo "$f"
      return 0
    fi
  done < <(find "$retrieve_dir" -type f \( -name '*.layout-meta.xml' -o -name '*.layout' \) -print0 2>/dev/null || true)
  # Fallback: single layout file in the retrieve tree
  f="$(find "$retrieve_dir" -type f \( -name '*.layout-meta.xml' -o -name '*.layout' \) | head -n 1 || true)"
  if [[ -n "$f" && -f "$f" ]]; then
    echo "$f"
    return 0
  fi
  return 1
}

# Retrieve live layout XML and merge package custom fields into it.
# Important: remove the package stub from force-app BEFORE sf retrieve — the CLI
# often throws ERR_INVALID_ARG_TYPE (path undefined) when a Layout file with
# spaces already exists in the project tree.
retrieve_and_merge_layout() {
  local layout_file="$1"
  local member="$2"
  local retrieve_dir="$3"
  local retrieved=""
  local manifest="${retrieve_dir}/package.xml"
  local stub="${retrieve_dir}/package-stub.layout-meta.xml"
  local out_path="force-app/main/default/layouts/${member}.layout-meta.xml"
  local soap_js="${retrieve_dir}/_soap_retrieve_layout.js"

  rm -rf "$retrieve_dir"
  mkdir -p "$retrieve_dir"
  mkdir -p "$(dirname "$out_path")"

  # Stash package stub outside force-app, then remove project copy.
  cp "$layout_file" "$stub"
  rm -f "$layout_file"

  cat > "$manifest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>${member}</members>
        <name>Layout</name>
    </types>
    <version>62.0</version>
</Package>
EOF

  # --- Attempt 1: sf retrieve into an in-project folder (no spaces in path) ---
  local sf_out="force-app/.builder-layout-retrieve"
  rm -rf "$sf_out"
  mkdir -p "$sf_out"
  echo "Retrieving Layout via sf manifest → ${sf_out}: ${member}"
  # shellcheck disable=SC2086
  if sf project retrieve start \
    --manifest "$manifest" \
    --output-dir "$sf_out" \
    --wait 10 \
    $TARGET_ARGS; then
    retrieved="$(find_retrieved_layout "$sf_out" "$member" || true)"
  else
    echo "WARN: sf project retrieve failed for Layout:${member}"
  fi

  # --- Attempt 2: sf retrieve with no --output-dir (default package dir) ---
  if [[ -z "$retrieved" || ! -f "$retrieved" ]]; then
    echo "Retrying sf retrieve into default package directory"
    # shellcheck disable=SC2086
    if sf project retrieve start \
      --manifest "$manifest" \
      --wait 10 \
      $TARGET_ARGS; then
      retrieved="$(find_retrieved_layout "force-app" "$member" || true)"
    else
      echo "WARN: sf default-dir retrieve also failed for Layout:${member}"
    fi
  fi

  # --- Attempt 3: Metadata API SOAP retrieve (sessionId) — bypasses broken sf retrieve ---
  if [[ -z "$retrieved" || ! -f "$retrieved" ]]; then
    if [[ -n "${SF_ACCESS_TOKEN:-}" && -n "${SF_INSTANCE_URL:-}" ]] && command -v node >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
      echo "Falling back to Metadata API SOAP retrieve for Layout:${member}"
      cat > "$soap_js" <<'NODE'
const fs = require('fs');
const https = require('https');
const { URL } = require('url');
const { execFileSync } = require('child_process');

const instanceUrl = process.env.SF_INSTANCE_URL.replace(/\/$/, '');
const token = process.env.SF_ACCESS_TOKEN;
const member = process.argv[2];
const outDir = process.argv[3];
const apiVersion = '62.0';

function soapRequest(path, body) {
  const u = new URL(instanceUrl + path);
  const payload = Buffer.from(body, 'utf8');
  const opts = {
    hostname: u.hostname,
    port: u.port || 443,
    path: u.pathname,
    method: 'POST',
    headers: {
      'Content-Type': 'text/xml; charset=UTF-8',
      'SOAPAction': '""',
      'Content-Length': payload.length
    }
  };
  return new Promise((resolve, reject) => {
    const req = https.request(opts, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error('SOAP HTTP ' + res.statusCode + ': ' + text.slice(0, 400)));
          return;
        }
        resolve(text);
      });
    });
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

function xmlEscape(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function main() {
  const retrieveBody =
    '<?xml version="1.0" encoding="utf-8"?>' +
    '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
    '<soapenv:Header><met:SessionHeader><met:sessionId>' + xmlEscape(token) + '</met:sessionId></met:SessionHeader></soapenv:Header>' +
    '<soapenv:Body><met:retrieve><met:retrieveRequest>' +
    '<met:apiVersion>' + apiVersion + '</met:apiVersion>' +
    '<met:singlePackage>true</met:singlePackage>' +
    '<met:unpackaged><met:types><met:members>' + xmlEscape(member) + '</met:members><met:name>Layout</met:name></met:types>' +
    '<met:version>' + apiVersion + '</met:version></met:unpackaged>' +
    '</met:retrieveRequest></met:retrieve></soapenv:Body></soapenv:Envelope>';

  const startXml = await soapRequest('/services/Soap/m/' + apiVersion, retrieveBody);
  const idMatch = startXml.match(/<id>([^<]+)<\/id>/);
  if (!idMatch) {
    throw new Error('No retrieve id in response: ' + startXml.slice(0, 500));
  }
  const asyncId = idMatch[1];
  let zipB64 = null;
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 2000));
    const statusBody =
      '<?xml version="1.0" encoding="utf-8"?>' +
      '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
      '<soapenv:Header><met:SessionHeader><met:sessionId>' + xmlEscape(token) + '</met:sessionId></met:SessionHeader></soapenv:Header>' +
      '<soapenv:Body><met:checkRetrieveStatus><met:asyncProcessId>' + xmlEscape(asyncId) + '</met:asyncProcessId>' +
      '<met:includeZip>true</met:includeZip></met:checkRetrieveStatus></soapenv:Body></soapenv:Envelope>';
    const statusXml = await soapRequest('/services/Soap/m/' + apiVersion, statusBody);
    if (/<done>true<\/done>/.test(statusXml)) {
      const zipMatch = statusXml.match(/<zipFile>([^<]+)<\/zipFile>/);
      if (!zipMatch) {
        throw new Error('Retrieve done but no zipFile: ' + statusXml.slice(0, 500));
      }
      zipB64 = zipMatch[1];
      break;
    }
  }
  if (!zipB64) {
    throw new Error('Timed out waiting for retrieve ' + asyncId);
  }
  const zipPath = outDir + '/retrieve.zip';
  fs.writeFileSync(zipPath, Buffer.from(zipB64, 'base64'));
  execFileSync('unzip', ['-o', zipPath, '-d', outDir], { stdio: 'inherit' });
  console.log('SOAP retrieve unpacked to ' + outDir);
}

main().catch((e) => {
  console.error(String(e && e.stack ? e.stack : e));
  process.exit(1);
});
NODE
      if node "$soap_js" "$member" "$retrieve_dir"; then
        retrieved="$(find_retrieved_layout "$retrieve_dir" "$member" || true)"
        # MDAPI unzip often uses layouts/Name.layout
        if [[ -z "$retrieved" || ! -f "$retrieved" ]]; then
          retrieved="$(find "$retrieve_dir" -type f \( -name '*.layout' -o -name '*.layout-meta.xml' \) | head -n 1 || true)"
        fi
      else
        echo "WARN: SOAP Metadata retrieve failed for Layout:${member}"
      fi
    else
      echo "WARN: SOAP fallback unavailable (need SF_ACCESS_TOKEN, SF_INSTANCE_URL, node, unzip)"
    fi
  fi

  if [[ -z "$retrieved" || ! -f "$retrieved" ]]; then
    echo "WARN: retrieve produced no layout file for ${member}"
    # Restore stub so caller can skip cleanly
    mkdir -p "$(dirname "$layout_file")"
    cp "$stub" "$layout_file"
    return 1
  fi

  if ! node "$MERGE_JS" "$stub" "$retrieved" "$out_path"; then
    mkdir -p "$(dirname "$layout_file")"
    cp "$stub" "$layout_file"
    return 1
  fi
  if [[ "$out_path" != "$layout_file" && -f "$layout_file" && "$layout_file" != "$out_path" ]]; then
    echo "Rewrote layout path: ${layout_file} -> ${out_path}"
    rm -f "$layout_file"
  fi
  rm -rf "force-app/.builder-layout-retrieve"
  echo "OK: merged into live layout ${member}"
  return 0
}


merge_layouts_from_org() {
  local layout_count
  layout_count="$(find force-app -type f \( -name '*.layout-meta.xml' -o -name '*.layout' \) 2>/dev/null | wc -l | tr -d ' ')"
  echo "Layout files in package: ${layout_count}"
  if [[ "${layout_count}" -lt 1 ]]; then
    return 0
  fi

  if [[ "$CLI" != "sf" ]]; then
    echo "WARN: layout retrieve-merge requires sf CLI; removing stub layouts from deploy set"
    find force-app -type f \( -name '*.layout-meta.xml' -o -name '*.layout' \) -print -delete 2>/dev/null || true
    return 0
  fi

  local have_merger=0
  if command -v node >/dev/null 2>&1; then
    have_merger=1
    cat > "$MERGE_JS" <<'NODE'
const fs = require('fs');
function extractCustomFields(xml) {
  const fields = [];
  const re = /<field>\s*([A-Za-z][A-Za-z0-9_]*__c)\s*<\/field>/gi;
  let m;
  while ((m = re.exec(xml)) !== null) fields.push(m[1]);
  return [...new Set(fields)];
}
function hasField(xml, apiName) {
  return new RegExp('<field>\\s*' + apiName + '\\s*</field>', 'i').test(xml);
}
function itemXml(apiName, required) {
  return (
    '\n            <layoutItems>\n' +
    '                <behavior>' + (required ? 'Required' : 'Edit') + '</behavior>\n' +
    '                <field>' + apiName + '</field>\n' +
    '            </layoutItems>'
  );
}
function insertAfterFirstColumns(xml, snippet) {
  const m = xml.match(/<layoutColumns[^>]*>/i);
  if (!m) return null;
  const at = xml.indexOf(m[0]) + m[0].length;
  return xml.slice(0, at) + snippet + xml.slice(at);
}
function merge(baseXml, fields) {
  let xml = baseXml;
  const missing = fields.filter((f) => !hasField(xml, f));
  if (!missing.length) return xml;
  const snippet = missing.map((f) => itemXml(f, false)).join('');
  return insertAfterFirstColumns(xml, snippet) || xml;
}
function isStub(xml) {
  const items = (xml.match(/<layoutItems>/gi) || []).length;
  return items > 0 && items < 8;
}
const pkg = fs.readFileSync(process.argv[2], 'utf8');
const live = fs.readFileSync(process.argv[3], 'utf8');
const out = process.argv[4];
const fields = extractCustomFields(pkg);
if (isStub(live) && fields.length === 0) {
  console.error('Retrieved layout looks empty; refusing merge');
  process.exit(2);
}
const merged = merge(live, fields);
fs.writeFileSync(out, merged);
const itemCount = (merged.match(/<layoutItems>/gi) || []).length;
console.log('Merged custom fields: ' + (fields.join(', ') || '(none)') + '; layoutItems=' + itemCount);
if (itemCount < 8) {
  console.error('Merged layout still looks like a stub (layoutItems=' + itemCount + ')');
  process.exit(3);
}
NODE
  else
    echo "WARN: node not available for layout XML merge"
  fi

  local layout_file member original_member object_api discover_name retrieve_dir merge_ok final_member
  while IFS= read -r -d '' layout_file; do
    member="$(basename "$layout_file")"
    member="${member%.layout-meta.xml}"
    member="${member%.layout}"
    original_member="$member"
    object_api="${member%%-*}"
    echo "==> Merging layout with org copy: ${member} (object=${object_api})"
    merge_ok=0
    final_member=""
    retrieve_dir="${WORK_DIR}/_layout_retrieve_$$"

    if [[ "$have_merger" -eq 1 ]]; then
      if retrieve_and_merge_layout "$layout_file" "$member" "$retrieve_dir"; then
        merge_ok=1
        final_member="$member"
      else
        echo "WARN: retrieve failed for Layout:${member} — discovering live ${object_api} layouts"
        discover_name="$(discover_layout_name "$object_api" "$member" || true)"
        if [[ -n "$discover_name" ]]; then
          if [[ "$discover_name" != "$member" ]]; then
            echo "==> Retrying merge against discovered layout: ${discover_name}"
          else
            echo "==> Retrying merge with discovered matching name via manifest: ${discover_name}"
          fi
          if retrieve_and_merge_layout "$layout_file" "$discover_name" "$retrieve_dir"; then
            merge_ok=1
            final_member="$discover_name"
          fi
        else
          echo "WARN: could not discover a live ${object_api} layout"
        fi
      fi
    fi

    rm -rf "$retrieve_dir"

    if [[ "$merge_ok" -eq 1 && -n "$final_member" ]]; then
      record_layout_remap "$original_member" "$final_member"
    else
      echo "SKIP: removing stub/wrong layout from deploy set: ${layout_file}"
      echo "BUILDER_LAYOUT_SKIP|${original_member}"
      rm -f "$layout_file"
    fi
  done < <(find force-app -type f \( -name '*.layout-meta.xml' -o -name '*.layout' \) -print0 2>/dev/null || true)
}

merge_layouts_from_org

if [[ -f "$REMAP_FILE" ]]; then
  echo "BUILDER_LAYOUT_REMAP_JSON=$(cat "$REMAP_FILE")"
fi

# If all layouts were skipped, force-app may still have field/profile — continue.
if [[ ! -d force-app ]] || [[ -z "$(find force-app -type f 2>/dev/null | head -n 1)" ]]; then
  echo "ERROR: no metadata files left to deploy after layout preflight"
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
