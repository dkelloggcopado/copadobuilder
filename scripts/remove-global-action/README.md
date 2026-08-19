# Remove Copado Builder Global Action

1. Remove **Copado Builder** from Publisher Layouts (so users stop seeing it).
2. Deploy `copado-builder-remove-global-action.zip` with destructive changes allowed.

Deletes:
- QuickAction `Copado_Builder`
- Aura bundle `copadoBuilderGlobalAction`

Does **not** remove the Copado Builder app/tab, LWC, or Utility Bar.
