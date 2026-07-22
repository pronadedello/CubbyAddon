local _, ns = ...

ns.Buffs = {}
local Buffs = ns.Buffs

-- World-buff readiness. Catalog and Chronoboon Displacer decode logic
-- are adapted from JustAPoint's classic_world_buffs template, which
-- itself mirrors KerathRaidcheck. See README.md "Attribution" for the
-- upstream sources. Bundled as code rather than fetched at runtime —
-- the list is stable across patches.
--
-- Semantics:
--   * default: every catalog buff is required
--   * user ticks a buff in the Buffs tab to mark it "I don't need this"
--   * a required buff that is missing or short shows in the tracker
--   * "short" threshold = durationPct % of the buff's max duration
--     (default 90%, configurable on the Buffs tab)
--   * chronoboon-stored buffs count as having the buff (lenient mode)

local CHRONOBOON_SPELL_ID = 349981

-- When the aura at index i has spellId = CHRONOBOON_SPELL_ID, the buff's
-- SPELL_AURA_APPLIED points array carries the remaining seconds of each
-- stored world buff. Our flattener (unpackAuraData below) unpacks that
-- points array starting at position 16 of the tuple, so points[N] shows
-- up at buf[15+N]. Empirically-verified layout — the Wowpedia UnitAura
-- table says these live at positions 17..24, but a live capture on
-- current clients puts Fengus at points[1] (buf[16]), not points[2],
-- so the whole table is one position earlier than the wiki claims.
-- Values are in seconds; 0 = "not stored".
local BOON_SLOT_TO_SPELL_ID = {
  [16] = 22817,  -- Fengus' Ferocity
  [17] = 22818,  -- Mol'dar's Moxie
  [18] = 22820,  -- Slip'kik's Savvy
  [19] = 22888,  -- Rallying Cry of the Dragonslayer
  [20] = 16609,  -- Warchief's Blessing (Horde)
  [21] = 24425,  -- Spirit of Zandalar
  [22] = 15366,  -- Songflower Serenade
  [23] = 23768,  -- Sayge's / DMF
}

local CLASS_CATEGORY = {
  WARRIOR = 'physical', ROGUE = 'physical', HUNTER = 'physical',
  PRIEST  = 'caster',   MAGE  = 'caster',   WARLOCK = 'caster',
  DRUID   = 'caster',   PALADIN = 'caster', SHAMAN  = 'caster',
}

-- max_duration_minutes is the in-game cap; the "short" threshold is
-- max * durationPct/100. JustAPoint hard-codes a tuned floor per buff
-- (required_duration_minutes) — we make it a single percentage so the
-- user has one knob.
--
-- Flask and Zanza/Blasted Lands buffs are intentionally absent. Both come
-- from consumables that the user tracks in the Items tab (a Flask of the
-- Titans bottle, a Zanza vial); the buff is a downstream effect of having
-- the item, not a separate raid-prep concern. Tracking them in both places
-- would be redundant.
ns.BUFF_CATALOG = {
  { key='WCB',  name="Warchief's Blessing",              short='WCB', classes='all',      max_duration_minutes=60,  spell_ids={ 16609, 460939, 355366 } },
  { key='Ony',  name='Rallying Cry of the Dragonslayer', short='Ony', classes='all',      max_duration_minutes=120, spell_ids={ 22888, 355363 } },
  { key='HoH',  name='Spirit of Zandalar',               short='HoH', classes='all',      max_duration_minutes=120, spell_ids={ 24425, 355365 } },
  { key='SF',   name='Songflower Serenade',              short='SF',  classes='all',      max_duration_minutes=60,  spell_ids={ 15366 } },
  { key='Fer',  name="Fengus' Ferocity",                 short='Fer', classes='physical', max_duration_minutes=120, spell_ids={ 22817 } },
  { key='Mox',  name="Mol'dar's Moxie",                  short='Mox', classes='all',      max_duration_minutes=120, spell_ids={ 22818 } },
  { key='Sav',  name="Slip'kik's Savvy",                 short='Sav', classes='caster',   max_duration_minutes=120, spell_ids={ 22820 } },
  { key='DMF',  name='Darkmoon Faire',                   short='DMF', classes='all',      max_duration_minutes=120, spell_ids={ 23768, 23736, 23766, 23738, 23737, 23735, 23767, 23769 } },
}

local function db()
  CubbyDB.buffs              = CubbyDB.buffs or {}
  CubbyDB.buffs.ignored      = CubbyDB.buffs.ignored or {}
  CubbyDB.buffs.durationPct  = CubbyDB.buffs.durationPct or 90
  return CubbyDB.buffs
end

function Buffs:GetCatalog()      return ns.BUFF_CATALOG end
function Buffs:GetDurationPct()  return db().durationPct or 90 end
function Buffs:IsIgnored(key)    return db().ignored[key] == true end

function Buffs:SetIgnored(key, ignored)
  db().ignored[key] = ignored and true or nil
end

function Buffs:SetDurationPct(pct)
  db().durationPct = math.max(1, math.min(100, math.floor(tonumber(pct) or 90)))
end

-- Every buff in the catalog is shown to every class. The `classes` field
-- is now purely informational — the Buffs tab labels physical/caster-only
-- buffs so the player knows which to mark "Ignore". This makes the addon
-- work for any class without having to import a per-class default set,
-- and keeps the user in control of what's required.
function Buffs:IsApplicable(_buff)
  return true
end

-- Class hint shown next to the buff name in the config tab. Returns the
-- raw category string ('physical'/'caster') or nil for buffs that apply
-- to everyone.
function Buffs:ClassHint(buff)
  if not buff.classes or buff.classes == 'all' then return nil end
  return buff.classes
end

-- GetSpellTexture moved to C_Spell in Retail 11.0.0. The C_Spell version
-- returns (iconID, originalIconID, ...) — we only want the first. The
-- global still exists on older Classic flavors.
local function spellTexture(sid)
  if C_Spell and C_Spell.GetSpellTexture then
    return (C_Spell.GetSpellTexture(sid))
  end
  if GetSpellTexture then return GetSpellTexture(sid) end
end

function Buffs:IconFor(buff)
  for _, sid in ipairs(buff.spell_ids) do
    local tex = spellTexture(sid)
    if tex then return tex end
  end
  return 'Interface\\Icons\\INV_Misc_QuestionMark'
end

-- UnitBuff was removed in Retail 11.0.2 (2024-08-13) and truncated on the
-- newer Classic flavors — the vararg tail that carried Chronoboon's stored
-- seconds is no longer returned. Replacement is
-- C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL"), which returns an
-- AuraData struct. We flatten it ourselves rather than lean on
-- AuraUtil.UnpackAuraData — that helper isn't present on every flavor, and
-- if it's missing we'd silently fall back to the truncated UnitBuff and
-- lose the Chronoboon points. Layout mirrors the old UnitBuff tuple so
-- buf[10]/buf[6]/buf[17..24]/buf[29] stay valid without touching the
-- Chronoboon slot table.
local function unpackAuraData(a)
  if not a then return nil end
  return a.name, a.icon, a.applications, a.dispelName, a.duration,
         a.expirationTime, a.sourceUnit, a.isStealable,
         a.nameplateShowPersonal, a.spellId, a.canApplyAura, a.isBossAura,
         a.isFromPlayerOrPlayerPet, a.nameplateShowAll, a.timeMod,
         unpack(a.points or {})
end

local function getBuff(unit, i)
  if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
    return unpackAuraData(C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL"))
  end
  if UnitBuff then return UnitBuff(unit, i) end
end

-- Debug snapshot: which aura API is active, what does the Chronoboon aura
-- currently contain, and what does Cubby's slot mapping think each
-- position holds. Returns a big multi-line string suitable for pasting.
-- UI:ShowBuffLog() renders it in a copyable window; the caller can also
-- print it to chat line-by-line if that's more convenient.
--
-- Reads the raw AuraData.points array directly (bypassing our flattener)
-- so a mismatch between "what points[N] actually holds" and "what Cubby
-- reads at buf[15+N]" is visible in one glance.
function Buffs:DebugDump()
  local out = {}
  local function w(s) out[#out+1] = s or "" end

  local stamp = _G and _G.CubbyBuildStamp
  if not stamp and ns and ns.BUILD_STAMP then stamp = ns.BUILD_STAMP end
  w("=== Cubby buff debug" .. (stamp and (" — build " .. stamp) or "") .. " ===")
  w("")
  w("API detection:")
  w(string.format("  C_UnitAuras.GetAuraDataByIndex = %s",
    tostring(C_UnitAuras and C_UnitAuras.GetAuraDataByIndex ~= nil)))
  w(string.format("  AuraUtil.UnpackAuraData        = %s",
    tostring(AuraUtil and AuraUtil.UnpackAuraData ~= nil)))
  w(string.format("  UnitBuff (legacy)              = %s",
    tostring(UnitBuff ~= nil)))

  local class = select(2, UnitClass('player')) or "?"
  local name = UnitName('player') or "?"
  w(string.format("Player: %s (%s)", name, class))
  w("")

  -- Locate Chronoboon among player buffs.
  local boonIdx, boonBuf, boonRaw
  for i = 1, 40 do
    local buf = { getBuff('player', i) }
    local spellId = buf[10]
    if not spellId then break end
    if spellId == CHRONOBOON_SPELL_ID then
      boonIdx = i
      boonBuf = buf
      if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        boonRaw = C_UnitAuras.GetAuraDataByIndex('player', i, "HELPFUL")
      end
      break
    end
  end

  if not boonIdx then
    w("Chronoboon aura: NOT FOUND on player.")
    w("(pop the Chronoboon Displacer, then reopen this window.)")
  else
    w(string.format("Chronoboon aura: found at slot %d (spellId %d).",
      boonIdx, CHRONOBOON_SPELL_ID))
    w("")

    if boonRaw then
      local pts = boonRaw.points or {}
      w(string.format("Raw AuraData.points (%d entries):", #pts))
      for j = 1, #pts do
        w(string.format("  points[%2d] = %s", j, tostring(pts[j])))
      end
    else
      w("(no direct AuraData access — running the UnitBuff fallback path.)")
    end
    w("")

    w("Flattened tuple positions 16..30 (Cubby's buf[N]):")
    for slot = 16, 30 do
      local v = boonBuf[slot]
      if v ~= nil then
        w(string.format("  buf[%2d] = %s", slot, tostring(v)))
      end
    end
    w("")

    w("Cubby's slot map — [pos] = spellId  → expected name — value now at buf[pos]:")
    -- Iterate slot keys in numeric order for readable output.
    local keys = {}
    for k in pairs(BOON_SLOT_TO_SPELL_ID) do keys[#keys+1] = k end
    table.sort(keys)
    local nameBySpell = {}
    for _, b in ipairs(ns.BUFF_CATALOG) do
      for _, sid in ipairs(b.spell_ids) do nameBySpell[sid] = b.name end
    end
    for _, slot in ipairs(keys) do
      local sid = BOON_SLOT_TO_SPELL_ID[slot]
      local nm  = nameBySpell[sid] or "?"
      local v   = boonBuf[slot]
      w(string.format("  [%2d] = %-7d → %-35s value=%s",
        slot, sid, nm, tostring(v)))
    end
  end
  w("")

  w("Current Buffs:Status() output:")
  for _, r in ipairs(self:Status()) do
    local remain = r.remain and string.format("%.1fm", r.remain) or "-"
    w(string.format("  %-32s %-8s remain=%s",
      r.buff.name, r.state, remain))
  end

  return table.concat(out, "\n")
end

-- Walk the player's auras once, returning { active = {[sid]=remainMin},
-- stored = {[sid]=remainMin} } where `stored` is populated only when a
-- chronoboon is active. Lenient mode: callers may consume either map.
local function scanPlayer()
  local active, stored = {}, {}
  for i = 1, 40 do
    local buf = { getBuff('player', i) }
    local spellId = buf[10]
    if not spellId then break end
    if spellId == CHRONOBOON_SPELL_ID then
      for slot = 16, 23 do
        local secs = buf[slot]
        if secs and secs > 0 then
          local sid = BOON_SLOT_TO_SPELL_ID[slot]
          if sid then stored[sid] = secs / 60 end
        end
      end
    else
      local exp = buf[6]
      local remainMin
      if exp and exp > 0 then remainMin = (exp - GetTime()) / 60
      else                    remainMin = 9999  -- permanent / unknown
      end
      active[spellId] = remainMin
    end
  end
  return active, stored
end

-- For every applicable, non-ignored buff: classify as ok / short / missing.
-- short = present but remaining < durationPct% of max duration.
-- Returns a sorted list (catalog order) of { buff, state, remainMin }.
function Buffs:Status()
  local thresholdPct = (db().durationPct or 90) / 100
  local active, stored = scanPlayer()
  local out = {}
  for _, buff in ipairs(ns.BUFF_CATALOG) do
    if self:IsApplicable(buff) and not self:IsIgnored(buff.key) then
      local threshold = (buff.max_duration_minutes or 60) * thresholdPct
      local remain
      for _, sid in ipairs(buff.spell_ids) do
        if active[sid] then remain = active[sid]; break end
        if stored[sid] and not remain then remain = stored[sid] end
      end
      local state
      if not remain                  then state = 'missing'
      elseif remain < threshold      then state = 'short'
      else                                state = 'ok'
      end
      table.insert(out, { buff = buff, state = state, remain = remain })
    end
  end
  return out
end

function Buffs:Missing()
  local out = {}
  for _, r in ipairs(self:Status()) do
    if r.state == 'missing' or r.state == 'short' then
      table.insert(out, r)
    end
  end
  return out
end
