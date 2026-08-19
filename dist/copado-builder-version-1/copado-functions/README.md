# Copado Builder — Deploy Then Commit

Copado commit retrieves metadata **from the Dev org**, not from Builder’s generated files.
Build therefore must **deploy the AI package into Dev first**, then run commit.

This folder defines:

| Artifact | Purpose |
|----------|---------|
| `builder-deploy-package/` | Copado Function that writes `force-app/` and runs `sf project deploy` |
| Job Template `builder_deploy_then_commit` | Function step → existing `sfdx_commit_1` (or your commit template) |

## Prerequisites

- Copado Functions enabled
- Salesforce CLI function image available
- Org Credential for Dev validated (Validated Status = OK)
- User Story on the correct Project / pipeline
- Copado Builder Settings → **Deploy Then Commit Job Template** = `builder_deploy_then_commit`

## Install the Function

1. In Copado, create a new Function:
   - **API Name:** `builder_deploy_package`
   - **Image:** MUST include the Salesforce CLI (`sf` or `sfdx`) and `jq`.  
     **`copado-function-core:v1` does NOT include `sf`** → you get `sf: command not found`.  
     Use the same image your org uses for `sfdx_commit_1` / `sfdx_deploy_1` (open one of
     those functions → Configuration → copy its Image Name; commonly a `copado-multicloud-dx` image).
   - **Timeout:** 60 minutes
2. Paste [`builder-deploy-package/script.sh`](builder-deploy-package/script.sh) as the function script.
3. Add these Function parameters (on the Function record **and** on the Job Step):

| Parameter | Value (Dynamic Expression) |
|-----------|----------------------------|
| **DataJson** | `{$Context.copado__JobExecution__r.copado__DataJson__c}` |
| **sessionId** | `{$Source.Credential.SessionId}` |
| **endpoint** | `{$Source.Credential.EndpointURL}` (preferred) or `{$Source.Credential.Endpoint}` |

   Prefer **EndpointURL** (base instance URL). `Endpoint` can include a SOAP path
   (`/services/Soap/u/...`) which breaks `sf` auth (`...UACservices/oauth2/userinfo`).
   The Function script also strips any path as a safety net.
4. Save / publish the function.

## Create the Job Template

1. Create Job Template:
   - **Name:** `builder deploy then commit` (spaces are fine)
   - **Preferred API / Developer Name:** `builder_deploy_then_commit`
2. **Step 1 — Function:** `builder_deploy_package`
   - Map the three parameters above (DataJson, sessionId, endpoint) using **`$Source.Credential.*`**
   - Source Environment = Dev (stamped by Builder Apex)
   - This Function **deploys the AI package into Dev only**. It does not push to Git.
3. **Step 2 — Commit (required):** `sfdx_commit_1` (or your org’s standard Copado commit template)
   - Depends on Step 1 succeeding
   - Retrieves the deployed metadata from Dev and commits it to the User Story feature branch
   - This is what ties the Git commit to the Copado User Story (via User Story Commit)
4. Save the template.
5. In Copado Builder Settings, set **Deploy Then Commit Job Template** to either:
   - `builder_deploy_then_commit`, or
   - the exact Job Template **Name** (`builder deploy then commit`), or
   - the Job Template **Salesforce Id** / API Name (`builder_deploy_then_commit_1`)

## What Builder sends in DataJson

```json
{
  "userStoryId": "a1s...",
  "userStoryCommitId": "a1t...",
  "contentDocumentId": "069...",
  "environmentId": "a0B...",
  "environmentRecordId": "a0E...",
  "targetUsername": "dev1.user@example.com.dev1",
  "targetOrgId": "00D...",
  "message": "Copado Builder commit for US-0000040",
  "commitMessage": "Copado Builder commit for US-0000040",
  "featureBranchName": "feature/US-0000040",
  "baseBranch": "dev",
  "recreateFeatureBranch": false,
  "fileWithSelectedChanges": "068...",
  "changes": [
    { "t": "CustomField", "n": "Account.High_Touch_Account__c", "m": "", "j": "", "c": "SFDX", "a": "Add" }
  ],
  "pipelineId": "a0P...",
  "source": "CopadoBuilder",
  "action": "deployThenCommit",
  "packageJson": {
    "summary": "...",
    "files": [
      { "path": "force-app/main/default/...", "content": "..." }
    ]
  }
}
```

Commit step expressions such as `DataJson.message`, `featureBranchName`, `baseBranch`,
and `fileWithSelectedChanges` are populated by Builder. `fileWithSelectedChanges` is a
**ContentVersion** Id (`068…`) pointing at a file titled **Copado Commit changes** whose
JSON matches the Copado UI (normal SFDX commit — not selective):

`[{"t":"CustomField","n":"Account.Field__c","m":"","j":"","c":"SFDX","a":"Add"}]`

- `c` = `"SFDX"` (pipeline format). Using `"Add"` here made Enricher treat rows as Non-SF.
- `a` = `"Add"` for a normal full-component commit (empty `m`/`j` = not selective).
- Builder **creates User Story Metadata first**, then builds this JSON from those rows
  (same source of truth as the Copado Commit Changes UI). Package paths are only a fallback.

Pipeline is stamped on the Job Execution so `{$Pipeline.*}` resolves.

Builder creates a **User Story Commit** and starts CreateExecution with that record as
`parentId` so the JE → User Story Commit → User Story chain matches Copado’s Commit Changes UI.

`targetUsername` / `targetOrgId` come from the User Story's Org Credential and are
used by the Function as `--target-org`. Copado authenticates the credential's org in
the container but does not set a default (which caused `NoDefaultEnvError`); passing
the username explicitly resolves it. If your org exposes an access token + instance URL
to the step instead, the script uses those first.

`packageJson` is included when the serialized package is under ~90KB so the Function does not need to download ContentVersion from the Copado org.

## Important: starting Job Executions

Builder starts the template via Copado's official Apex API:

`copado.CreateExecution` with `parentId` (User Story Commit when available, else User Story),
`sourceId` (Dev Environment), `pipelineId`, `dataJson`, and `runAfterInstantiation = true`.

That is what instantiates Job Steps and wires Context / Source / Pipeline so
`{$Source.Credential.*}` and commit expressions resolve. Raw Apex insert of
`copado__JobExecution__c` alone leaves the job empty — do not rely on that path.

Your user needs the **Copado Job Engine** permission set.

If CreateExecution is unavailable, Builder falls back to inserting a Job Execution
row (may still need Execute/Start in the UI).

## Verify

1. Create a User Story on the project that owns Dev1.
2. In Copado Builder: select that project + Dev credential → **Build Code**.
3. Confirm Job Execution `builder_deploy_then_commit` moves past Not Started and Completes.
4. Confirm the field/component exists in Dev1.
5. Confirm User Story Commit / Git feature branch has a real commit (not “no changes”).
