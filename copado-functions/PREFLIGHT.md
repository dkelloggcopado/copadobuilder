# Org preflight — Deploy / Commit / Validate

Run these in the Copado org before relying on Phase 2 Validate in demos.  
Phase 1 (Deploy + Commit split) only needs **A**.

## A. Deploy-only template (required for Phase 1)

1. Ensure Function `builder_deploy_package` exists (same as Version 1).
2. Create Job Template per [`builder_deploy_only.job-template.md`](builder_deploy_only.job-template.md).
3. Set Copado Builder Settings → **Deploy Job Template** = `builder_deploy_only`.
4. Smoke: Builder **Deploy** → JE Success → metadata in Dev → no Git commit.

## B. Commit-only (OOTB `sfdx_commit_1`)

1. After a successful Deploy, click Builder **Commit**.
2. Confirm CreateExecution uses template `sfdx_commit_1` (CMD **Commit Job Template**).
3. Confirm User Story Commit / feature branch updates.

Optional Anonymous Apex probe (replace Ids):

```apex
copado.CreateExecution.Request r = new copado.CreateExecution.Request();
r.templateName = 'sfdx_commit_1';
r.parentId = 'USC_ID';
r.sourceId = 'ENV_ID';
r.dataJson = '{"message":"probe","recreateFeatureBranch":false}';
r.runAfterInstantiation = true;
// If this compiles, destinationId is available for Validate:
// r.destinationId = 'DEST_ENV_ID';
System.debug(r);
```

## C. Validate Changes (Builder auto-start)

Builder Validate creates a Promotion (**with Pipeline stamped**), then in a Queueable
calls Copado’s **Promotion Deployment action** (`copado.PromotionDeployAction.promote`
with `deploymentDryRun=true` for Validate). That action creates the Deployment, selections
file, OOTB payload, and runs the Pipeline Action job template — same path as **Deploy Changes**
/ Flow “Run a Copado promotion deployment action”.

If the official action is unavailable, Builder falls back to CreateExecution with OOTB
Promote then Deploy DataJson:

| Step | `action` | Key fields |
|---|---|---|
| Promote | `Promotion` | `userStoryIds[]`, `userStoryBranches[]`, distinct `sourceCredentialId` / `destinationCredentialId`, `promotionBranchName`, `fileWithSelectedChanges`, `executePromotion`, `executeDeployment`, `deploymentDryRun` |
| Deploy | `PromotionDeployment` | `deploymentId`, `transactionId`/`promotionId`, `promotionBranchName`, `fileWithSelectedChanges`, `destinationBranchName`, `deploymentDryRun` |

Do **not** send Builder’s old shape (`action: validate`, `environmentRecordId`, same source/dest).

Calling CreateExecution only for deploy (skipping merge) left Promotions stuck in
**Draft / Promotion not Started**.

Set on Copado Builder Settings → Default (used by CreateExecution fallback):

| Field | Value (Job Template API Name) |
|---|---|
| Validate Promote Job Template | usually `sfdx_promote_1` |
| Validate Deploy Job Template | usually `sfdx_deploy_1` |

Validate Status is **In progress** while jobs run, **Successful** only after the dry-run Job Execution completes OK, and **Failed** if that job errors (e.g. missing field on layout).

After Validate is Successful, use **Deploy to {next}** for a real (non–dry-run) deploy to the next pipeline environment.
