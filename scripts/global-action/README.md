# Copado Builder Global Action

Opens Copado Builder from the Lightning Experience **global +** menu on any page — without changing Copado managed-package utility items.

## Why Aura?
Salesforce LWC `lightning__GlobalAction` is **Field Service mobile only**. Desktop LEX global actions require an Aura Quick Action host. This Aura component only wraps `c:copadoBuilderChat`.

## Deploy
1. Deploy `copado-builder-updates-2-code.zip` (includes Aura + LWC if rebuilt together), **or**
2. Deploy `copado-builder-updates-4-global-action.zip`

## One-time Setup (required)
1. Setup → **Publisher Layouts** (or Global Actions → Publisher Layouts)
2. Edit the layout used by your users (often **Global Layout**)
3. In **Salesforce Mobile and Lightning Experience Actions**, add **Copado Builder**
4. Save

Until it is on the publisher layout, the action exists but will not show in `+`.

## Rollback
Deploy `copado-builder-remove-global-action.zip` with destructive changes allowed.
Or: Publisher Layouts → remove the action, then delete Global Action **Copado Builder** in Setup.
