local ADDON_NAME, ns = ...

local DEFAULT_TARGET = 20

ns.Cubby = {}
local Cubby = ns.Cubby

local frame = CreateFrame("Frame", "CubbyEventFrame")

local function defaults()
  CubbyDB = CubbyDB or {}
  CubbyDB.items = CubbyDB.items or {}
  -- Pending entries added by name before the client knew the item.
  -- Keyed by lowercased name. Each value: { name = (as-typed), target = N }.
  CubbyDB.pending = CubbyDB.pending or {}
  CubbyDB.framePos = CubbyDB.framePos or { point = "CENTER", x = 0, y = 0 }
  CubbyDB.defaultTarget = CubbyDB.defaultTarget or DEFAULT_TARGET
  -- Always-on objective-tracker panel. Default: visible, unlocked, no saved
  -- position (defaults to right-edge centered). `shown == false` hides it.
  CubbyDB.tracker = CubbyDB.tracker or { shown = true, locked = false }
  -- Buff readiness. ignored[key] = true marks a buff as "I don't need this";
  -- everything else is required. durationPct is the "short" threshold as a
  -- percentage of each buff's max duration.
  CubbyDB.buffs = CubbyDB.buffs or { ignored = {}, durationPct = 90 }
  -- Bank auto-shuffle. `disabled` is the user-facing kill switch — when true
  -- the Bank module never plans or executes any move (escape hatch when the
  -- shuffle misbehaves at the bank). `debug` makes it print every decision
  -- to chat so the user (and us) can see what it's trying to do.
  -- `intervalMs` is the pace between container actions: higher = more time
  -- for the client/server to reconcile state between moves (fewer
  -- "Couldn't split" rejections) at the cost of slower bank visits.
  CubbyDB.bank = CubbyDB.bank or { disabled = false, debug = false, intervalMs = 500 }
  -- Backfill the new field for users on a pre-0.4.13 saved-vars file.
  if CubbyDB.bank.intervalMs == nil then CubbyDB.bank.intervalMs = 500 end
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function extractItemId(idOrLink)
  local n = tonumber(idOrLink)
  if n then return n end
  if type(idOrLink) == "string" then
    return tonumber(idOrLink:match("item:(%d+)"))
  end
end

function Cubby:Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff8d63ffCubby|r: " .. tostring(msg))
end

function Cubby:AddItem(idOrLink)
  local id = extractItemId(idOrLink)
  if not id then return end
  if CubbyDB.items[id] then return end

  local name, _, quality, _, _, itemType, subType, _, _, icon = GetItemInfo(id)
  CubbyDB.items[id] = {
    id = id,
    name = name,
    icon = icon,
    itemType = itemType,
    subType = subType,
    quality = quality,
    target = CubbyDB.defaultTarget or DEFAULT_TARGET,
  }
  ns.UI:Refresh()
end

function Cubby:SetTarget(id, n)
  local item = CubbyDB.items[id]
  if not item then return end
  item.target = math.max(0, math.floor(tonumber(n) or 0))
end

function Cubby:RemoveItem(id)
  CubbyDB.items[id] = nil
  ns.UI:Refresh()
end

-- Try to add an item by name. Returns (true, "added") if the client knows
-- the name (cache hit) and we stored a real entry; (false, "pending") if
-- we stored a name-only entry to be resolved later; (false, "duplicate")
-- if the item is already tracked or pending.
function Cubby:AddItemByName(rawName)
  local display = trim(rawName)
  if display == "" then return false, "empty" end
  local key = display:lower()

  -- If we can extract an item id from a hyperlink, prefer that path.
  local linkId = extractItemId(rawName)
  if linkId then
    if CubbyDB.items[linkId] then return false, "duplicate" end
    self:AddItem(rawName)
    return true, "added"
  end

  -- GetItemInfo accepts a name and returns the link if the client has the
  -- item cached. The fields we care about are name (1) and link (2).
  local name, link = GetItemInfo(display)
  if link then
    local id = extractItemId(link)
    if id then
      if CubbyDB.items[id] then return false, "duplicate" end
      self:AddItem(id)
      -- Preserve the user-set target if they had a pending entry under
      -- this name; then drop the pending entry.
      if CubbyDB.pending[key] then
        CubbyDB.items[id].target = CubbyDB.pending[key].target or CubbyDB.items[id].target
        CubbyDB.pending[key] = nil
      end
      return true, "added"
    end
  end

  -- Already pending under this name, or already tracked as a real item
  -- whose name matches? Treat as duplicate.
  if CubbyDB.pending[key] then return false, "duplicate" end
  for _, item in pairs(CubbyDB.items) do
    if item.name and item.name:lower() == key then return false, "duplicate" end
  end

  CubbyDB.pending[key] = {
    name   = display,
    target = CubbyDB.defaultTarget or DEFAULT_TARGET,
  }
  ns.UI:Refresh()
  return false, "pending"
end

function Cubby:SetPendingTarget(key, n)
  local p = CubbyDB.pending[key]
  if not p then return end
  p.target = math.max(0, math.floor(tonumber(n) or 0))
end

function Cubby:RemovePending(key)
  CubbyDB.pending[key] = nil
  ns.UI:Refresh()
end

-- Walk every pending entry and try to resolve it against the client's
-- item cache. If GetItemInfo now knows the name, graduate it to a real
-- tracked item (with the same target the user picked) and drop it from
-- the pending table. Called from the event hooks below — bag updates,
-- bank updates, GET_ITEM_INFO_RECEIVED, merchant show — so any time
-- the client may have learned new names, we re-check.
local function resolvePending()
  if not CubbyDB or not CubbyDB.pending then return end
  local changed = false
  for key, entry in pairs(CubbyDB.pending) do
    local _, link = GetItemInfo(entry.name)
    local id = link and extractItemId(link)
    if id then
      if not CubbyDB.items[id] then
        local name, _, quality, _, _, itemType, subType, _, _, icon = GetItemInfo(id)
        CubbyDB.items[id] = {
          id = id,
          name = name,
          icon = icon,
          itemType = itemType,
          subType = subType,
          quality = quality,
          target = entry.target,
        }
      end
      CubbyDB.pending[key] = nil
      changed = true
    end
  end
  if changed and ns.UI then ns.UI:Refresh() end
end

-- Centralised group label so the sort and the renderer can't drift.
-- Armor/Weapon collapse to "Equipment" (Cloth/Leather/Plate/Daggers/etc are too
-- granular to be useful). Everything else uses Blizzard's itemSubType when
-- available — that gives Potion / Flask / Elixir / Bandage / Food & Drink /
-- Cloth (trade good) / Herb / Metal & Stone / etc.
function Cubby:GroupOf(item)
  -- "Not yet seen" = added by name but the game client hasn't shown this
  -- character the item yet, so we don't know its icon/type/counts. Resolves
  -- automatically the first time the player encounters the item.
  if item.pending then return "Not yet seen" end
  if not item.name then return "Loading…" end
  local t = item.itemType
  if t == "Armor" or t == "Weapon" then return "Equipment" end
  return item.subType or t or "Other"
end

function Cubby:Items()
  local list = {}
  for _, item in pairs(CubbyDB.items) do
    table.insert(list, item)
  end
  for key, p in pairs(CubbyDB.pending or {}) do
    table.insert(list, {
      pending = true,
      key     = key,
      name    = p.name,
      target  = p.target,
    })
  end
  table.sort(list, function(a, b)
    local ga = self:GroupOf(a)
    local gb = self:GroupOf(b)
    if ga == gb then return (a.name or "") < (b.name or "") end
    -- "Not yet seen" first, then "Loading…", then alpha, then "Other" last.
    if ga == "Not yet seen" then return true end
    if gb == "Not yet seen" then return false end
    if ga == "Loading…" then return true end
    if gb == "Loading…" then return false end
    if ga == "Other" then return false end
    if gb == "Other" then return true end
    return ga < gb
  end)
  return list
end

local function onItemInfoReceived(id, ok)
  if not id or ok == false then return end
  if CubbyDB and CubbyDB.items[id] and not CubbyDB.items[id].name then
    local name, _, quality, _, _, itemType, subType, _, _, icon = GetItemInfo(id)
    if name then
      CubbyDB.items[id].name = name
      CubbyDB.items[id].icon = icon
      CubbyDB.items[id].itemType = itemType
      CubbyDB.items[id].subType = subType
      CubbyDB.items[id].quality = quality
      ns.UI:Refresh()
    end
  end
end

local function probePendingItems()
  if not CubbyDB or not CubbyDB.items then return end
  for id, item in pairs(CubbyDB.items) do
    if not item.name or not item.subType or not item.itemType or not item.quality then
      local name, _, quality, _, _, itemType, subType, _, _, icon = GetItemInfo(id)
      if name then
        item.name = name
        item.icon = icon
        item.itemType = itemType
        item.subType = subType
        item.quality = quality
      end
    end
  end
end

local function handleSlash(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "" or msg == "show" or msg == "toggle" then
    ns.UI:Toggle()
  elseif msg == "help" then
    Cubby:Print("/cubby — toggle the main window")
    Cubby:Print("/cubby tracker — show the on-screen tracker (after you minimized it)")
    Cubby:Print("/cubby reset — reset the main window position")
    Cubby:Print("Items: drag into the window, or click the bottom strip to add by name.")
    Cubby:Print("Buffs: tick \"Ignore\" on the Buffs tab for ones you don't need.")
  elseif msg == "reset" then
    CubbyDB.framePos = { point = "CENTER", x = 0, y = 0 }
    ns.UI:ApplyPosition()
    Cubby:Print("Window position reset.")
  elseif msg == "tracker" then
    -- Brings the tracker back when it was minimized for the session.
    -- Doesn't touch the persistent CubbyDB.tracker.shown preference —
    -- if the user permanently disabled the tracker in Settings, they
    -- should turn it back on there.
    if ns.Tracker then ns.Tracker:Show() end
  elseif msg == "debug" or msg == "debug buffs" then
    -- Opens the Buff debug log window (same window as the Settings-tab
    -- button). Snapshot: API detection, raw AuraData points, flattened
    -- tuple positions 16..30, slot-map cross-check, and Status output.
    if ns.UI and ns.UI.ShowBuffLog then ns.UI:ShowBuffLog() end
  elseif msg == "bank retry" or msg == "bank-retry" then
    -- After the user manually clears a wedged slot in the bank window,
    -- re-run the planner without needing to close+reopen the bank.
    if ns.Bank then ns.Bank:Retry() end
  else
    ns.UI:Toggle()
  end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("UI_ERROR_MESSAGE")

frame:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    defaults()
  elseif event == "PLAYER_LOGIN" then
    ns.UI:Build()
    ns.Minimap:Build()
    ns.Tracker:Build()
    probePendingItems()
    resolvePending()
    SLASH_CUBBY1 = "/cubby"
    SLASH_CUBBY2 = "/cb"
    SlashCmdList.CUBBY = handleSlash
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    onItemInfoReceived(arg1, arg2)
    resolvePending()
  elseif event == "MERCHANT_SHOW" then
    if not IsShiftKeyDown() then
      ns.Restock:OnMerchantShow()
    end
    resolvePending()
  elseif event == "BANKFRAME_OPENED" then
    if ns.Bank then ns.Bank.bankOpen = true end
    if not IsShiftKeyDown() then
      if ns.UI then
        ns.UI:Show()
        ns.UI:RefreshStatuses()
      end
      C_Timer.After(0.4, function()
        if ns.Bank then ns.Bank:Start() end
      end)
    end
  elseif event == "BANKFRAME_CLOSED" then
    if ns.Bank then
      ns.Bank:Stop()
      ns.Bank.bankOpen = false
    end
    if ns.UI then
      ns.UI:Hide()
      ns.UI:RefreshStatuses()
    end
  elseif event == "BAG_UPDATE_DELAYED"
      or event == "PLAYERBANKSLOTS_CHANGED" then
    resolvePending()
    if ns.UI then ns.UI:RefreshStatuses() end
  elseif event == "UNIT_AURA" and arg1 == "player" then
    -- Buff state on the player changed. The Items list doesn't care, but
    -- the Tracker's Buffs section does, so refresh just the tracker.
    if ns.Tracker then ns.Tracker:Refresh() end
  elseif event == "UI_ERROR_MESSAGE" then
    -- Forward Blizzard's red-error-area messages to Bank so a "Couldn't
    -- split those items" line gets captured into the Bank log alongside
    -- the move that triggered it. Bank ignores errors when its ticker
    -- isn't running.
    if ns.Bank and ns.Bank.OnUIError then ns.Bank:OnUIError(arg1, arg2) end
  end
end)

local _origChatEdit_InsertLink = ChatEdit_InsertLink
function ChatEdit_InsertLink(link)
  if ns.UI and (ns.UI:IsSearchFocused() or ns.UI:IsAddPopupFocused()) then
    Cubby:AddItem(link)
    return true
  end
  return _origChatEdit_InsertLink(link)
end
