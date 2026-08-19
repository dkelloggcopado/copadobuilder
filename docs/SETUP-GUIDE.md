# Copado Builder Setup Guide

## Purpose

This guide covers first-time installation of Copado Builder in a Salesforce/Copado environment for DevOps Exchange consumers.

## Prerequisites

- Copado org with required admin permissions
- Access to this source repository
- Access to target Salesforce environments used in your pipeline
- Copado AI/API credentials configured for your org
- Function runtime image with Salesforce CLI (`sf` or `sfdx`) and `jq`

## Install Steps

1. **Deploy Salesforce metadata**
   - Use the package/deploy artifacts from this repository per release instructions.
   - Minimum required metadata includes app, classes, LWC, custom objects/fields, permissions, custom metadata, and credentials settings.

2. **Assign permissions**
   - Assign `Copado_Builder_User` permission set to intended users.

3. **Configure credentials/integrations**
   - Validate Copado AI/API configuration records.
   - Ensure Development Org Credential binding is set to the expected sandbox/org for Builder usage.

4. **Configure function assets**
   - Create/Update function `builder_deploy_package` using:
     - `copado-functions/builder-deploy-package/script.sh`
     - matching function config from repository docs
   - Confirm runtime image contains Salesforce CLI and `jq`.

5. **Configure job templates**
   - Create/update required Job Templates referenced by Builder flows.
   - Verify template API names align with configured settings.

6. **Configure Builder settings**
   - Review/update `Copado_Builder_Settings` custom metadata values.
   - Ensure endpoints, integration references, and template names are valid.

7. **Smoke test**
   - Open Copado Builder app.
   - Create/select a story.
   - Run Build, Deploy, Commit, Validate in a lower environment.
   - Confirm status updates and artifact visibility.

## Post-Install Validation Checklist

- [ ] App loads without permission errors
- [ ] Users can open Builder chat and session
- [ ] Build generates artifact package
- [ ] Deploy job starts and reports status
- [ ] Commit job starts and reports status
- [ ] Validate and next-environment path function correctly

## Troubleshooting

- **Org context mismatch:** Reconnect Org Intelligence with correct Development Org Credential.
- **Deploy function errors:** Confirm function image has `sf`/`sfdx` + `jq`.
- **Commit retrieval issues:** Verify metadata selections and actual org layout full names.
- **Status refresh errors:** Retry refresh and review latest Copado Job Execution records.

