# RLS Career Cheat Menu

A BeamNG.drive UI app that adds a cheat menu for [RLS Career Overhaul](https://github.com/RLS-Modding/rls_career_overhaul).

Written against RLS Career Overhaul **v2.8.x** on **BeamNG.drive 0.40**. RLS must be installed and enabled.

## Features

| Tab | Cheats |
| --- | --- |
| **Money** | Add +1K / +10K / +100K / +1M, add, remove or set an exact amount. Add BeamXP and vouchers. Clear all active loans (asks you to click twice). |
| **Skills** | Every RLS skill with its level: −1, +1, Max, Reset, plus **Max all skills**. |
| **Rep** | Set each organization's reputation (−10, +10, Max, Zero), **Max all organizations**, and max your car meet reputation. |
| **Vehicle** | Free instant repair of the owned car you are driving, refuel/recharge, reset RLS maintenance wear and tires, end a police pursuit, and set the insurance driver score. |
| **World** | Set the time of day (dawn, noon, dusk or midnight) and force a career save. |

Every change goes through RLS's own systems (the money ledger, attributes, the insurance and loan modules), so it shows up in the Wallet and history as **"Cheat Menu"** and is saved with your career.

## Install

1. Download `rls_cheat_menu.zip` from Releases, or build it with `./build.sh`.
2. Put the zip in your BeamNG user folder under `mods/` (Launcher → Manage User Folder → Open in Explorer). Leave it zipped.
3. Start the game, load an RLS career, open the UI Apps editor (**Esc → UI Apps**, or Ctrl+U by default), click **Add app** and pick **RLS Cheat Menu**.

## How it works

- `lua/ge/extensions/rlsCheatMenu.lua` is a game-engine Lua extension. It calls RLS modules such as `overhaul_career_economy_playerAttributes`, `overhaul_career_progression_skills`, `overhaul_career_repair_insurance`, `overhaul_career_economy_loans` and `overhaul_integration_services_police`. It looks every module up lazily and runs every action in `pcall`, so a mismatch shows an error toast instead of breaking the game.
- `scripts/rls_cheat_menu/modScript.lua` loads that extension when the mod is mounted.
- `ui/modules/apps/RLSCheatMenu/` is the Angular UI app. It sends commands with `bngApi.engineLua` and receives state on the `RLSCheatMenuState` hook.

## Notes

- If the career was started in **Freeroam+**, RLS's own cheats mode keeps money pinned at $1T.
- Free repair only works on vehicles you own. In any other vehicle it does a plain physics reset.
- RLS's weather system may move the clock on after you set the time.
- Back up your save before using cheats.
