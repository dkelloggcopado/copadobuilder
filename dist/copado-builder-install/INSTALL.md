# Copado Builder — Installation Guide

Follow these steps **in order**. When you finish, a new user can open Copado Builder, talk to Copado AI, create a User Story, Build metadata, Deploy to a Dev org, Commit, and promote to the next environment.

**Who this is for:** someone installing Copado Builder into a Salesforce org that already has **Copado CI/CD** installed. No coding experience required.

---

## Checklist (print or copy)

- [ ] 1. Confirm prerequisites
- [ ] 2. Deploy the **one** Salesforce package (`copado-builder-mdapi.zip`)
- [ ] 3. Assign the permission set
- [ ] 4. Add the Copado AI API key (Salesforce)
- [ ] 5. Fill in Copado Builder Settings (Salesforce)
- [ ] 6. Create the Copado Function (Copado)
- [ ] 7. Create the Job Templates (Copado)
- [ ] 8. Add the Global Action to the Publisher Layout (Salesforce)
- [ ] 9. Connect Copado AI “User Level” (Copado AI)
- [ ] 10. Open Builder and smoke-test
- [ ] 11. Turn on live mode and run one real Build → Deploy → Commit

---

## 1. Prerequisites

Before you install anything, confirm all of the following:

| Requirement | How to check |
|-------------|--------------|
| Copado CI/CD is installed | App Launcher shows Copado apps; you can open a **User Story** |
| Copado Functions are enabled | In Copado you can create **Functions** and **Job Templates** |
| Your user can run jobs | You have Copado permissions including **Copado Job Engine** (or equivalent) |
| At least one Dev org credential | Copado **Org Credential** with **Validated Status = OK**, not Production |
| A Copado Project + pipeline | That Dev credential sits on a Project pipeline (e.g. Dev → Int → UAT) |
| Standard commit template exists | Usually named `sfdx_commit_1` (note your org’s name if different) |
| Copado AI access | You have a Copado AI **Organization Id** and a **Personal Access Key** |

You will need these values written down:

1. Copado AI **Organization Id**
2. Copado AI **Personal Access Key**
3. Your Copado AI region (US / EU / Australia / Singapore)

---

## 2. Deploy the Salesforce package (one zip)

Fresh installs use **one** Metadata API zip. It includes objects, Apex, LWC, the Copado Builder app, Global Action, Remote Site, Named/External Credential shells (no secret), permission set, and default settings.

| File | Where | Required? |
|------|-------|-----------|
| **`salesforce/copado-builder-mdapi.zip`** | Inside the install kit | **Yes — deploy this once** |
| Files under `copado-functions/` | Inside the install kit | **Yes — but manual** (not a Salesforce deploy) |

> Copado Functions, Job Templates, API keys, and Copado AI User Level **cannot** go inside a Salesforce package. Those stay in the manual steps below.

### How to deploy (Workbench)

1. Open [Workbench](https://workbench.developerforce.com) and log into the **Copado (CI/CD) Salesforce org** (the org where Copado is installed — not a random Dev sandbox, unless that *is* your Copado org).
2. Go to **migration** → **Deploy**.
3. Choose **`salesforce/copado-builder-mdapi.zip`** (from the install kit).
4. Check **Single Package**.
5. Click **Next** → **Deploy**.
6. Wait until status is **Succeeded**.

### How to deploy (Salesforce CLI)

```bash
mkdir -p /tmp/cb-deploy
unzip -q salesforce/copado-builder-mdapi.zip -d /tmp/cb-deploy
sf project deploy start --metadata-dir /tmp/cb-deploy --target-org YOUR_ORG_ALIAS --wait 30
```

### Updating an existing install (maintainers)

If Builder is **already** in the org, do **not** redeploy the full MDAPI zip with credentials — that can wipe the API key and overwrite settings. From the source repo, use incremental zips instead:

1. `copado-builder-updates-1-schema.zip` — only when objects/fields change  
2. `copado-builder-updates-2-code.zip` — Apex + LWC updates  
3. `copado-builder-updates-4-global-action.zip` — only if the Global Action changed  

Always deploy **schema before code** when using those update zips.

```bash
./scripts/build-updates-zips.sh
```

---

## 3. Assign the permission set (Salesforce)

1. In Salesforce, open **Setup**.
2. Search for **Permission Sets**.
3. Open **Copado Builder User**.
4. Click **Manage Assignments** → **Add Assignment**.
5. Select every user who should use Copado Builder → **Assign**.

Also make sure those users can:

- Create / edit Copado **User Stories**
- Start Copado **Job Executions**
- Use the selected **Org Credentials**

---

## 4. Add the Copado AI API key (Salesforce — manual)

Secrets cannot be stored in the zip. You must paste the key once in Setup.

1. **Setup** → search **Named Credentials**.
2. Open the **External Credentials** tab.
3. Click **Copado AI API Key**.
4. Under **Principals**, open **Principal** → **Edit**.
5. Under **Authentication Parameters**, add (or edit) this row:

| Field | Exact value |
|-------|-------------|
| **Name** | `ApiKey` (spelling must match exactly) |
| **Value** | Your Copado AI **Personal Access Key** |

6. Save.
7. Still on the External Credential, confirm these headers exist:

| Header | Value |
|--------|-------|
| `Api-Key` | `{!$Credential.Copado_AI_API_Key.ApiKey}` |
| `X-Authorization` | `{!$Credential.Copado_AI_API_Key.ApiKey}` |

8. Open **Named Credentials** → **Copado AI API** and confirm:
   - It uses External Credential **Copado AI API Key**
   - The URL matches your Copado AI region (see table in step 5)

> If you ever **redeploy** the External Credential metadata, the secret can be wiped. Paste the API key again.

---

## 5. Configure Copado Builder Settings (Salesforce)

1. **Setup** → search **Custom Metadata Types**.
2. Click **Copado Builder Settings**.
3. Click **Manage Records**.
4. Open **Default** → **Edit**.
5. Set these fields:

| Field | What to enter |
|-------|----------------|
| **Organization Id** | Your Copado AI Organization Id |
| **Base Url** | Region URL from the table below |
| **Workspace Id** | Leave blank |
| **Use Mock API** | **Checked** for the first smoke test; later **uncheck** for live Copado AI |
| **Commit Job Template** | `sfdx_commit_1` (or your org’s OOTB commit template) |
| **Deploy Job Template** | `builder_deploy_only` (created in step 7) |
| **Deploy Then Commit Job Template** | `builder_deploy_then_commit` (created in step 7) |
| **Validate Promote Job Template** | Usually `sfdx_promote_1` |
| **Validate Deploy Job Template** | Usually `sfdx_deploy_1` |
| **Default Dev Environment Id** | Leave blank (users pick Dev in the UI) |
| **Actions Webhook Path** | Leave blank |

### Copado AI region URLs

| Region | Base Url |
|--------|----------|
| US | `https://copadogpt-api.robotic.copado.com` |
| EU | `https://copadogpt-api.eu-robotic.copado.com` |
| Australia | `https://copadogpt-api.au-robotic.copado.com` |
| Singapore | `https://copadogpt-api.sg-robotic.copado.com` |

If you change **Base Url**, update the Named Credential URL to the same value.

6. **Save**.

---

## 6. Create the Copado Function (Copado — manual)

Deploy and Commit need a Copado Function that is **not** inside the Salesforce zip.

### 6.1 Create the Function

1. In Copado, go to **Functions** → create a new Function.
2. Set:

| Field | Value |
|-------|-------|
| **API Name** | `builder_deploy_package` (exact) |
| **Timeout** | 60 minutes |
| **Image** | Copy the **Image Name** from your org’s existing `sfdx_commit_1` or `sfdx_deploy_1` Function. It must include the Salesforce CLI (`sf`) and `jq`. Do **not** use `copado-function-core:v1` alone. |

3. Open `copado-functions/builder-deploy-package/script.sh` from this kit.
4. Copy the entire script into the Function script editor.
5. Save / publish the Function.

### 6.2 Add Function parameters

Add these parameters on the Function (you will map them again on the Job Step):

| Parameter name | Dynamic expression |
|----------------|-------------------|
| `DataJson` | `{$Context.copado__JobExecution__r.copado__DataJson__c}` |
| `sessionId` | `{$Source.Credential.SessionId}` |
| `endpoint` | `{$Source.Credential.EndpointURL}` (preferred) |

---

## 7. Create the Job Templates (Copado — manual)

You need **two** templates.

### 7.1 Deploy-only template (`builder_deploy_only`)

Used by the **Deploy** button in Builder.

1. Create a Job Template named e.g. `builder deploy only`.
2. Preferred API name: `builder_deploy_only`.
3. Add **one** step: Function `builder_deploy_package`.
4. Map `DataJson`, `sessionId`, and `endpoint` as in step 6.2.
5. Save. Confirm the template shows **1 step**.

### 7.2 Deploy-then-commit template (`builder_deploy_then_commit`)

Used when you want deploy + commit in one job (also referenced by settings).

1. Create a Job Template named e.g. `builder deploy then commit`.
2. Preferred API name: `builder_deploy_then_commit`.
3. **Step 1:** Function `builder_deploy_package` (same parameter mapping).
4. **Step 2:** OOTB commit template `sfdx_commit_1` (depends on Step 1 succeeding).
5. Save. Confirm the template shows **2 steps**.

### 7.3 Point Builder Settings at the templates

Return to **Copado Builder Settings → Default** and confirm:

- **Deploy Job Template** = `builder_deploy_only`
- **Deploy Then Commit Job Template** = `builder_deploy_then_commit`
- **Commit Job Template** = `sfdx_commit_1`

---

## 8. Add the Global Action (Salesforce — manual)

So users can open Builder from the Lightning **+** menu on any page:

1. **Setup** → search **Publisher Layouts**.
2. Edit the layout your users use (often **Global Layout**).
3. Find **Salesforce Mobile and Lightning Experience Actions**.
4. Add **Copado Builder**.
5. Save.

Users can also open **App Launcher → Copado Builder** without this step.

---

## 9. Connect Copado AI “User Level” (Copado AI — manual)

Org Intelligence lets the Build Agent read **live metadata** from a Salesforce org (Dev, Int, etc.).

1. Open **Copado AI** (web app) and sign in.
2. Go to **Integrations** (or **My Integrations**).
3. Find or create the integration named **User Level** (type Copado / CI/CD).
4. Set **Development Org Credential** to the Dev org you will use first (for example `dev1`).
5. Click **Save**.
6. Keep this integration **connected / healthy**.

### Important behavior

- Builder **Org Context** (the dropdown in the Status panel) and Copado AI **User Level** should stay on the **same** org when you ask metadata questions or click **Check deployment**.
- After you promote a story to the next environment (for example `int`), set Org Context to that environment and click **Reconnect Org Intelligence**.
- You can also open Copado AI → Integrations and change **Development Org Credential** to `int` (or the next env), then **Save**, then Reconnect in Builder.

---

## 10. Open Builder and smoke-test (mock mode)

1. Leave **Use Mock API** = **checked**.
2. App Launcher → **Copado Builder** (or Lightning **+** → Copado Builder).
3. Start a chat describing a tiny change (example: “Add a text field Favorite_Color__c on Account”).
4. Confirm messages appear and the Status panel loads (Project, Org Context, pipeline icons).
5. You do **not** need a real Deploy/Commit success in mock mode.

---

## 11. Turn on live mode and run a real change

1. **Copado Builder Settings → Default** → **uncheck Use Mock API** → Save.
2. In Builder:
   1. Choose **Copado Project**.
   2. Set **Org Context** to a validated Dev credential.
   3. Click **Connect Org Intelligence** / **Reconnect Org Intelligence** until Org Context shows **Connected**.
   4. **Create Story** or link an existing User Story.
   5. Chat until the story is clear.
   6. Click **Build** (creates the metadata package — watch **Artifacts** in the Status panel).
   7. Click **Deploy** (deploys into the selected Dev org).
   8. Click **Commit** (commits from Dev to the User Story branch).
   9. Optional: **Validate** / **Deploy** to the next environment, then **Check deployment**.

### Success checklist

- [ ] Metadata exists in the Dev org
- [ ] User Story has a real commit (not “no changes”)
- [ ] Org Context shows Connected for the org you expect
- [ ] **Check deployment** reports the correct org first, then FOUND/MISSING for each artifact

---

## Package map (quick reference)

```
Fresh install (what installers get)
  1) salesforce/copado-builder-mdapi.zip   ← ONE Salesforce deploy
  +) copado-functions/                    ← manual Function + Job Templates

Later updates (maintainers / source repo only)
  1) copado-builder-updates-1-schema.zip  (only when objects/fields change)
  2) copado-builder-updates-2-code.zip
  3) copado-builder-updates-4-global-action.zip  (only if Global Action changed)
```

Rebuild from source:

```bash
./scripts/build-mdapi-zip.sh --with-credentials   # full zip for fresh installs
./scripts/pack-install-kit.sh                     # dist/copado-builder-install.zip
./scripts/build-updates-zips.sh                   # optional incremental update zips
```

---

## Troubleshooting

| What you see | What to do |
|--------------|------------|
| `Unauthorized endpoint` | Remote Site **Copado AI API** missing — redeploy the MDAPI zip or Remote Site |
| `401 Unauthorized` | API key missing/wrong on External Credential principal `ApiKey` |
| App not visible | Assign permission set **Copado Builder User** |
| Apex deploy errors on update zips | Deploy **schema** zip before **code** zip |
| Could not start Job Template | Function/template missing, or Settings field has the wrong name |
| `sf: command not found` in Function log | Wrong Function Image — copy Image from `sfdx_commit_1` |
| Commit Success but no Git changes | Deploy step never landed metadata in Dev — open the Job Execution |
| Org Intelligence “Not bound” while UI shows the right org | In Copado AI, Save User Level on that credential, then **Reconnect** in Builder |
| Global Action missing from **+** | Add **Copado Builder** to the Publisher Layout |

---

## What Builder does after install (for trainers)

| Button | Purpose |
|--------|---------|
| **Improve Story** | Refine requirements with Copado AI |
| **Create Story** | Create / update the Copado User Story |
| **Build** | Generate the metadata package (Artifacts list) |
| **Deploy** | Deploy package into the current Org Context (Dev) |
| **Commit** | Commit deployed metadata to the User Story branch |
| **Validate** | Validate promotion toward the next environment |
| **Deploy to …** | Promote / deploy to the next pipeline environment |
| **Check deployment** | Ask Build Agent to verify artifacts in the **current** User Level org |

### Status panel tips (for trainers)

| UI element | What it does |
|------------|--------------|
| **Pipeline icons** (Deploy / Commit / Validate / Deploy to …) | Click a **spinner** or **check/X** to open the related Copado Job Execution or Promotion in a new tab. Status still updates automatically while a job runs. |
| **Build** icon | Marks package generation complete. Build is AI-only (no Copado Job Execution to open). |
| **Artifacts** | Shows file count; click the row/chevron to expand or minimize the file list. |
| **Org Context → Reconnect** | Re-binds Copado AI **User Level** to the selected environment after promote (e.g. Dev → Int). |

### Shareable install kit

```bash
./scripts/build-mdapi-zip.sh --with-credentials
./scripts/pack-install-kit.sh
```

That creates **`dist/copado-builder-install.zip`** containing:

```
copado-builder-install/
  START-HERE.txt
  INSTALL.md                 ← start here
  README.md
  salesforce/
    copado-builder-mdapi.zip ← ONE Salesforce deploy
    README.txt
  copado-functions/          ← Function script + notes (manual)
```

Give recipients **`dist/copado-builder-install.zip`** and tell them to open **INSTALL.md** first.
