# Copado Builder Version 1 — Installation Guide

Follow these steps **in order** on a Salesforce org that already has **Copado CI/CD** installed.  
This kit installs the working Version 1 experience: **Build** generates metadata; **Commit** runs Job Template `builder_deploy_then_commit` (deploy AI package into Dev, then OOTB Copado commit `sfdx_commit_1`).

---

## Checklist overview

- [ ] 1. Prerequisites
- [ ] 2. Deploy Salesforce metadata (`copado-builder-v1-mdapi.zip`)
- [ ] 3. Assign permission set
- [ ] 4. Add Copado AI API key (secret)
- [ ] 5. Configure Copado Builder Settings (Custom Metadata)
- [ ] 6. Install Copado Function `builder_deploy_package`
- [ ] 7. Install Job Template `builder_deploy_then_commit`
- [ ] 8. Add Global Action to Publisher Layout (recommended)
- [ ] 9. Open Copado Builder
- [ ] 10. Smoke test (mock mode)
- [ ] 11. Enable live Copado AI + Org Intelligence
- [ ] 12. End-to-end live test (Build → Commit)

---

## 1. Prerequisites

Confirm before deploying:

| Requirement | How to check |
|-------------|--------------|
| Copado CI/CD (Deployer) installed | App Launcher → Copado apps / User Story object exists |
| Copado Functions enabled | You can create Functions and Job Templates in Copado |
| Copado Job Engine permission | Your user can start Job Executions |
| Validated Dev Org Credential | Org Credential **Validated Status = OK** (not Production) |
| Copado Project + pipeline | Project includes that Dev environment |
| OOTB commit template available | Job Template API name `sfdx_commit_1` (or note your org’s commit template API name) |
| Copado AI access | You have a Copado AI **Organization Id** and **Personal Access Key** |

API version of this package: **62.0**.

---

## 2. Deploy Salesforce metadata

Use the zip at:

`salesforce/copado-builder-v1-mdapi.zip`

The zip has **`package.xml` at the root** (required for Metadata API deploy).

### Option A — Workbench

1. Go to [workbench.developerforce.com](https://workbench.developerforce.com) (or your preferred Workbench).
2. Log in to the target org.
3. **migration** → **Deploy**.
4. Choose `copado-builder-v1-mdapi.zip`.
5. Check **Single Package**.
6. Deploy (Apex tests optional for first install; if required, run `CopadoBuilderControllerTest`, `CopadoDevopsServiceTest`).

### Option B — Salesforce CLI

```bash
# Unzip the kit, then:
mkdir -p /tmp/cb-v1 && unzip -q salesforce/copado-builder-v1-mdapi.zip -d /tmp/cb-v1
sf project deploy start --metadata-dir /tmp/cb-v1 --target-org YOUR_ORG_ALIAS --wait 30
```

### Option C — Copado / other MDAPI upload

Upload `copado-builder-v1-mdapi.zip` and run a standard Metadata API deploy. Ensure the tool treats the zip as a **single package** (manifest at root).

### What this deploy includes

- Custom objects: `AI_Builder_Session__c`, `AI_Builder_Message__c`, `AI_Builder_Action__c`, `Copado_Builder_User_Preference__c`
- Custom metadata type + **Default** record: `Copado_Builder_Settings__mdt`
- Apex: Builder controller, AI API, DevOps service, commit-link schedulable, tests
- LWC `copadoBuilderChat`, Aura global action host, Quick Action **Copado Builder**
- App, tab, flexipages (app page + optional utility bar page)
- Remote Site, Named Credential, External Credential shells (**no API key secret**)
- Permission set `Copado_Builder_User`

---

## 3. Assign permission set

1. **Setup** → **Permission Sets** → **Copado Builder User**.
2. **Manage Assignments** → add every user who should use Builder.
3. Also ensure those users have Copado permissions needed to create User Stories and run Job Templates (including **Copado Job Engine** where required).

CLI:

```bash
sf org assign permset --name Copado_Builder_User --target-org YOUR_ORG_ALIAS
```

---

## 4. Add Copado AI API key (manual — secrets cannot be in the zip)

Redeploying External Credentials later can **clear** secrets. Re-do this step after any credential redeploy.

1. **Setup** → **Named Credentials** → **External Credentials** tab.
2. Open **Copado AI API Key** (`Copado_AI_API_Key`).
3. Under **Principals**, open **Principal** → **Edit**.
4. In **Authentication Parameters**, add or edit:

| Field | Value |
|-------|-------|
| **Name** | `ApiKey` (exact spelling) |
| **Value** | Your Copado AI **Personal Access Key** |

5. Confirm custom headers on the External Credential include:

| Header | Value |
|--------|-------|
| `Api-Key` | `{!$Credential.Copado_AI_API_Key.ApiKey}` |
| `X-Authorization` | `{!$Credential.Copado_AI_API_Key.ApiKey}` |

6. Save.

7. Confirm Named Credential **Copado AI API** (`Copado_AI_API`) points at your region base URL (see region table in step 5) and uses this External Credential.

---

## 5. Configure Copado Builder Settings (Custom Metadata)

1. **Setup** → **Custom Metadata Types**.
2. **Copado Builder Settings** → **Manage Records** → **Default**.
3. **Edit** and set:

| Field | Recommended value |
|-------|-------------------|
| **Organization Id** | Your Copado AI organization ID (replace any sample value from the package) |
| **Base Url** | Region URL from the table below |
| **Workspace Id** | Leave blank (Builder can create workspaces per session) |
| **Use Mock API** | **Checked** for first smoke test; **unchecked** for live Copado AI |
| **Commit Job Template** | `sfdx_commit_1` (OOTB; used inside the combined template) |
| **Deploy Job Template** | `sfdx_deploy_1` (optional / legacy; Version 1 Commit uses Deploy-Then-Commit) |
| **Deploy Then Commit Job Template** | `builder_deploy_then_commit` (**required** for live Commit) |
| **Default Dev Environment Id** | Leave blank — users pick Dev in the UI |
| **Actions Webhook Path** | Leave blank unless you start jobs via REST instead of `CreateExecution` |

### Region Base URLs

| Region | Base Url |
|--------|----------|
| US | `https://copadogpt-api.robotic.copado.com` |
| EU | `https://copadogpt-api.eu-robotic.copado.com` |
| Australia | `https://copadogpt-api.au-robotic.copado.com` |
| Singapore | `https://copadogpt-api.sg-robotic.copado.com` |

If you change Base Url, update the Named Credential URL to match.

---

## 6. Install Copado Function `builder_deploy_package`

Copado Functions are **not** in the Salesforce zip. Use files under `copado-functions/builder-deploy-package/` in this kit.

### 6.1 Create the Function

1. In Copado, create a new **Function**.
2. Set:
   - **API Name:** `builder_deploy_package` (exact)
   - **Timeout:** 60 minutes
   - **Image:** Must include Salesforce CLI (`sf` or `sfdx`) **and** `jq`.  
     **Do not** use `copado-function-core:v1` alone — it typically lacks `sf` and fails with `sf: command not found`.  
     Open your org’s OOTB `sfdx_commit_1` (or `sfdx_deploy_1`) Function → **Configuration** → copy its **Image Name** (often a `copado-multicloud-dx` style image).
3. Paste the contents of `copado-functions/builder-deploy-package/script.sh` as the Function script.
4. Save / publish.

### 6.2 Function parameters

Add these parameters on the **Function** record **and** again on the **Job Step** (step 7):

| Parameter | Dynamic Expression |
|-----------|-------------------|
| **DataJson** | `{$Context.copado__JobExecution__r.copado__DataJson__c}` |
| **sessionId** | `{$Source.Credential.SessionId}` |
| **endpoint** | `{$Source.Credential.EndpointURL}` (preferred) or `{$Source.Credential.Endpoint}` |

Prefer **EndpointURL** (instance base URL). A SOAP-style `Endpoint` path can break `sf` auth. The script also strips path suffixes as a safety net.

---

## 7. Install Job Template `builder_deploy_then_commit`

1. In Copado, create a **Job Template**:
   - **Name:** `builder deploy then commit` (spaces are fine)
   - **Preferred API / Developer Name:** `builder_deploy_then_commit`
2. **Step 1 — Function:** `builder_deploy_package`
   - Map **DataJson**, **sessionId**, **endpoint** as in step 6.2
   - This step deploys the AI package into the **Dev** org only (no Git)
3. **Step 2 — Commit:** OOTB template **`sfdx_commit_1`** (or your org’s standard commit template)
   - Depends on Step 1 succeeding
   - Retrieves from Dev and commits to the User Story feature branch / User Story Commit
4. Save the template. Confirm it shows **2 steps**.
5. Return to **Copado Builder Settings → Default** and set **Deploy Then Commit Job Template** to:
   - `builder_deploy_then_commit`, or
   - the exact Job Template **Name**, or
   - the Job Template Salesforce Id / API name as shown in Copado

### How Builder starts the job

Builder uses Copado Apex `copado.CreateExecution` with:

- `parentId` = User Story Commit (preferred) or User Story
- `sourceId` = Dev Environment
- `pipelineId` when available
- `dataJson` = package + commit selections
- `runAfterInstantiation = true`

Your user needs permission to run the Job Engine. If CreateExecution is unavailable, Builder may insert a Job Execution that still needs **Start** in the UI.

---

## 8. Global Action on Publisher Layout (recommended)

The package includes Global Action **Copado Builder** (Aura host wrapping the chat LWC). Until it is on a Publisher Layout, it will not appear in the Lightning **+** menu.

1. **Setup** → **Publisher Layouts** (or Global Actions → Publisher Layouts).
2. Edit the layout your users use (often **Global Layout**).
3. In **Salesforce Mobile and Lightning Experience Actions**, add **Copado Builder**.
4. Save.

Users can also open **App Launcher → Copado Builder** without the Global Action.

---

## 9. Open Copado Builder

1. App Launcher → **Copado Builder**, **or** Lightning header **+** → **Copado Builder**.
2. You should see chat, Status panel (Project, Environment, score), and actions: Improve Story, Create Story, Build, Commit.

---

## 10. Smoke test (mock mode)

With **Use Mock API = true**:

1. Start a chat and describe a small change (e.g. a custom field on Account).
2. Use **Improve Story** if prompted; confirm Story Score / Missing Info update from chat content.
3. Select a **Copado Project** in the Status panel.
4. Click **Create Story** (mock may create/link a stub depending on org mode).
5. Confirm the UI does not error and messages persist if you refresh the session.

Mock mode does **not** call live Copado AI or start real deploy/commit jobs.

---

## 11. Enable live Copado AI + Org Intelligence

1. Copado Builder Settings → Default → **uncheck Use Mock API** → Save.
2. Optional connectivity check (Developer Console → Execute Anonymous), replace `YOUR_ORG_ID`:

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:Copado_AI_API/organizations/YOUR_ORG_ID/workspaces');
req.setMethod('GET');
req.setHeader('Content-Type', 'application/json');
HttpResponse res = new Http().send(req);
System.debug(res.getStatusCode() + ' ' + res.getBody());
```

Expected: HTTP **200** with JSON.

3. In Builder Status panel:
   - Select **Copado Project**
   - Select **Dev environment** (validated credential on that pipeline)
   - Connect **Org Intelligence** when prompted / available
4. Confirm **Org Context** shows Connected (or follow on-screen probe messaging).

---

## 12. End-to-end live test (Version 1)

1. Select **Copado Project** whose pipeline includes your Dev org.
2. Select **Dev environment** (Validated Status = OK).
3. **Create Story** or **Use Story** to link a real `copado__User_Story__c`.
4. Chat until the story draft is solid (Acceptance Criteria, requirements, org context, tests as needed).
5. Click **Build** — generates the metadata package and stamps User Story Metadata / files. Does **not** deploy by itself.
6. Click **Commit** — starts `builder_deploy_then_commit`:
   1. Deploy package into the selected Dev org
   2. Commit from Dev to the User Story feature branch via `sfdx_commit_1`
7. In the Status panel, use **Refresh** on Job Status until Success (or open the Job Execution in Copado).
8. Verify:
   - [ ] New metadata exists in the Dev org
   - [ ] User Story shows a real commit (Git SHA / User Story Commit), not empty “no changes”
   - [ ] Feature branch contains the committed files

### Per-developer Dev selection

Do **not** put each developer’s sandbox Id only in Custom Metadata. In the Status panel:

1. Pick **Project**
2. Pick **Dev environment**
3. Optionally remember as default (user preference)

Builder stamps that Org Credential onto the User Story before deploy/commit when needed.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Unauthorized endpoint` | Redeploy Remote Site `Copado_AI_API` or confirm it exists |
| `401 Unauthorized` | API key missing/wrong on External Credential principal `ApiKey` |
| Named Credential not found | Must be API name `Copado_AI_API` |
| App / action not visible | Assign `Copado_Builder_User`; add Global Action to Publisher Layout |
| Could not start Job Template `builder_deploy_then_commit` | Install Function + 2-step template; set CMD **Deploy Then Commit Job Template** |
| `The given job has no step to execute` | Template has 0 steps — add Function + `sfdx_commit_1` on the **template**, then run Commit again |
| `sf: command not found` in Function log | Wrong Function Image — copy Image from `sfdx_commit_1` |
| `NoDefaultEnvError` | Ensure credential has Username; Builder sends `targetUsername` in DataJson — use current V1 Apex |
| Commit Success but no Git changes | Deploy step failed or package never landed in Dev — open Job Execution steps |
| Job stuck Not Started | Open Job Execution → Start, or configure Actions Webhook Path |
| Org Intelligence not Connected | Check integration / credential; Use Mock API must be false for live probes |
| Score stays low with full AI draft | Redeploy latest Apex (V1 kit includes chat-aware scoring); refresh session after assistant reply |

---

## Version 1 behavior notes

- **Build** = AI package only (no Copado job).
- **Commit** = combined **deploy to Dev + commit to User Story** via `builder_deploy_then_commit`.
- There is **no** separate Deploy-only or Validate-to-next-env button in Version 1.
- Prefer **Permission Sets** over editing the shared Admin profile when demoing FLS changes (avoids Potential Conflict noise).

---

## Kit file reference

```
copado-builder-version-1/
  README.md
  INSTALL.md                          ← this file
  salesforce/
    copado-builder-v1-mdapi.zip
  copado-functions/
    README.md
    builder-deploy-package/
      script.sh
      config.yml
    builder_deploy_then_commit.job-template.md
```
