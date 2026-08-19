# Job Template: builder_deploy_only

Deploy-only template for Copado Builder **Phase 1** (separate Deploy button).

Uses the existing Function `builder_deploy_package` — **no** commit step.

## Record

| Field | Value |
|-------|-------|
| Name | Builder Deploy Only |
| API Name | `builder_deploy_only` |
| Type | Custom |

## Steps (exactly one)

### 1. Deploy Builder package

- **Type:** Function
- **Function:** `builder_deploy_package` (must already exist — see `README.md`)
- **Parameters:**

| Parameter | Dynamic Expression |
|-----------|-------------------|
| DataJson | `{$Context.copado__JobExecution__r.copado__DataJson__c}` |
| sessionId | `{$Source.Credential.SessionId}` |
| endpoint | `{$Source.Credential.EndpointURL}` (preferred) or `{$Source.Credential.Endpoint}` |

- **Source Environment:** Dev (set by Builder `CreateExecution` `sourceId`)

## Copado Builder Settings

Set **Deploy Job Template** = `builder_deploy_only` (not `sfdx_deploy_1`).

`sfdx_deploy_1` is the **Promotion** deploy template — do not use it for AI package deploy to Dev.

## Verify

1. Build a package in Builder.
2. Click **Deploy** (not Commit).
3. Job Execution for `builder_deploy_only` succeeds.
4. Metadata appears in Dev.
5. **No** new User Story Commit / Git commit yet.
