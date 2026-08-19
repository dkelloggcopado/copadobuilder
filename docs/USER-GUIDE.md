# Copado Builder User Guide

## Overview

Copado Builder provides a guided delivery workflow for Copado User Stories:

1. Build metadata package
2. Deploy to selected dev environment
3. Commit from org to feature branch
4. Validate for next environment
5. Promote/deploy to next environment

## Personas

## Admin / Release Manager

- Configure app access and permission set assignment
- Configure Builder settings and integration credentials
- Configure required job templates and function scripts
- Monitor pipeline status and validation outcomes

## Developer / Story Owner

- Link or create the target user story
- Build metadata package from story requirements
- Select correct dev org in status panel
- Deploy, commit, and validate in sequence

## Standard Workflow

1. **Open Builder session**
2. **Create/link story**
3. **Build**
   - Confirm artifacts generated as expected
4. **Deploy**
   - Wait for successful deploy job completion
5. **Commit**
   - Commit retrieved metadata from selected dev org
6. **Validate**
   - Run validation against next environment
7. **Deploy to next environment**
   - Promote once validate passes

## Best Practices

- Always confirm selected org/credential before deploy/commit.
- Treat Build artifacts as desired package input; commit retrieves from actual org state.
- Keep function scripts up to date with latest repository version.
- Use explicit component naming conventions to avoid metadata collisions.

## Common Failure Patterns

- **Wrong layout name / localized layout mismatch**
  - Confirm live layout fullName in the target org.
  - Rebuild or update artifacts with authoritative layout name.

- **Commit retrieves wrong or missing components**
  - Verify deploy succeeded first.
  - Verify User Story Metadata selections match actual artifacts.

- **Org Intelligence reads wrong org**
  - Reconnect with the intended Development Org Credential.
  - Confirm integration binding before metadata verification prompts.

## Operational Tips

- Use a dedicated lower environment for repeated setup/upgrade test cycles.
- Document your org-specific job template names and function images.
- Subscribe to discussion/support channels for exchange feedback and updates.

