# Copado Builder — 60-minute demo checklist

## 1. Deploy
1. Deploy `copado-builder-updates-2-code.zip` (includes app **without** Utility Bar).
2. If you previously installed the Utility Bar zip: also deploy `copado-builder-remove-utility-bar.zip` (allow destructive changes).
3. Deploy `copado-builder-updates-4-global-action.zip` — then add **Copado Builder** to **Publisher Layouts** (required for the `+` menu).
4. Hard-refresh.

## 2. Prove basic chat
1. Full app tab **or** global **+** → **Copado Builder**.
2. Send: `Hello`

## 3. Prove Org Intelligence (live Dev metadata)
1. Status panel → Copado Project = **Main - Testing**
2. Environment = **dev1**
3. Integration = **User Level**
4. Click **Connect** if needed
5. Send: `What are the custom fields on the Account object in dev1?`

## Access notes
- **Global Action** is the supported “anywhere” entry (does not require editing Copado managed apps).
- Utility Bar is **not** auto-assigned to the Copado Builder app.
- Messages do not attach integrations; an active Copado connection is enough for OI.

## If something fails
- Global Action not in `+` → Publisher Layouts → add **Copado Builder**.
- Utility Bar still showing → deploy `copado-builder-remove-utility-bar.zip`.
- Global Action issues → deploy `copado-builder-remove-global-action.zip`.
