local ADDON_NAME, ns = ...

ns.Tracker = {}
local Tracker = ns.Tracker

-- An always-on objective-tracker-style panel. Two states:
--   * Ready  — every tracked item with a target meets it in bags
--               → single green "✓ Cubby — ready to raid" line.
--   * Short  — anything is below target → header + grouped item list
--               showing bag/target. Same group labels as the main window.
-- Pending entries (added by name, not yet seen) are excluded — we can't
-- decide whether they're stocked, so they don't belong in an actionable
-- shortfall list. They show up in the main window only.

local FRAME_W      = 210
local ROW_H        = 16
local HEADER_H     = 14
local PADDING      = 8
-- Indent levels. The tracker has two nesting depths:
--   top-level     ("Buffs", "Items")               → INDENT_TOP   (0)
--   sub-group     ("Bandage", "Potion")            → INDENT_SUB   (10)
--   buff row      directly under Buffs             → INDENT_LEAF  (10)
--   item row      under an item sub-group          → INDENT_LEAF2 (14)
local INDENT_TOP   = 0
local INDENT_SUB   = 10
local INDENT_LEAF  = 10
local INDENT_LEAF2 = 14

-- Match the main window's status icons exactly, so the meaning is one rule
-- instead of two. bank = visit your banker, short = visit a merchant/AH.
-- "ok" is never used here (the tracker only lists shortfalls).
local STATUS_TEX = {
  bank  = "Interface\\MINIMAP\\TRACKING\\Banker",
  short = "Interface\\MINIMAP\\TRACKING\\Auctioneer",
}

local frame
local titleText
local listChild
local rowPool      = {}
local headerPool   = {}
local buffRowPool  = {}
local ackLinePool  = {}

local function trackerDb()
  if not CubbyDB then return {} end
  CubbyDB.tracker = CubbyDB.tracker or {}
  return CubbyDB.tracker
end

-- A buff row: icon on the left, name fills the rest. When short, name
-- shows "(Nm)" remaining. Hover shows the spell tooltip.
local function makeBuffRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_H)

  local icon = row:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ROW_H - 2, ROW_H - 2)
  icon:SetPoint("LEFT", row, "LEFT", 0, 0)
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  row.icon = icon

  local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  name:SetPoint("LEFT",  icon, "RIGHT", 4, 0)
  name:SetPoint("RIGHT", row,  "RIGHT", -2, 0)
  name:SetJustifyH("LEFT")
  name:SetWordWrap(false)
  row.name = name

  row:EnableMouse(true)
  row:SetScript("OnEnter", function(self)
    if not self.spellId then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    if GameTooltip.SetSpellByID then
      GameTooltip:SetSpellByID(self.spellId)
    else
      GameTooltip:SetHyperlink("spell:" .. self.spellId)
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", GameTooltip_Hide)
  row:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" and ns.UI then ns.UI:Show() end
  end)

  return row
end

local function getBuffRow(i, parent)
  local r = buffRowPool[i]
  if not r then
    r = makeBuffRow(parent)
    buffRowPool[i] = r
  end
  return r
end

-- A small "✓ All X stocked/active" acknowledgement line — same width as
-- a row, no icon, green-tinted via inline texture + colour-escaped text.
local function makeAckLine(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_H)
  local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT",  row, "LEFT", 0, 0)
  text:SetPoint("RIGHT", row, "RIGHT", -2, 0)
  text:SetJustifyH("LEFT")
  text:SetWordWrap(false)
  row.text = text
  return row
end

local function getAckLine(i, parent)
  local a = ackLinePool[i]
  if not a then
    a = makeAckLine(parent)
    ackLinePool[i] = a
  end
  return a
end

local function makeRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_H)

  -- Leftmost: bank vs short status icon (same convention as the main list).
  local status = row:CreateTexture(nil, "OVERLAY")
  status:SetSize(ROW_H - 2, ROW_H - 2)
  status:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.status = status

  local icon = row:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ROW_H - 2, ROW_H - 2)
  icon:SetPoint("LEFT", status, "RIGHT", 3, 0)
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  row.icon = icon

  local count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  count:SetPoint("RIGHT", row, "RIGHT", -2, 0)
  count:SetJustifyH("RIGHT")
  row.count = count

  local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  name:SetPoint("LEFT",  icon,  "RIGHT", 4, 0)
  name:SetPoint("RIGHT", count, "LEFT", -4, 0)
  name:SetJustifyH("LEFT")
  name:SetWordWrap(false)
  row.name = name

  -- Per-row hover tooltip: full item tooltip + Cubby's required/in-bags/
  -- in-bank lines, matching the main window row tooltip. Anchored LEFT so
  -- the tooltip pops out to the left of the right-edge-docked tracker.
  row:EnableMouse(true)
  row:SetScript("OnEnter", function(self)
    if not self.itemId then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetHyperlink("item:" .. self.itemId)
    local item = CubbyDB and CubbyDB.items and CubbyDB.items[self.itemId]
    if item then
      local bag    = GetItemCount(self.itemId, false, false) or 0
      local total  = GetItemCount(self.itemId, true,  false) or 0
      local bank   = math.max(0, total - bag)
      local target = item.target or 0
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine("Cubby required:", tostring(target), 0.6, 0.85, 1, 1, 1, 1)
      GameTooltip:AddDoubleLine("In bags:", tostring(bag),  0.6, 0.85, 1, 1, 1, 1)
      GameTooltip:AddDoubleLine("In bank:", tostring(bank), 0.6, 0.85, 1, 1, 1, 1)
      if target > 0 then
        if bag >= target then
          GameTooltip:AddLine("Stocked.", 0.3, 0.9, 0.3)
        elseif total >= target then
          GameTooltip:AddLine("Visit your bank to top up.", 1.0, 0.85, 0.2)
        else
          GameTooltip:AddLine("Not enough stock — get more.", 1.0, 0.5, 0.5)
        end
      end
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", GameTooltip_Hide)
  -- Click on a row opens the main window, same as clicking the tracker
  -- background. Without this, the row captures the click and the parent
  -- frame's OnMouseUp never fires.
  row:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" and ns.UI then ns.UI:Show() end
  end)

  return row
end

local function getRow(i, parent)
  local r = rowPool[i]
  if not r then
    r = makeRow(parent)
    rowPool[i] = r
  end
  return r
end

local function makeHeader(parent)
  local h = CreateFrame("Frame", nil, parent)
  h:SetHeight(HEADER_H)

  local txt = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  txt:SetPoint("LEFT", h, "LEFT", 0, 0)
  txt:SetTextColor(1.0, 0.82, 0.0)  -- gold, matches main window section heads
  h.text = txt

  return h
end

local function getHeader(i, parent)
  local h = headerPool[i]
  if not h then
    h = makeHeader(parent)
    headerPool[i] = h
  end
  return h
end

function Tracker:Refresh()
  if not frame or not frame:IsShown() then return end
  if not CubbyDB or not CubbyDB.items then return end

  -- Gather actionable shortfalls. Pending items (no id) skipped. For each
  -- shortfall, also pull the bank total so we can pick the bank/short icon.
  local missing = {}
  local trackedWithTarget = 0
  for _, item in ipairs(ns.Cubby:Items()) do
    if item.id and item.name and (item.target or 0) > 0 then
      trackedWithTarget = trackedWithTarget + 1
      local bag   = GetItemCount(item.id, false, false) or 0
      local total = GetItemCount(item.id, true,  false) or 0
      if bag < item.target then
        table.insert(missing, {
          item = item, bag = bag, total = total, target = item.target,
        })
      end
    end
  end

  -- Buff readiness (new). Each entry is { buff, state, remain }; missing
  -- and short both surface here.
  local missingBuffs = (ns.Buffs and ns.Buffs:Missing()) or {}
  local buffStatus   = (ns.Buffs and ns.Buffs:Status())  or {}
  local anyBuffsRequired = #buffStatus > 0

  local totalMissing = #missing + #missingBuffs

  local y = 0
  local rowsUsed, headersUsed, buffsUsed, acksUsed = 0, 0, 0, 0
  local listTop = HEADER_H + 6  -- under the title text

  -- Helper closures to keep the section rendering below tidy.
  local function emitHeader(text, indent)
    headersUsed = headersUsed + 1
    local h = getHeader(headersUsed, listChild)
    h.text:SetText(text)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", listChild, "TOPLEFT", indent or INDENT_TOP, -y)
    h:SetPoint("RIGHT",   listChild, "RIGHT",   0, 0)
    h:Show()
    y = y + HEADER_H
  end

  local function emitAck(text, indent)
    acksUsed = acksUsed + 1
    local a = getAckLine(acksUsed, listChild)
    -- Inline check texture rather than a U+2713 glyph (font doesn't have it).
    a.text:SetText(
      "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:12:12:0:0|t |cff66ff66"
      .. text .. "|r")
    a:ClearAllPoints()
    a:SetPoint("TOPLEFT", listChild, "TOPLEFT", indent or INDENT_LEAF, -y)
    a:SetPoint("RIGHT",   listChild, "RIGHT",   0, 0)
    a:Show()
    y = y + ROW_H
  end

  if trackedWithTarget == 0 and not anyBuffsRequired then
    titleText:SetText("|cffffd200Cubby|r — |cffaaaaaanothing tracked yet|r")
    listChild:SetHeight(1)
    frame:SetHeight(listTop + PADDING)
  elseif totalMissing == 0 then
    -- Inline texture rather than a "✓" glyph (the WoW font doesn't render
    -- the unicode codepoint and shows a tofu square instead).
    titleText:SetText(
      "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:14:14:0:0|t "
      .. "|cffffd200Cubby|r — |cff66ff66ready to raid|r")
    listChild:SetHeight(1)
    frame:SetHeight(listTop + PADDING)
  else
    titleText:SetText(
      "|cffffd200Cubby|r — |cffff9999"
      .. totalMissing .. " missing|r")

    -- ----- Buffs section -----
    if anyBuffsRequired then
      emitHeader("Buffs", INDENT_TOP)
      if #missingBuffs > 0 then
        for _, m in ipairs(missingBuffs) do
          buffsUsed = buffsUsed + 1
          local r = getBuffRow(buffsUsed, listChild)
          r.spellId = m.buff.spell_ids and m.buff.spell_ids[1] or nil
          r.icon:SetTexture(ns.Buffs:IconFor(m.buff))
          if m.state == 'short' and m.remain then
            r.name:SetText(m.buff.name
              .. " |cffffd200(" .. math.floor(m.remain) .. "m)|r")
          else
            r.name:SetText(m.buff.name)
          end
          r:ClearAllPoints()
          r:SetPoint("TOPLEFT", listChild, "TOPLEFT", INDENT_LEAF, -y)
          r:SetPoint("RIGHT",   listChild, "RIGHT",   0, 0)
          r:Show()
          y = y + ROW_H
        end
      else
        emitAck("All required buffs active", INDENT_LEAF)
      end
    end

    -- ----- Items section -----
    if trackedWithTarget > 0 then
      emitHeader("Items", INDENT_TOP)
      if #missing > 0 then
        local groupOrder, byGroup = {}, {}
        for _, m in ipairs(missing) do
          local g = ns.Cubby:GroupOf(m.item)
          if not byGroup[g] then
            byGroup[g] = {}
            table.insert(groupOrder, g)
          end
          table.insert(byGroup[g], m)
        end

        for _, g in ipairs(groupOrder) do
          emitHeader(g, INDENT_SUB)
          for _, m in ipairs(byGroup[g]) do
            rowsUsed = rowsUsed + 1
            local r = getRow(rowsUsed, listChild)
            r.itemId = m.item.id
            r.icon:SetTexture(m.item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetText(m.item.name)
            r.count:SetText(m.bag .. "/" .. m.target)
            if m.total >= m.target then
              r.status:SetTexture(STATUS_TEX.bank)
            else
              r.status:SetTexture(STATUS_TEX.short)
            end
            r.status:Show()
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", listChild, "TOPLEFT", INDENT_LEAF2, -y)
            r:SetPoint("RIGHT",   listChild, "RIGHT",   0, 0)
            r:Show()
            y = y + ROW_H
          end
        end
      else
        emitAck("All items stocked", INDENT_LEAF)
      end
    end

    listChild:SetHeight(math.max(1, y))
    frame:SetHeight(listTop + y + PADDING)
  end

  for i = rowsUsed + 1, #rowPool do
    rowPool[i]:Hide()
    rowPool[i].itemId = nil
  end
  for i = headersUsed + 1, #headerPool do headerPool[i]:Hide() end
  for i = buffsUsed   + 1, #buffRowPool do
    buffRowPool[i]:Hide()
    buffRowPool[i].spellId = nil
  end
  for i = acksUsed + 1, #ackLinePool do ackLinePool[i]:Hide() end
end

function Tracker:ApplyPosition()
  if not frame then return end
  local db = trackerDb()
  frame:ClearAllPoints()
  if db.point then
    frame:SetPoint(db.point, UIParent, db.point, db.x or 0, db.y or 0)
  else
    -- Default: right edge, vertically centered.
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -16, 0)
  end
end

local function savePosition()
  local db = trackerDb()
  local point, _, _, x, y = frame:GetPoint(1)
  db.point = point
  db.x     = x
  db.y     = y
end

function Tracker:ApplyLock()
  if not frame then return end
  -- Locked = not draggable, but mouse is still enabled for click-to-open.
  frame:SetMovable(not trackerDb().locked)
end

function Tracker:Show()
  if not frame then return end
  trackerDb().shown = true
  frame:Show()
  self:Refresh()
end

function Tracker:Hide()
  if not frame then return end
  trackerDb().shown = false
  frame:Hide()
end

function Tracker:IsShown()
  return frame and frame:IsShown()
end

function Tracker:Toggle()
  if self:IsShown() then self:Hide() else self:Show() end
end

function Tracker:Build()
  if frame then return end

  frame = CreateFrame("Frame", "CubbyTracker", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  frame:SetWidth(FRAME_W)
  frame:SetHeight(40)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.55)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.9)
  end
  frame:SetAlpha(0.92)

  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self)
    if not trackerDb().locked then self:StartMoving() end
  end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePosition()
  end)
  frame:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" and ns.UI then ns.UI:Show() end
  end)
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Cubby tracker")
    GameTooltip:AddLine("Click to open the main window. Drag to move.",
      0.85, 0.85, 0.85, true)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", GameTooltip_Hide)

  -- Session-only hide. Disappears the tracker until the next /reload or
  -- login. Distinct from the Settings tab's "Show tracker" checkbox, which
  -- is the persistent preference and survives reloads.
  local closeBtn = CreateFrame("Button", nil, frame)
  closeBtn:SetSize(14, 14)
  closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
  closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
  closeBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
  closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
  closeBtn:SetScript("OnClick", function()
    frame:Hide()  -- ephemeral: do not touch CubbyDB.tracker.shown
  end)
  closeBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Hide for this session")
    GameTooltip:AddLine("Comes back on next /reload or login. To hide it "
      .. "permanently, uncheck \"Show tracker\" in Settings.",
      0.85, 0.85, 0.85, true)
    GameTooltip:Show()
  end)
  closeBtn:SetScript("OnLeave", GameTooltip_Hide)

  titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  titleText:SetPoint("TOPLEFT",  frame,    "TOPLEFT",  PADDING, -PADDING)
  -- Leave room for the close button on the right.
  titleText:SetPoint("TOPRIGHT", closeBtn, "LEFT",     -4,      0)
  titleText:SetJustifyH("LEFT")
  titleText:SetWordWrap(false)

  listChild = CreateFrame("Frame", nil, frame)
  listChild:SetPoint("TOPLEFT",  titleText, "BOTTOMLEFT",  0, -4)
  listChild:SetPoint("TOPRIGHT", titleText, "BOTTOMRIGHT", 0, -4)
  listChild:SetHeight(1)

  self:ApplyPosition()
  self:ApplyLock()

  -- First-run default: visible. Explicit `false` in saved vars hides.
  if trackerDb().shown == false then
    frame:Hide()
  else
    frame:Show()
    self:Refresh()
  end
end
