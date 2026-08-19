# Job Template: builder_deploy_then_commit

Create this Job Template in the Copado org (UI). Copado does not store Job Templates as DX source in this repo.

## Record

| Field | Value |
|-------|-------|
| Name | Builder Deploy Then Commit |
| API Name | `builder_deploy_then_commit` |
| Type | Custom / Automation |

## Steps (in order)

### 1. Deploy Builder package

- **Type:** Function
- **Function:** `builder_deploy_package`
- **Parameters:**
  - `DataJson` = `{$Context.copado__JobExecution__r.copado__DataJson__c}`
  - `sessionId` = `{$Source.Credential.SessionId}`
  - `endpoint` = `{$Source.Credential.EndpointURL}` (preferred) or `{$Source.Credential.Endpoint}`
- **Credential / Environment:** Source Environment = Dev (set by CreateExecution `sourceId`).  
  Parent = User Story so the commit step can resolve branch / repository context.

2. **Step 1 — Function:** `builder_deploy_package`
   - Map DataJson / sessionId / endpoint from `$Source.Credential.*`
   - Function deploys to Dev **and** commits `force-app/` to `featureBranchName`
3. **Step 2:** optional — skip `sfdx_commit_1` (Enricher often marks Builder selections as Non-SF)

Copado Builder Apex creates `copado__JobExecution__c` with:

- Job Template = `builder_deploy_then_commit`
- User Story = linked story
- DataJson = package + environment context (see README)
