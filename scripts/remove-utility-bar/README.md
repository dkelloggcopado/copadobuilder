# Remove Copado Builder Utility Bar

Use this if a Utility Bar was previously auto-assigned to the Copado Builder app.
Prefer **Global Action** going forward.

## Deploy (Workbench or `sf`)

1. Upload / deploy **`copado-builder-remove-utility-bar.zip`**
2. Workbench: check **Allow Deployments that contain destructive changes**
3. Hard-refresh

This zip:
1. Redeploys `Copado_Builder` **without** a utility bar
2. **Deletes** FlexiPage `Copado_Builder_Utility_Bar`

## Manual fallback

App Manager → Copado Builder → Edit → Utility Items → remove **Copado Builder** → Save.

## What stays

- Copado Builder tab / app page
- Global Action (if installed)
- LWC + Apex
