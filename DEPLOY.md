# Copado Builder — Deploy Guide

## MDAPI zip deploy (Copado / Workbench upload)

**Use this file** if you deploy via zip upload in Copado or Salesforce:

```
~/Projects/copado-builder/copado-builder-mdapi.zip
```

Rebuild anytime:

```bash
./scripts/build-mdapi-zip.sh
```

The zip has `package.xml` at the **root** — required for MDAPI deploy. The previous zip failed with `No package.xml found` because metadata was nested under `force-app/` without a root-level manifest.

**Copado deploy:**
1. Upload `copado-builder-mdapi.zip`
2. Deploy Components (tests not required for initial POC)
3. Assign `Copado_Builder_User` permission set

---

## One-command deploy (Salesforce CLI)

```bash
cd ~/Projects/copado-builder

# Log in once
sf org login web --instance-url https://test.salesforce.com --alias copado-psa

# Deploy everything + run tests + assign permission set
chmod +x scripts/deploy.sh
./scripts/deploy.sh copado-psa
```

Or deploy manually:

```bash
sf project deploy start --source-dir force-app --target-org copado-psa --wait 15
sf apex run test --tests CopadoBuilderControllerTest --target-org copado-psa --result-format human --wait 10
sf org assign permset --name Copado_Builder_User --target-org copado-psa
```

Or deploy from manifest:

```bash
sf project deploy start --manifest manifest/package.xml --target-org copado-psa --wait 15
```

---

## What gets deployed

| Category | Components |
|----------|------------|
| **Objects** | `AI_Builder_Session__c`, `AI_Builder_Message__c`, `AI_Builder_Action__c` |
| **Config** | `Copado_Builder_Settings__mdt` + Default record |
| **Apex** | `CopadoBuilderController`, `CopadoAiApiService`, `CopadoBuilderControllerTest` |
| **LWC** | `copadoBuilderChat` |
| **App** | Copado Builder app, tab, flexipage |
| **Integration** | Remote Site, External Credential, Named Credential |
| **Security** | `Copado_Builder_User` permission set |

---

## Post-deploy (required — cannot be in metadata)

### 1. Per-user Copado AI Personal Access Tokens

Builder no longer uses a shared External Credential API key for auth. Each Salesforce user pastes their own Copado AI Personal Access Token in the Builder setup modal (stored on private **Copado Builder User Secret** — Long Text; the old Hierarchy CS 255-char field truncated many PATs and caused 401s).

1. Confirm **Base Url** on Copado Builder Settings matches your Copado AI region, and Remote Site Setting allows that host.
2. Assign permission set **Copado Builder User** (includes access to `Copado_Builder_User_Secret__c`).
3. **Each Builder user:** create a PAT in the Copado AI Platform → open Builder → paste the **full** token in setup (or **Update Copado AI token**) → Connect their User Level Org Credential in Copado AI Settings. If you previously saved a token and see 401, re-paste — the old store may have truncated it.

> Do not paste one shared PAT for the whole Hub org — Copado AI isolates User Level integrations per account. A shared token always acts as the token owner only.

### 2. Configure Custom Metadata

1. **Setup** → search **Custom Metadata Types**
2. **Copado Builder Settings** → **Manage Records** → **Default**
3. Set:

| Field | Value |
|-------|-------|
| **Organization Id** | Your Copado AI org ID |
| **Base Url** | `https://copadogpt-api.robotic.copado.com` (or your region) |
| **Workspace Id** | Optional — leave blank to auto-create per session |
| **Use Mock API** | ✅ checked for offline demo; **uncheck** for live Copado AI generate + real DevOps |
| **Commit Job Template** | Legacy commit-only template (default `sfdx_commit_1`) — Build Code no longer uses this alone |
| **Deploy Job Template** | Copado Job Template name/Id (default `sfdx_deploy_1`) for the separate Deploy button |
| **Deploy Then Commit Job Template** | Required for Build Code live mode (default `builder_deploy_then_commit`) |
| **Default Dev Environment Id** | Optional org-wide fallback only — **developers should not need this**. Each user picks Dev in the Builder UI |
| **Actions Webhook Path** | Optional same-org REST path for RunJobTemplate (leave blank to use Job Execution DML) |

### Install deploy-then-commit Function + Job Template

Copado commit retrieves metadata **from the Dev org**, not from Builder’s generated JSON. Build Code therefore deploys the AI package into the selected Dev org first, then commits.

See [`copado-functions/README.md`](copado-functions/README.md) for install steps. Summary:

1. Create Copado Function `builder_deploy_package` from `copado-functions/builder-deploy-package/`.
2. Create Job Template `builder_deploy_then_commit` with steps: Function deploy → Copado commit (`sfdx_commit_1`).
3. Set **Deploy Then Commit Job Template** = `builder_deploy_then_commit` on Copado Builder Settings Default.
4. Leave **Actions Webhook Path** blank unless you start jobs via REST instead of Job Execution DML.

### Per-developer Dev environment

Do **not** rely on Custom Metadata for each developer’s sandbox.

In Copado Builder Status panel:

1. Select **Copado Project** — the project whose pipeline includes your Dev org (e.g. Dev1).
2. Select **Dev environment** — validated Org Credentials for that project’s pipeline only.
3. Optionally check **Remember as my default** (saved per user / project on `Copado_Builder_User_Preference__c`).
4. Click **Build Code** or **Deploy to Dev**.

Builder will write that Org Credential onto the linked Copado User Story before deploy/commit. If the story already has a matching credential, it is pre-selected.

Resolution order:

1. Credential / environment already on the user story (if it is in the validated list)  
2. Your saved preference for that project  
3. First validated non-production Org Credential in the list  

### Build → Deploy to Dev → Commit (live)

With **Use Mock API** unchecked, Copado CI/CD installed, and `builder_deploy_then_commit` installed:

1. **Select Copado Project** — required before create; avoids “credential not included in the project pipeline”.
2. **Create / Update Copado Story** — writes real `copado__User_Story__c` under that project and stores `Story_Record_Id__c`.
3. **Select Dev environment** — required; only validated Org Credentials (`Validated Status = OK`) in that project’s pipeline.
4. **Build Code** — Copado AI returns a metadata package → stores ContentVersion → stamps User Story Metadata + Org Credential → starts `builder_deploy_then_commit` (deploy package to Dev, then Copado commit).
5. **Refresh job status** (Status panel) — confirm Job Execution succeeded; failures appear as System chat messages.
6. **Review Code / Create Tests** — Copado AI analyzes the stored package (not CRT yet).
7. **Deploy to Dev** (optional later promote) — separate job template for pipeline deploy when needed.

#### End-to-end checklist

- [ ] Story is on the correct Copado Project (pipeline includes Dev1).
- [ ] Dev1 Org Credential shows Validated Status = OK and is selected in Status panel.
- [ ] Function + Job Template `builder_deploy_then_commit` installed; CMD field set.
- [ ] Build Code succeeds and Last Job Id is populated.
- [ ] Job Status reaches success (not Failed).
- [ ] Generated field/component **exists in Dev1**.
- [ ] User Story shows a real Commit (Git SHA / commit record), not empty “no changes”.
- [ ] Feature branch contains the committed metadata.

Org list is **only** validated Org Credentials (`Validated Status = OK`), filtered to the selected project’s pipeline when possible.

### 3. Assign permission set to users

```bash
sf org assign permset --name Copado_Builder_User --target-org copado-psa --on-behalf-of your.user@copado.com.psa
```

Or via Setup → Permission Sets → Copado Builder User → Manage Assignments.

### 4. Open the app

App Launcher → **Copado Builder**

---

## Verify API connectivity

Developer Console → Execute Anonymous (replace `YOUR_ORG_ID`):

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:Copado_AI_API/organizations/YOUR_ORG_ID/workspaces');
req.setMethod('GET');
req.setHeader('Content-Type', 'application/json');
HttpResponse res = new Http().send(req);
System.debug(res.getStatusCode() + ' ' + res.getBody());
```

Expected: `200` with workspace list JSON.

## Verify Org Intelligence (target Dev org)

1. Deploy `copado-builder-updates-2-code.zip` (Use Mock API = **false**).
2. In Copado Builder: create/link a story → select Dev environment → **Connect Org Intelligence**.
3. Status panel **Org Context** should become `Connected`, and a System chat message will include:
   - probe answer (should name live custom objects/fields)
   - truncated `configure` JSON (shows the credential shape Copado AI expects)
4. Or run `scripts/probe-org-intelligence.apex` in Execute Anonymous (replace `CREDENTIAL_ID`).

If create fails, paste `rawConfigureJson` from the System message — that tells us the exact credential payload shape to lock in.

---

## Region URLs

| Region | Base URL |
|--------|----------|
| US | `https://copadogpt-api.robotic.copado.com` |
| EU | `https://copadogpt-api.eu-robotic.copado.com` |
| Australia | `https://copadogpt-api.au-robotic.copado.com` |
| Singapore | `https://copadogpt-api.sg-robotic.copado.com` |

Update **Base Url** in Custom Metadata and redeploy Named Credential URL if needed.

---

## Incremental Workbench zips

After schema/code changes, rebuild:

```bash
chmod +x scripts/build-updates-zips.sh
./scripts/build-updates-zips.sh
```

Upload order: **`copado-builder-updates-1-schema.zip` first**, then `copado-builder-updates-2-code.zip`.

If Apex fails with errors on all Builder classes, the schema field usually was not deployed yet (or deploy order was reversed). Redeploy schema, then code.

Schema zip adds the CMD field + layout only (it does **not** redeploy the Default CMD record, so live Use Mock API / org Id settings are preserved). After schema deploy, set **Deploy Then Commit Job Template** = `builder_deploy_then_commit` on Default.

Also install Copado Function/template from `copado-functions/` (not in the Salesforce zip).

---

## Troubleshooting

| Error | Fix |
|-------|-----|
| `Unauthorized endpoint` | Remote Site `Copado_AI_API` not deployed — redeploy `force-app` |
| `401 Unauthorized` | PAT missing/wrong/truncated, or Organization Id / region mismatch — Builder → **Update Copado AI token** (re-paste full PAT after schema deploy) |
| “Add your Copado AI Personal Access Token” | User has not saved a PAT in Builder setup yet |
| `Named Credential not found` | Named Credential API name must be `Copado_AI_API` |
| App not visible | Assign `Copado_Builder_User` permission set |
| Tests fail | Deploy all objects first, then Apex |
| Could not start Job Template `builder_deploy_then_commit` | Install Function + template (`copado-functions/README.md`); set Deploy Then Commit Job Template CMD |
| Commit succeeds with no Git changes | Package never landed in Dev — confirm deploy step of the job succeeded before commit |
| Job Status Failed | Open Copado Job Execution; fix deploy errors in Dev, then Build again |
| `The given job has no step to execute` | Job Template has 0 steps — add Step 1 (Function `builder_deploy_package`) + Step 2 (commit) on the **template**, then Build again for a fresh execution |
| `sf: command not found` in Function log | Function Image lacks the Salesforce CLI — switch Image to your org's DX/commit image (copy from `sfdx_commit_1`) |
| `NoDefaultEnvError` in Function log | Builder now sends `targetUsername` in DataJson so the script passes `--target-org`. Redeploy code zip; ensure the credential has a Username; confirm the step runs against the User Story Org Credential |
| Job stuck at Not Started | Open the Job Execution → Start Execution, or set Actions Webhook Path for RunJobTemplate |
