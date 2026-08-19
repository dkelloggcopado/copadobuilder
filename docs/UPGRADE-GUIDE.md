# Copado Builder Upgrade Guide

## Purpose

This guide covers upgrading an existing Copado Builder installation to a newer release.

## Upgrade Principles

- Test upgrade in a non-production org first.
- Keep rollback artifacts for the currently installed version.
- Re-apply any function/template/config updates bundled with the new release.

## Upgrade Steps

1. **Review release notes / changed components**
   - Identify changed metadata, classes, LWC, settings, and function scripts.

2. **Backup current configuration**
   - Export current custom metadata/settings values.
   - Snapshot function scripts and job template configuration.

3. **Deploy upgraded metadata**
   - Deploy updated package to target org.
   - Resolve any metadata conflicts before continuing.

4. **Update function implementation**
   - Re-paste latest `copado-functions/builder-deploy-package/script.sh`.
   - Confirm function parameters and runtime image requirements still match.

5. **Review settings and template API names**
   - Ensure configured template/function names still exist and match expected APIs.

6. **Re-validate org context integration**
   - Reconnect Org Intelligence if required.
   - Confirm selected Development Org Credential is correct.

7. **Run regression flow**
   - Build → Deploy → Commit → Validate on a test story.
   - Confirm artifact names, status updates, and job execution links behave correctly.

## Breaking-Change Checks

- [ ] Any renamed settings fields
- [ ] Any changed template API name expectations
- [ ] Any changed function parameter requirements
- [ ] Any changed metadata type handling (layouts/profiles/fields)

## Rollback Plan

If upgrade fails:

1. Re-deploy previous known-good package.
2. Restore previous function script and template settings.
3. Re-run smoke test to confirm baseline behavior.

