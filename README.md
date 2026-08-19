# Copado Builder

Chat-guided Copado user story builder for Salesforce: describe a change, generate metadata with Copado AI, deploy to Dev, commit to the User Story, and promote through the pipeline.

## Install (start here)

**For other people:** give them **`dist/copado-builder-install.zip`**. They unzip it and follow **`INSTALL.md`**.

That kit contains:

- **One** Salesforce deploy zip (`salesforce/copado-builder-mdapi.zip`)
- Copado Function files (`copado-functions/`) for manual setup
- Step-by-step **INSTALL.md** (Salesforce + Copado AI + Function / Job Templates)

Rebuild the shareable kit after code changes:

```bash
./scripts/build-mdapi-zip.sh --with-credentials
./scripts/pack-install-kit.sh
```

**In this repo:** **[INSTALL.md](INSTALL.md)** has the full beginner checklist.

## Packages (quick map)

| Audience | File | When |
|----------|------|------|
| **Installers** | `copado-builder-mdapi.zip` (inside the install kit) | Fresh org — **one** Salesforce deploy |
| Maintainers | `copado-builder-updates-1-schema.zip` | Schema-only upgrades |
| Maintainers | `copado-builder-updates-2-code.zip` | Apex + LWC upgrades |
| Maintainers | `copado-builder-updates-4-global-action.zip` | Global Action (**+** menu) changes |
| Installers + maintainers | `copado-functions/` | Manual Copado Function (required for Deploy/Commit) |

Incremental update zips (safer for orgs that already have Builder):

```bash
./scripts/build-updates-zips.sh
```

## Developer notes

- Source lives under `force-app/main/default/`
- Older deploy notes: [DEPLOY.md](DEPLOY.md)
- Function details: [copado-functions/README.md](copado-functions/README.md)

## DevOps Exchange publishing docs

- Listing draft: [`EXCHANGE-LISTING.md`](EXCHANGE-LISTING.md)
- Setup guide: [`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md)
- Upgrade guide: [`docs/UPGRADE-GUIDE.md`](docs/UPGRADE-GUIDE.md)
- User guide: [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md)
- Submission checklist: [`docs/DEVOPS-EXCHANGE-SUBMISSION-CHECKLIST.md`](docs/DEVOPS-EXCHANGE-SUBMISSION-CHECKLIST.md)
