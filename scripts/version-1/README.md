# Copado Builder — Version 1

Self-contained install kit for the **current working** Copado Builder experience:

**Chat → Create / Link User Story → Build (AI package) → Commit (deploy package to Dev, then Copado commit to the story)**

This freeze is **Version 1** (combined Deploy-Then-Commit). Later versions may split Deploy and Commit into separate buttons.

## What’s in this kit

| Path | Purpose |
|------|---------|
| **INSTALL.md** | **Start here** — every deploy and manual setup step |
| `salesforce/copado-builder-v1-mdapi.zip` | Full Salesforce Metadata API package (`package.xml` at zip root) |
| `copado-functions/` | Function script + Job Template instructions (not deployable via MDAPI) |

## Quick start

1. Read and follow **[INSTALL.md](INSTALL.md)** in order.
2. Do not skip the Copado Function / Job Template section — Commit will not work without it.
3. After install, leave **Use Mock API** checked for a smoke test, then switch to live Copado AI.

## Requirements

- Salesforce org with **Copado CI/CD** (Deployer) installed
- Copado AI organization access (Personal Access Key)
- At least one **validated** Dev Org Credential on a Copado Project pipeline
