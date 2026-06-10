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

-- When slot 10 of UnitBuff('player', i) equals the chronoboon spell ID,
-- the same row's slots 17..24 and 29 carry the remaining seconds of each
-- stored buff. Mapping is KRC's reference.
local BOON_SLOT_TO_SPELL_ID = {
  [17] = 22817,  -- Fengus' Ferocity
  [18] = 22818,  -- Mol'dar's Moxie
  [19] = 22820,  -- Slip'kik's Savvy
  [20] = 22888,  -- Rallying Cry of the Dragonslayer
  [21] = 16609,  -- Warchief's Blessing (Horde)
  [22] = 24425,  -- Spirit of Zandalar
  [23] = 15366,  -- Songflower Serenade
  [24] = 23768,  -- Sayge's / DMF
  [29] = 460939, -- Warchief's Blessing (Alliance)
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

function Buffs:IconFor(buff)
  if GetSpellTexture then
    for _, sid in ipairs(buff.spell_ids) do
      local tex = GetSpellTexture(sid)
      if tex then return tex end
    end
  end
  return 'Interface\\Icons\\INV_Misc_QuestionMark'
end

-- Walk the player's auras once, returning { active = {[sid]=remainMin},
-- stored = {[sid]=remainMin} } where `stored` is populated only when a
-- chronoboon is active. Lenient mode: callers may consume either map.
local function scanPlayer()
  local active, stored = {}, {}
  for i = 1, 40 do
    local buf = { UnitBuff('player', i) }
    local spellId = buf[10]
    if not spellId then break end
    if spellId == CHRONOBOON_SPELL_ID then
      for slot = 17, 24 do
        local secs = buf[slot]
        if secs and secs > 0 then
          local sid = BOON_SLOT_TO_SPELL_ID[slot]
          if sid then stored[sid] = secs / 60 end
        end
      end
      local secs29 = buf[29]
      if secs29 and secs29 > 0 then
        local sid = BOON_SLOT_TO_SPELL_ID[29]
        if sid then stored[sid] = secs29 / 60 end
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
