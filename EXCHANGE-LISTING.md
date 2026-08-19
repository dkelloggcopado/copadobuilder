# Copado Builder — DevOps Exchange Listing Draft

## Listing Basics

- **Solution Name:** Copado Builder
- **Owner / Maintainer:** Daniel Kellogg
- **Repository:** `https://github.com/dkelloggcopado/copadobuilder`
- **Support Model:** Community-supported (Discussion Group + GitHub issues)
- **License:** Add/confirm repository license before submission

## Short Description

Copado Builder helps delivery teams generate, deploy, and commit Salesforce metadata for Copado User Stories with guided AI workflows. It streamlines Build, Deploy, Commit, Validate, and promote-to-next-environment operations from a single app experience.

## Long Description

Copado Builder is a Salesforce extension for teams using Copado DevOps that need faster, safer metadata delivery. The solution provides:

- Story-aware metadata generation
- Guided deployment and commit orchestration
- Validation and next-environment promotion support
- Org-context aware checks and status visibility

The extension is designed for repeatable use across many stories and environments, with clear operational flow for admins and developers.

## Value Proposition

- Reduces manual metadata assembly time
- Improves delivery consistency across stories
- Provides operational guardrails around Build/Deploy/Commit/Validate flow
- Makes extension setup reusable through documented installation and upgrade steps

## Personas

- **Release/Admin persona:** Installs package, configures credentials, templates, and functions
- **Developer persona:** Builds metadata package for a story, deploys to dev org, commits, validates, and promotes

## Included Assets

- Salesforce metadata app (Apex, LWC, custom metadata, objects, permissions)
- Copado function assets under `copado-functions/`
- Packaging scripts and release helpers under `scripts/`
- Setup, upgrade, and usage docs in `docs/`

## Prerequisites (for listing)

- Copado org with required object access
- Salesforce org access for target environments
- Copado AI/API connectivity configured
- Function runtime image that includes Salesforce CLI + `jq`

## Known Constraints

- Exchange consumers must follow setup and upgrade documentation exactly
- Function image/credential setup is mandatory for deploy/commit automation
- Community-supported solution; no Copado official SLA

## Submission Checklist

- [ ] Repo is public and accessible
- [ ] Copado Labs has edit/collaboration access to the repo
- [ ] Setup guide complete and tested in clean org
- [ ] Upgrade guide complete and tested from prior version
- [ ] User guide complete for admin + developer personas
- [ ] Listing text copied into “Submit Your Solution” form
- [ ] Screenshots and optional demo assets prepared

## Suggested Tags / Categories

- Copado Extension
- Salesforce DevOps
- Metadata Automation
- Build and Deploy Automation
- User Story Delivery

