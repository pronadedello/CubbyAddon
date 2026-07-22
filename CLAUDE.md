# Cubby — project context

Cubby is a **World of Warcraft addon** (Lua, runs inside the WoW client) for
raid-readiness in Classic. It answers two questions: *are my consumables
stocked?* and *are my world buffs up?* See `README.md` for the user-facing
feature tour; this file is for working on the code.

- **Language/runtime:** Lua, executed by the WoW client's addon sandbox. No
  build step *for the runtime* (the Lua/`.toc` files drop into
  `Interface/AddOns/Cubby` as-is), no package manager, no test runner. You
  cannot execute the code outside the game — "running" is `/reload` in WoW.
  There *is* release + live-installer tooling (see "Release + live installer"
  below) — that's separate from what WoW loads.
- **Current version:** `1.0.7` (see `Cubby.toc`).
- **Multi-flavor:** the `.toc` declares interface numbers for Classic Era
  (`11508`), Cata (`40402`), Mists (`50500`), and Retail (`120001`). Code
  must tolerate all of these — see the API-shim note below.

## Architecture

One shared addon namespace table threaded through every file via the WoW
vararg header `local ADDON_NAME, ns = ...`. Each module hangs a table off
`ns`; there are no other globals except the saved-variable `CubbyDB` and the
slash commands.

Load order is fixed by `Cubby.toc` and matters (later files call into
earlier `ns.*` tables at build time). Files WoW loads:

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

Dev/release tooling (not loaded by WoW, stripped from the release zip via
`.pkgmeta`):

| File / dir | Role |
|------------|------|
| `gen_manifest.py`               | Regenerates `manifest.json` — SHA-256 per shipped file plus a `<toc-version>-<utc-timestamp>` version string. Re-run after any Lua/`.toc` edit. |
| `manifest.json`                 | Consumed by `install.ps1` to hash-diff files. Regenerated, not hand-edited. |
| `server.sh`                     | `python3 -m http.server` on `:8090` (override with `$CUBBY_PORT`), pidfile in `.run/`. `start`/`stop`/`restart`/`status`. |
| `install.ps1`                   | Windows-side polling installer. `iwr <BaseUrl>/install.ps1 \| iex`. Mirrors changed files into `Interface/AddOns/Cubby/`. |
| `build.sh <out-dir>`            | Stages the runtime files into a `Cubby/`-rooted zip named `Cubby-<version>.zip`. Whitelist mirrors `.pkgmeta`. |
| `.pkgmeta`                      | BigWigs-packager config; ignore list keeps installer/dev tooling out of the release zip. |
| `.github/workflows/release.yml` | Fires on `v*.*.*` tags: verifies tag matches TOC Version, runs `build.sh`, attaches to a GitHub Release, uploads to CurseForge if `vars.CF_PROJECT_ID` is set. |
| `Cubby-256.png`, `Cubby-512.png`, `Cubby.png` | Store/README artwork. Not the in-game icon (that's `Cubby.tga`). |
| `.run/`                         | Runtime state for `server.sh` — `server.pid`, `server.log`. Never commit. |

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

- **Cross-flavor API shims.** Blizzard has been moving globals into
  namespaces (`C_Container`, `C_UnitAuras`, `C_Spell`, `C_MerchantFrame`).
  Wrap every callsite in a `if C_X and C_X.Foo then … else legacyFoo() end`
  helper — never call the bare global. Current shims:
  - `Bank.lua` — container APIs (`C_Container.*`).
  - `Restock.lua` — `C_MerchantFrame.GetItemInfo` (only that one migrated;
    `GetMerchantNumItems`/`GetMerchantItemLink`/`BuyMerchantItem` are still
    globals with no modern replacement).
  - `Buffs.lua` — `getBuff` flattens `C_UnitAuras.GetAuraDataByIndex`'s
    AuraData struct into the legacy `UnitBuff` positional tuple (we do
    the flattening ourselves rather than lean on `AuraUtil.UnpackAuraData`
    — that helper isn't present on every flavor, and falling back to
    truncated `UnitBuff` would drop the Chronoboon points). `spellTexture`
    prefers `C_Spell.GetSpellTexture`. The Chronoboon slot table
    (`BOON_SLOT_TO_SPELL_ID`, positions 16..23) indexes into the flattened
    tuple; `points[N]` lands at position `15+N`. If the decode ever
    misbehaves, open **Cubby → Settings → Buff debug** for a live snapshot
    of the raw points array vs. the current mapping — that's what caught
    an off-by-one against Wowpedia's positioning claim.
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
  slot mapping (slot 10 = spell id; slots 16–23 carry stored buff remaining
  seconds). The mapping's ordering (Fengus, Mol'dar, Slip'kik, Ony, WCB,
  Zandalar, Songflower, DMF) mirrors KerathRaidcheck — see the
  "Attribution" section of `README.md`. Treat the slot table as reference
  data, not something to "clean up". If someone updates the wiki to claim
  Wowpedia's numbering (17..24), don't switch — a live capture on current
  clients definitively places Fengus at `points[1]`, i.e. `buf[16]`.

## Release + live installer

Two flows share the same file list; they diverge in delivery.

**Live installer (dev-time hot reload).** Edit Lua → `python3 gen_manifest.py`
→ the developer's `install.ps1` polling loop hashes the new `manifest.json`,
downloads changed files into `Interface/AddOns/Cubby/`, developer runs
`/reload` in WoW. `server.sh` (this repo) serves the raw files over
`http://:8090`; a Caddy vhost at `staging.justapoint.org/addons/cubby/*`
reverse-proxies to it, so the ps1 talks HTTPS to Caddy and never touches
this box directly. If `install.ps1` gets a 502, Caddy is up and `server.sh`
isn't — `./server.sh status` then `./server.sh start`. **After every edit,
regenerate the manifest** — the poller gates downloads on hash, so a stale
manifest just means the change never ships.

**Release (production, CurseForge + GitHub).** Bump `## Version:` in
`Cubby.toc`, commit, tag `vX.Y.Z`, push with `--follow-tags`. The workflow
verifies the tag matches the TOC version, runs `build.sh` to zip the
runtime files (top-level `Cubby/` entry), attaches the zip to a GitHub
Release, and uploads to CurseForge for every game-version whose name starts
with the Interface-derived prefix (e.g. Interface `11508` → `1.15.*`). A
`-suffix` in the version (`v2.0.0-beta.1`) flips both `prerelease=true` and
CurseForge `releaseType=beta`. No `manifest.json`, `install.ps1`, or
`server.sh` in the shipped zip — `.pkgmeta` ignores them.

## Environment

`.devcontainer/` is a generic Claude Code sandbox, unrelated to the addon
itself — don't treat its tooling as project build config.
