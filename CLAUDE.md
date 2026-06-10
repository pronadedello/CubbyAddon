# Cubby — project context

Cubby is a **World of Warcraft addon** (Lua, runs inside the WoW client) for
raid-readiness in Classic. It answers two questions: *are my consumables
stocked?* and *are my world buffs up?* See `README.md` for the user-facing
feature tour; this file is for working on the code.

- **Language/runtime:** Lua, executed by the WoW client's addon sandbox. No
  build step, no package manager, no test runner. You cannot run it outside
  the game — "running" means copying the folder into
  `Interface/AddOns/Cubby` and `/reload`-ing in WoW.
- **Current version:** `0.4.0` (see `Cubby.toc`).
- **Multi-flavor:** the `.toc` declares interface numbers for Classic Era
  (`11508`), Cata (`40402`), Mists (`50500`), and Retail (`120001`). Code
  must tolerate all of these — see the API-shim note below.

## Architecture

One shared addon namespace table threaded through every file via the WoW
vararg header `local ADDON_NAME, ns = ...`. Each module hangs a table off
`ns`; there are no other globals except the saved-variable `CubbyDB` and the
slash commands.

Load order is fixed by `Cubby.toc` and matters (later files call into
earlier `ns.*` tables at build time):

| File          | `ns` table   | Responsibility |
|---------------|--------------|----------------|
| `Cubby.lua`   | `ns.Cubby`   | Init, `CubbyDB` defaults, slash commands, **all event wiring** (`OnEvent`), item add/track/resolve logic |
| `Buffs.lua`   | `ns.Buffs`   | World-buff catalog + Chronoboon-aware aura scan |
| `UI.lua`      | `ns.UI`      | Main window: Items/Buffs/Settings tabs, list, add-by-name popup |
| `Tracker.lua` | `ns.Tracker` | Always-on on-screen objective tracker (shortfalls only) |
| `Minimap.lua` | `ns.Minimap` | Minimap button |
| `Restock.lua` | `ns.Restock` | Vendor-side auto-buy on `MERCHANT_SHOW` |
| `Bank.lua`    | `ns.Bank`    | Bank↔bag shuffle queue when the bank is open |
| `Cubby.tga`   | —            | Minimap / addon-list icon |

`Cubby.lua` is the hub: it owns the single `CubbyEventFrame` and dispatches
every game event to the right module. UI modules expose `:Build()` (called
once on `PLAYER_LOGIN`), `:Refresh()` / `:RefreshStatuses()`, and
`:Show()/:Hide()`. When in doubt about what reacts to an event, read the
`OnEvent` handler in `Cubby.lua`.

## Saved variables (`CubbyDB`, per-character)

Schema and defaults live in `defaults()` in `Cubby.lua`; the field-by-field
breakdown is in `README.md` under "Saved vars". Key idea: `items[id]` holds
fully-resolved tracked items, while `pending[lowercaseName]` holds items
added *by name* before the client knew them — they "graduate" to `items[id]`
via `resolvePending()` once the client learns the item (loot, tooltip,
vendor, AH). World buffs are opt-out: every catalog buff is required unless
`buffs.ignored[key]` is set.

## Conventions

- **Cross-flavor API shims.** Container APIs moved from globals
  (`GetContainerItemInfo`, …) to the `C_Container` namespace in newer
  clients. `Bank.lua` and `Restock.lua` wrap each call in a
  `if C_Container and C_Container.X then … else legacyX() end` helper. Add
  new container/merchant calls the same way, never call the bare global.
- **No unicode glyphs (✓, ✗, etc.) in fonts.** The WoW font renders missing
  codepoints as tofu squares. Status checks use inline texture escapes
  (`|TInterface\\RAIDFRAME\\ReadyCheck-Ready:…|t`) instead — see `Tracker.lua`.
- **Status icon vocabulary is shared** between the main list and tracker:
  ✓ = bags meet target, banker icon = bank can cover, auctioneer icon = must
  buy more. `STATUS_TEX` is defined in both `UI.lua` and `Tracker.lua`; keep
  them in sync.
- **Frame/widget pooling.** Lists re-use pooled rows/headers
  (`rowPool`, `headerPool`, etc.) and hide the unused tail on each refresh
  rather than creating/destroying frames. Follow this when adding list UI.
- **Tab button naming is load-bearing.** `PanelTemplates_SetTab` looks tabs
  up by the global-name pattern `<frameName>Tab<id>`. Our frame is
  `CubbyFrame`, so tabs *must* be named `CubbyFrameTab1/2/3` or it errors.

## Gotchas / safety

- **`UseContainerItem` with the bank CLOSED consumes the item** (drinks the
  potion, eats the food). `Bank.lua` guards every move with the
  `Bank.bankOpen` flag and bails immediately in `executeNext()` if the bank
  isn't open. Do **not** weaken this guard.
- WoW silently drops rapid container actions, so `Bank.lua` paces moves on a
  `C_Timer` ticker (`INTERVAL = 0.2s`) and re-validates each slot per tick
  (slots may be locked mid-animation, or already moved).
- The Chronoboon decode in `Buffs.lua` (`scanPlayer`) relies on a fixed
  `UnitBuff` slot mapping (slot 10 = spell id; slots 17–24, 29 carry stored
  buff remaining seconds). This mirrors KerathRaidcheck — see the
  "Attribution" section of `README.md`. Treat the slot table as reference
  data, not something to "clean up".

## Environment

`.devcontainer/` is a generic Claude Code sandbox, unrelated to the addon
itself — don't treat its tooling as project build config.
