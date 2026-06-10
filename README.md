# Cubby

Raid-readiness for WoW Classic. Two questions:

1. **Are my consumables stocked?** — for every item you want to keep on hand,
   set a target count. Cubby auto-buys at vendors and shuffles bag↔bank to
   keep you topped up. The on-screen tracker shows what's missing.
2. **Are my world buffs up?** — tick the buffs you care about; the tracker
   shows the ones that aren't on you (or are about to expire).

No profiles, no per-spec presets. One number per item, one Ignore checkbox
per buff.

## Use

- `/cubby` or `/cb` — toggle the main window.
- `/cubby tracker` — show the on-screen tracker after you minimized it.
- `/cubby reset` — recenter the main window.

### Items tab

- Drag any item onto the main window, or onto the bottom strip, to track
  it. Default target is 20.
- Click the bottom strip with an empty cursor to add an item **by name** —
  type it, hit Enter. If the client already knows the item, it goes
  straight into the tracker. If not, it lands under "Not yet seen" with a
  `?` icon and resolves automatically the first time you encounter it
  in-game (in a bag, on a tooltip, at a vendor, at the AH).
- Edit the number on a row to change the target. Press Enter to save —
  if you're at the bank, the shuffle re-runs immediately.
- Click the red X on a row to stop tracking.
- Tick **Only missing** to collapse categories and show only items
  where bag count is below target.
- At a vendor, Cubby auto-buys whatever you're short on. Hold Shift to
  skip a single restock.
- At the bank, the window auto-opens and shuffles between bags and bank
  to match your targets. Hold Shift on opening to skip.
- **Refresh** button re-runs the check for whichever window is open.

### Buffs tab

- One row per world buff (Warchief's, Rallying Cry, Zandalar, Songflower,
  Fengus', Mol'dar's, Slip'kik's, DMF). All shown to every class — tick
  **Ignore** on the ones you don't need. The class hint next to each name
  ("physical" / "caster") tells you which are class-specific.
- **Required duration** is the % of each buff's max duration below which
  it counts as "about to expire" (defaults to 90%). A buff in that window
  shows up on the tracker as `Buff name (Nm)`.
- Chronoboon-stored buffs count as having the buff.
- Hover any row's icon for the spell tooltip.

### Tracker (on-screen)

- Sits on the right edge of the screen by default; drag to move,
  Settings tab to lock or hide.
- Two top-level sections — **Buffs** and **Items** (with item categories
  as sub-headers).
- Click anywhere to open the main window.
- "−" button in the top-right hides the tracker for this session only.
  Reload or login brings it back. To hide permanently, untick "Show
  tracker" in Settings.

### Settings tab

- Show tracker on screen — persistent on/off.
- Lock tracker position — disables dragging.

### Status icons (Items tab + tracker rows)

- ✓ green check — bags meet target.
- 🏦 banker icon — bags short, but bank can cover.
- ⚖ auctioneer icon — even bank can't cover; buy more.

## Files

```
Cubby.toc       — addon manifest
Cubby.lua       — init, saved vars, slash commands, event wiring
Buffs.lua       — world-buff catalog + chronoboon-aware aura scan
UI.lua          — main window: tabs, list, add-by-name popup, settings
Tracker.lua     — on-screen objective tracker
Minimap.lua     — minimap button
Restock.lua     — vendor-side auto-buy
Bank.lua        — bank↔bag shuffle queue
Cubby.tga       — minimap + addon-list icon
```

## Saved vars (`CubbyDB`, per-character)

- `items[itemId] = { id, name, icon, itemType, subType, quality, target }`
- `pending[lowercaseName] = { name, target }` — items added by name
  before the client knew them; graduate to `items[id]` when discovered
- `framePos = { point, x, y }` — main window position
- `tracker = { shown, locked, point, x, y }` — tracker state + position
- `buffs = { ignored = { [key] = true }, durationPct = 90 }`
- `mmAngle` — minimap button angle in radians
- `defaultTarget` — default target when adding a new item (20)
- `collapsed[groupLabel] = true` — collapsed category groups
- `showOnlyMissing` — "Only missing" filter state

## Attribution

The world-buff catalog and Chronoboon Displacer decode logic are
adapted from
[JustAPoint](https://github.com/JustAPointwow/addon)'s `Buffs.lua`,
which in turn mirrors
[KerathRaidcheck](https://www.curseforge.com/wow/addons/kerathraidcheck).
