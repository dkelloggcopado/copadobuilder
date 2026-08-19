#!/usr/bin/env bash
# Build incremental Workbench zips:
#   copado-builder-updates-1-schema.zip  (CMD field + layout)
#   copado-builder-updates-2-code.zip    (Apex + LWC + permission set)
#
# Does NOT include Copado_Builder_Settings.Default custom metadata so a redeploy
# cannot overwrite live Use Mock API / org Id settings. Set
# Deploy Then Commit Job Template manually after schema deploy (or via Setup).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export NODE_OPTIONS="--require ${ROOT_DIR}/scripts/node25-polyfill.cjs"

cd "$ROOT_DIR"
rm -rf mdapi-deploy updates-schema updates-code
sf project convert source --root-dir force-app --output-dir mdapi-deploy

# --- Schema zip (new session fields + CMD layout; no Default CMD record) ---
# Workbench is unreliable with directory-style CustomField members alone.
# Package new fields inside a minimal AI_Builder_Session__c.object (additive merge).
mkdir -p updates-schema/objects updates-schema/layouts
cp mdapi-deploy/objects/Copado_Builder_Settings__mdt.object updates-schema/objects/
cp "mdapi-deploy/layouts/Copado_Builder_Settings__mdt-Copado Builder Settings Layout.layout" \
  updates-schema/layouts/

python3 - <<'PY'
from pathlib import Path
import re

def field_as_object_fields(path: Path) -> str:
    xml = path.read_text()
    body = re.sub(r'<\?xml[^?]*\?>\s*', '', xml).strip()
    body = body.replace('<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">', '<fields>')
    body = body.replace('</CustomField>', '</fields>')
    return body

def write_object(
    label: str,
    plural: str,
    field_paths: list[Path],
    out: Path,
    *,
    name_field_xml: str,
    sharing_model: str = 'ReadWrite',
    extra_header: str = '',
):
    fields = [field_as_object_fields(p) for p in field_paths]
    out.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">\n'
        '    <deploymentStatus>Deployed</deploymentStatus>\n'
        + extra_header
        + f'    <label>{label}</label>\n'
        + name_field_xml
        + f'    <pluralLabel>{plural}</pluralLabel>\n'
        f'    <sharingModel>{sharing_model}</sharingModel>\n'
        + '\n'.join(fields)
        + '\n</CustomObject>\n'
    )
    print(f'Wrote {out}')

session_name = (
    '    <nameField>\n'
    '        <label>Session Name</label>\n'
    '        <type>Text</type>\n'
    '    </nameField>\n'
)
action_name = (
    '    <nameField>\n'
    '        <displayFormat>ACT-{0000}</displayFormat>\n'
    '        <label>Action Number</label>\n'
    '        <type>AutoNumber</type>\n'
    '    </nameField>\n'
)

session_fields = Path('force-app/main/default/objects/AI_Builder_Session__c/fields')
write_object(
    'AI Builder Session',
    'AI Builder Sessions',
    [
        session_fields / 'Org_Context_Status__c.field-meta.xml',
        session_fields / 'Org_Credential_Id__c.field-meta.xml',
        session_fields / 'Org_Intelligence_Integration_Id__c.field-meta.xml',
        session_fields / 'Status__c.field-meta.xml',
        session_fields / 'Last_Deploy_Job_Id__c.field-meta.xml',
        session_fields / 'Last_Commit_Job_Id__c.field-meta.xml',
        session_fields / 'Last_Job_Action__c.field-meta.xml',
        session_fields / 'Last_Promotion_Id__c.field-meta.xml',
    ],
    Path('updates-schema/objects/AI_Builder_Session__c.object'),
    name_field_xml=session_name,
    sharing_model='ReadWrite',
    extra_header=(
        '    <description>Tracks a Copado Builder chat session from idea through deploy.</description>\n'
        '    <enableActivities>true</enableActivities>\n'
        '    <enableReports>true</enableReports>\n'
        '    <enableSearch>true</enableSearch>\n'
    ),
)

action_fields = Path('force-app/main/default/objects/AI_Builder_Action__c/fields')
write_object(
    'AI Builder Action',
    'AI Builder Actions',
    [action_fields / 'Action_Type__c.field-meta.xml'],
    Path('updates-schema/objects/AI_Builder_Action__c.object'),
    name_field_xml=action_name,
    sharing_model='ControlledByParent',
    extra_header=(
        '    <description>Logs every external API call and builder action.</description>\n'
        '    <enableReports>true</enableReports>\n'
        '    <enableSearch>true</enableSearch>\n'
    ),
)

pref_fields = Path('force-app/main/default/objects/Copado_Builder_User_Preference__c/fields')
write_object(
    'Copado Builder User Preference',
    'Copado Builder User Preferences',
    [
        pref_fields / 'Environment_Id__c.field-meta.xml',
        pref_fields / 'External_Key__c.field-meta.xml',
        pref_fields / 'Project_Id__c.field-meta.xml',
    ],
    Path('updates-schema/objects/Copado_Builder_User_Preference__c.object'),
    name_field_xml=(
        '    <nameField>\n'
        '        <displayFormat>PREF-{0000}</displayFormat>\n'
        '        <label>Preference Number</label>\n'
        '        <type>AutoNumber</type>\n'
        '    </nameField>\n'
    ),
    sharing_model='Private',
    extra_header=(
        '    <description>Per-user Copado Builder defaults (project, Dev org, integration).</description>\n'
        '    <enableReports>false</enableReports>\n'
        '    <enableSearch>false</enableSearch>\n'
    ),
)

# Hierarchy Custom Setting: prefer converted MDAPI object (customSettingsType=Hierarchy).
auth_src = Path('mdapi-deploy/objects/Copado_Builder_Auth__c.object')
auth_out = Path('updates-schema/objects/Copado_Builder_Auth__c.object')
if auth_src.exists():
    auth_out.write_text(auth_src.read_text())
    print(f'Copied {auth_out}')
else:
    # Fallback: build from source field meta
    auth_fields = Path('force-app/main/default/objects/Copado_Builder_Auth__c/fields')
    fields = [field_as_object_fields(auth_fields / 'Copado_AI_PAT__c.field-meta.xml')]
    auth_out.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">\n'
        '    <customSettingsType>Hierarchy</customSettingsType>\n'
        '    <description>Per-user Copado AI Personal Access Token for Copado Builder.</description>\n'
        '    <label>Copado Builder Auth</label>\n'
        '    <visibility>Public</visibility>\n'
        + '\n'.join(fields)
        + '\n</CustomObject>\n'
    )
    print(f'Wrote {auth_out} (fallback)')

# Private Long Text PAT store (preferred over Hierarchy CS 255-char limit)
secret_fields = Path('force-app/main/default/objects/Copado_Builder_User_Secret__c/fields')
write_object(
    'Copado Builder User Secret',
    'Copado Builder User Secrets',
    [
        secret_fields / 'External_Key__c.field-meta.xml',
        secret_fields / 'Copado_AI_PAT__c.field-meta.xml',
    ],
    Path('updates-schema/objects/Copado_Builder_User_Secret__c.object'),
    name_field_xml=(
        '    <nameField>\n'
        '        <displayFormat>SEC-{0000}</displayFormat>\n'
        '        <label>Secret Number</label>\n'
        '        <type>AutoNumber</type>\n'
        '    </nameField>\n'
    ),
    sharing_model='Private',
    extra_header=(
        '    <description>Per-user Copado AI secrets for Copado Builder (PAT).</description>\n'
        '    <enableReports>false</enableReports>\n'
        '    <enableSearch>false</enableSearch>\n'
    ),
)
PY

# External Credential (strip shared AuthHeaders — per-user PAT is Apex-owned)
mkdir -p updates-schema/externalCredentials
if [[ -f mdapi-deploy/externalCredentials/Copado_AI_API_Key.externalCredential ]]; then
  cp mdapi-deploy/externalCredentials/Copado_AI_API_Key.externalCredential \
    updates-schema/externalCredentials/
fi

cat > updates-schema/package.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>AI_Builder_Action__c</members>
        <members>AI_Builder_Session__c</members>
        <members>Copado_Builder_User_Preference__c</members>
        <members>Copado_Builder_User_Secret__c</members>
        <members>Copado_Builder_Auth__c</members>
        <members>Copado_Builder_Settings__mdt</members>
        <name>CustomObject</name>
    </types>
    <types>
        <members>Copado_Builder_Settings__mdt-Copado Builder Settings Layout</members>
        <name>Layout</name>
    </types>
    <types>
        <members>Copado_AI_API_Key</members>
        <name>ExternalCredential</name>
    </types>
    <version>62.0</version>
</Package>
EOF

# --- Code zip ---
mkdir -p updates-code/classes updates-code/lwc updates-code/permissionsets updates-code/applications
cp mdapi-deploy/classes/CopadoAiApiService.cls \
  mdapi-deploy/classes/CopadoAiApiService.cls-meta.xml \
  mdapi-deploy/classes/CopadoBuilderController.cls \
  mdapi-deploy/classes/CopadoBuilderController.cls-meta.xml \
  mdapi-deploy/classes/CopadoBuilderControllerTest.cls \
  mdapi-deploy/classes/CopadoBuilderControllerTest.cls-meta.xml \
  mdapi-deploy/classes/CopadoDevopsService.cls \
  mdapi-deploy/classes/CopadoDevopsService.cls-meta.xml \
  mdapi-deploy/classes/CopadoDevopsServiceTest.cls \
  mdapi-deploy/classes/CopadoDevopsServiceTest.cls-meta.xml \
  mdapi-deploy/classes/CopadoCommitLinkSchedulable.cls \
  mdapi-deploy/classes/CopadoCommitLinkSchedulable.cls-meta.xml \
  mdapi-deploy/classes/CopadoValidateQueueable.cls \
  mdapi-deploy/classes/CopadoValidateQueueable.cls-meta.xml \
  updates-code/classes/
cp -R mdapi-deploy/lwc/copadoBuilderChat updates-code/lwc/
cp mdapi-deploy/permissionsets/Copado_Builder_User.permissionset updates-code/permissionsets/
# App without utilityBar — clears any prior auto-assigned utility panel.
cp mdapi-deploy/applications/Copado_Builder.app updates-code/applications/

cat > updates-code/package.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>CopadoAiApiService</members>
        <members>CopadoBuilderController</members>
        <members>CopadoBuilderControllerTest</members>
        <members>CopadoCommitLinkSchedulable</members>
        <members>CopadoDevopsService</members>
        <members>CopadoDevopsServiceTest</members>
        <members>CopadoValidateQueueable</members>
        <name>ApexClass</name>
    </types>
    <types>
        <members>copadoBuilderChat</members>
        <name>LightningComponentBundle</name>
    </types>
    <types>
        <members>Copado_Builder_User</members>
        <name>PermissionSet</name>
    </types>
    <types>
        <members>Copado_Builder</members>
        <name>CustomApplication</name>
    </types>
    <version>62.0</version>
</Package>
EOF

# --- Utility Bar flexipage only (NOT wired to the app; prefer Global Action) ---
mkdir -p updates-utility/flexipages
cp mdapi-deploy/flexipages/Copado_Builder_Utility_Bar.flexipage updates-utility/flexipages/
cat > updates-utility/package.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>Copado_Builder_Utility_Bar</members>
        <name>FlexiPage</name>
    </types>
    <version>62.0</version>
</Package>
EOF
cat > updates-utility/README.md <<'EOF'
# Copado Builder Utility Bar (optional, not auto-assigned)

This zip only deploys the Utility Bar FlexiPage. It does **not** attach it to the
Copado Builder app. Prefer the **Global Action** (`updates-4`) for access from any page.

To use manually: App Manager → Edit an app → Utility Items → add Copado Builder.
EOF

# --- Remove Utility Bar zip (destructive) ---
rm -rf remove-utility-bar-pkg
mkdir -p remove-utility-bar-pkg/applications
cp "${ROOT_DIR}/scripts/remove-utility-bar/package.xml" remove-utility-bar-pkg/
cp "${ROOT_DIR}/scripts/remove-utility-bar/destructiveChanges.xml" remove-utility-bar-pkg/
cp "${ROOT_DIR}/scripts/remove-utility-bar/applications/Copado_Builder.app" remove-utility-bar-pkg/applications/
cp "${ROOT_DIR}/scripts/remove-utility-bar/README.md" remove-utility-bar-pkg/

rm -f copado-builder-updates-1-schema.zip \
  copado-builder-updates-2-code.zip \
  copado-builder-updates-3-utility-bar.zip \
  copado-builder-updates-4-global-action.zip \
  copado-builder-remove-utility-bar.zip \
  copado-builder-remove-global-action.zip

# --- Global Action zip (Aura host + Quick Action; no Copado managed package changes) ---
mkdir -p updates-global-action/aura updates-global-action/quickActions
cp -R mdapi-deploy/aura/copadoBuilderGlobalAction updates-global-action/aura/
cp mdapi-deploy/quickActions/Copado_Builder.quickAction updates-global-action/quickActions/
cp "${ROOT_DIR}/scripts/global-action/README.md" updates-global-action/
cat > updates-global-action/package.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>copadoBuilderGlobalAction</members>
        <name>AuraDefinitionBundle</name>
    </types>
    <types>
        <members>Copado_Builder</members>
        <name>QuickAction</name>
    </types>
    <version>62.0</version>
</Package>
EOF

rm -rf remove-global-action-pkg
mkdir -p remove-global-action-pkg
cp "${ROOT_DIR}/scripts/remove-global-action/package.xml" remove-global-action-pkg/
cp "${ROOT_DIR}/scripts/remove-global-action/destructiveChanges.xml" remove-global-action-pkg/
cp "${ROOT_DIR}/scripts/remove-global-action/README.md" remove-global-action-pkg/

(cd updates-schema && zip -r ../copado-builder-updates-1-schema.zip . -x "*.DS_Store")
(cd updates-code && zip -r ../copado-builder-updates-2-code.zip . -x "*.DS_Store")
(cd updates-utility && zip -r ../copado-builder-updates-3-utility-bar.zip . -x "*.DS_Store")
(cd remove-utility-bar-pkg && zip -r ../copado-builder-remove-utility-bar.zip . -x "*.DS_Store")
(cd updates-global-action && zip -r ../copado-builder-updates-4-global-action.zip . -x "*.DS_Store")
(cd remove-global-action-pkg && zip -r ../copado-builder-remove-global-action.zip . -x "*.DS_Store")

echo "Created: ${ROOT_DIR}/copado-builder-updates-1-schema.zip"
echo "Created: ${ROOT_DIR}/copado-builder-updates-2-code.zip"
echo "Created: ${ROOT_DIR}/copado-builder-updates-3-utility-bar.zip"
echo "Created: ${ROOT_DIR}/copado-builder-updates-4-global-action.zip"
echo "Created: ${ROOT_DIR}/copado-builder-remove-utility-bar.zip  (destructive rollback)"
echo "Created: ${ROOT_DIR}/copado-builder-remove-global-action.zip  (destructive rollback)"
cp "${ROOT_DIR}/INSTALL.md" "${ROOT_DIR}/INSTALL.md" 2>/dev/null || true
echo ""
echo "Install guide: ${ROOT_DIR}/INSTALL.md"
echo "Upload order (updates): schema → code → optional utility-bar → global-action."
echo "Fresh org: also build/deploy copado-builder-mdapi.zip first (see INSTALL.md)."
echo "Global Action also needs Publisher Layout assignment (see updates-4 README)."
echo "Install Function/template from copado-functions/ (not in these zips)."
echo "To remove Utility Bar only: deploy copado-builder-remove-utility-bar.zip with destructive changes allowed."
echo "To remove Global Action only: deploy copado-builder-remove-global-action.zip with destructive changes allowed."
