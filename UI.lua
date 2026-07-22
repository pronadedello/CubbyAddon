local ADDON_NAME, ns = ...

ns.UI = {}
local UI = ns.UI

local FRAME_W = 320
local FRAME_H = 460
local ROW_H = 28
local ROW_PAD = 4
local LIST_TOP_INSET = 64
-- Bumped from 80 → 84 so the dropzone + status text sit a few pixels above
-- the tabs that hang off the bottom edge, instead of being crammed against
-- them.
local LIST_BOTTOM_INSET = 84
local DROPZONE_H = 44

local mainFrame
local searchBox
local searchFilter = ""
local listScroll
local listChild
local statusText
local rowPool = {}
local headerPool = {}
local applyStatus -- forward-declared; defined below makeRow

local HEADER_H = 18
local HEADER_PAD = 2

local addPopup
local addEditBox
local addHintText

local tabButtons = {}
local itemsTabWidgets = {}
local buffsPage
local settingsPage

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function cursorIsItem()
  local kind, _, link = GetCursorInfo()
  if kind == "item" then return link end
end

local function addFromCursor()
  local link = cursorIsItem()
  if link then
    ns.Cubby:AddItem(link)
    ClearCursor()
  end
end

local function makeRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_H)

  local bg = row:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(row)
  bg:SetColorTexture(1, 1, 1, 0.05)
  bg:Hide()
  row.bg = bg

  local status = row:CreateTexture(nil, "OVERLAY")
  status:SetSize(16, 16)
  status:SetPoint("LEFT", row, "LEFT", 4, 0)
  status:Hide()
  row.status = status

  local icon = row:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ROW_H - 4, ROW_H - 4)
  icon:SetPoint("LEFT", status, "RIGHT", 4, 0)
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  row.icon = icon

  local iconBg = row:CreateTexture(nil, "BORDER")
  iconBg:SetColorTexture(0, 0, 0, 0.5)
  iconBg:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
  iconBg:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)

  -- Quality border around the icon, same idea as the coloured frame Blizzard
  -- draws around items in your bags. WhiteIconFrame is a white square outline;
  -- SetVertexColor tints it to the quality colour.
  local iconQuality = row:CreateTexture(nil, "OVERLAY")
  iconQuality:SetTexture("Interface\\Common\\WhiteIconFrame")
  iconQuality:SetPoint("TOPLEFT", icon, "TOPLEFT", -2, 2)
  iconQuality:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -2)
  iconQuality:Hide()
  row.iconQuality = iconQuality

  local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
  name:SetJustifyH("LEFT")
  row.name = name

  local delBtn = CreateFrame("Button", nil, row)
  delBtn:SetSize(16, 16)
  delBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  delBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
  delBtn:GetNormalTexture():SetVertexColor(0.9, 0.4, 0.4)
  delBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
  delBtn:GetHighlightTexture():SetVertexColor(1, 0.6, 0.6)
  delBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Remove from Cubby")
    GameTooltip:Show()
  end)
  delBtn:SetScript("OnLeave", GameTooltip_Hide)
  row.delBtn = delBtn

  local qty = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
  qty:SetSize(40, 20)
  qty:SetPoint("RIGHT", delBtn, "LEFT", -6, 0)
  qty:SetAutoFocus(false)
  qty:SetNumeric(true)
  qty:SetMaxLetters(4)
  qty:SetJustifyH("CENTER")
  row.qty = qty

  name:SetPoint("RIGHT", qty, "LEFT", -6, 0)

  qty:SetScript("OnEnterPressed", function(self)
    local v = tonumber(self:GetText()) or 0
    if row.itemId then
      ns.Cubby:SetTarget(row.itemId, v)
      self:SetText(tostring(v))
      applyStatus(row)
      -- If we're at the bank, immediately apply the new target.
      if ns.Bank and ns.Bank:IsAvailable() then
        ns.Bank:Refresh()
      end
    elseif row.pendingKey then
      ns.Cubby:SetPendingTarget(row.pendingKey, v)
      self:SetText(tostring(v))
    end
    self:ClearFocus()
    -- Tracker may need to add or drop this row depending on the new target.
    if ns.Tracker then ns.Tracker:Refresh() end
  end)
  qty:SetScript("OnEscapePressed", function(self)
    if row.itemId and CubbyDB.items[row.itemId] then
      self:SetText(tostring(CubbyDB.items[row.itemId].target or 0))
    elseif row.pendingKey and CubbyDB.pending[row.pendingKey] then
      self:SetText(tostring(CubbyDB.pending[row.pendingKey].target or 0))
    end
    self:ClearFocus()
  end)

  delBtn:SetScript("OnClick", function()
    if row.itemId then
      ns.Cubby:RemoveItem(row.itemId)
    elseif row.pendingKey then
      ns.Cubby:RemovePending(row.pendingKey)
    end
  end)

  row:EnableMouse(true)
  -- Shift/ctrl/alt-click behaves like shift-clicking the item in your bag:
  -- HandleModifiedItemClick handles chat link insert, dressing room, etc.
  -- Pending rows have no link to deliver, so this is a no-op for them.
  row:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and row.itemId then
      local link = select(2, GetItemInfo(row.itemId))
      if link then HandleModifiedItemClick(link) end
    end
  end)
  row:SetScript("OnEnter", function(self)
    if row.pendingKey then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(row.name and row.name:GetText() or "Not yet seen")
      GameTooltip:AddLine("Tracked by name — the game hasn't shown this item "
        .. "to this character yet, so Cubby doesn't know its icon, type, or "
        .. "live counts.", 1, 1, 1, true)
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("It'll fill in automatically the first time you "
        .. "encounter it in-game (loot it, mouseover a tooltip, see it at a "
        .. "vendor or the auction house). Your target count is kept.",
        0.85, 0.85, 0.85, true)
      GameTooltip:Show()
      return
    end
    if not row.itemId then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:" .. row.itemId)
    local item = CubbyDB.items[row.itemId]
    if item then
      local bag = GetItemCount(row.itemId, false, false) or 0
      local total = GetItemCount(row.itemId, true, false) or 0
      local bank = math.max(0, total - bag)
      local target = item.target or 0
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine("Cubby required:", tostring(target), 0.6, 0.85, 1, 1, 1, 1)
      GameTooltip:AddDoubleLine("In bags:",  tostring(bag),  0.6, 0.85, 1, 1, 1, 1)
      GameTooltip:AddDoubleLine("In bank:",  tostring(bank), 0.6, 0.85, 1, 1, 1, 1)
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

  return row
end

local function getRow(i, parent)
  local row = rowPool[i]
  if not row then
    row = makeRow(parent)
    rowPool[i] = row
  end
  return row
end

local function getHeader(i, parent)
  local h = headerPool[i]
  if h then return h end
  h = CreateFrame("Button", nil, parent)
  h:SetHeight(HEADER_H)

  local toggle = h:CreateTexture(nil, "ARTWORK")
  toggle:SetSize(14, 14)
  toggle:SetPoint("LEFT", h, "LEFT", 2, 0)
  h.toggle = toggle

  local txt = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  txt:SetPoint("LEFT", toggle, "RIGHT", 4, 0)
  txt:SetTextColor(1.0, 0.82, 0.0) -- gold, matching Blizzard section headers
  h.text = txt

  local sep = h:CreateTexture(nil, "BORDER")
  sep:SetColorTexture(0.6, 0.6, 0.6, 0.35)
  sep:SetPoint("LEFT", txt, "RIGHT", 6, -1)
  sep:SetPoint("RIGHT", h, "RIGHT", -4, -1)
  sep:SetHeight(1)

  h:SetScript("OnClick", function(self)
    local g = self.groupLabel
    if not g then return end
    CubbyDB.collapsed = CubbyDB.collapsed or {}
    CubbyDB.collapsed[g] = not CubbyDB.collapsed[g]
    UI:Refresh()
  end)

  headerPool[i] = h
  return h
end

local function matchesFilter(item)
  if searchFilter == "" then return true end
  return (item.name or ""):lower():find(searchFilter, 1, true) ~= nil
end

-- ok    = bags meet target (green check)
-- bank  = you have enough in bank to top up; go visit the banker (banker icon)
-- short = even bank can't cover; you need to buy more (auctioneer/coin icon)
local STATUS_TEX = {
  ok    = "Interface\\RAIDFRAME\\ReadyCheck-Ready",
  bank  = "Interface\\MINIMAP\\TRACKING\\Banker",
  short = "Interface\\MINIMAP\\TRACKING\\Auctioneer",
}

applyStatus = function(row)
  local id = row.itemId
  if not id then row.status:Hide() return end
  local item = CubbyDB.items[id]
  if not item or (item.target or 0) <= 0 then
    row.status:Hide()
    return
  end
  local target = item.target
  local bag   = GetItemCount(id, false, false) or 0
  local total = GetItemCount(id, true,  false) or 0

  local tex
  if bag >= target then
    tex = STATUS_TEX.ok
  elseif total >= target then
    tex = STATUS_TEX.bank
  else
    tex = STATUS_TEX.short
  end
  row.status:SetTexture(tex)
  row.status:Show()
end

function UI:RefreshStatuses()
  if not listChild then return end
  if ns.Tracker then ns.Tracker:Refresh() end
  -- In "Only missing" mode the visible set itself is filter-dependent: an
  -- item that just hit target needs to *leave* the list, not merely change
  -- its status icon. Promote to a full Refresh in that case.
  if CubbyDB and CubbyDB.showOnlyMissing then
    self:Refresh()
    return
  end
  for _, row in ipairs(rowPool) do
    if row:IsShown() then applyStatus(row) end
  end
end

local function applyQualityBorder(row, quality)
  if not quality or quality < 1 or not ITEM_QUALITY_COLORS or not ITEM_QUALITY_COLORS[quality] then
    row.iconQuality:Hide()
    return
  end
  local c = ITEM_QUALITY_COLORS[quality]
  row.iconQuality:SetVertexColor(c.r, c.g, c.b, 1)
  row.iconQuality:Show()
end

local function paintRow(row, item, idx, y)
  row.itemId     = item.id
  row.pendingKey = item.pending and item.key or nil
  row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  if item.name then
    row.name:SetText(item.name)
  elseif item.id then
    row.name:SetText("Loading… (#" .. item.id .. ")")
  else
    row.name:SetText("Loading…")
  end
  row.qty:SetText(tostring(item.target or 0))
  applyQualityBorder(row, item.quality)
  if idx % 2 == 0 then row.bg:Show() else row.bg:Hide() end
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -y)
  row:SetPoint("RIGHT", listChild, "RIGHT", 0, 0)
  row:Show()
  applyStatus(row)
end

function UI:Refresh()
  if not listChild then return end
  CubbyDB.collapsed = CubbyDB.collapsed or {}
  local missingOnly = CubbyDB.showOnlyMissing == true

  local items = ns.Cubby:Items()
  local filtered = {}
  for _, item in ipairs(items) do
    local passSearch = (not item.name) or matchesFilter(item)
    if passSearch then
      if missingOnly then
        -- Pending entries (no id yet) can't be checked against live counts,
        -- so they're hidden from "Only missing" — not actionable until they
        -- resolve to a real item.
        if item.id and item.name and (item.target or 0) > 0 then
          local bag = GetItemCount(item.id, false, false) or 0
          if bag < item.target then table.insert(filtered, item) end
        end
      else
        table.insert(filtered, item)
      end
    end
  end

  local y = 0
  local rowsUsed = 0
  local headersUsed = 0

  if missingOnly then
    -- Flat list, no headers. Items still sorted by group then name (from
    -- Cubby:Items), so related shortfalls cluster naturally.
    for _, item in ipairs(filtered) do
      rowsUsed = rowsUsed + 1
      paintRow(getRow(rowsUsed, listChild), item, rowsUsed, y)
      y = y + ROW_H + ROW_PAD
    end
  else
    local groupOrder, byGroup = {}, {}
    for _, item in ipairs(filtered) do
      local g = ns.Cubby:GroupOf(item)
      if not byGroup[g] then
        byGroup[g] = {}
        table.insert(groupOrder, g)
      end
      table.insert(byGroup[g], item)
    end

    for gi, g in ipairs(groupOrder) do
      local collapsed = CubbyDB.collapsed[g] == true
      local groupItems = byGroup[g]

      headersUsed = headersUsed + 1
      local h = getHeader(headersUsed, listChild)
      h.groupLabel = g
      h.text:SetText(g .. " (" .. #groupItems .. ")")
      h.toggle:SetTexture(collapsed
        and "Interface\\Buttons\\UI-PlusButton-Up"
        or  "Interface\\Buttons\\UI-MinusButton-Up")
      h:ClearAllPoints()
      local headerPad = (gi == 1) and 0 or HEADER_PAD
      h:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -y - headerPad)
      h:SetPoint("RIGHT", listChild, "RIGHT", 0, 0)
      h:Show()
      y = y + HEADER_H + headerPad

      if not collapsed then
        for _, item in ipairs(groupItems) do
          rowsUsed = rowsUsed + 1
          paintRow(getRow(rowsUsed, listChild), item, rowsUsed, y)
          y = y + ROW_H + ROW_PAD
        end
      end
    end
  end

  for i = rowsUsed + 1, #rowPool do
    rowPool[i]:Hide()
    rowPool[i].itemId = nil
    rowPool[i].pendingKey = nil
  end
  for i = headersUsed + 1, #headerPool do
    headerPool[i]:Hide()
  end

  local total = 0
  for _ in pairs(CubbyDB.items) do total = total + 1 end
  for _ in pairs(CubbyDB.pending or {}) do total = total + 1 end

  listChild:SetHeight(math.max(1, y))

  if total == 0 then
    statusText:SetText("No items tracked yet")
  elseif missingOnly and #filtered == 0 then
    statusText:SetText("All " .. total .. " items stocked")
  elseif #filtered == 0 then
    statusText:SetText(total .. " tracked, none match search")
  elseif missingOnly then
    statusText:SetText(#filtered .. " of " .. total .. " missing")
  else
    statusText:SetText(total .. " item" .. (total == 1 and "" or "s") .. " tracked")
  end

  if ns.Tracker then ns.Tracker:Refresh() end
end

-- Submit handler for the "track by name" popup. Tries to resolve the typed
-- name against the client's item cache via Cubby:AddItemByName, which either
-- adds the real item (cache hit, with full info + icon) or stores a pending
-- entry (cache miss — shows up with a ? icon and resolves later when the
-- player actually encounters that item in-game).
local function submitAddPopup()
  if not addEditBox then return end
  local raw = trim(addEditBox:GetText() or "")
  if raw == "" then return end

  local resolved, status = ns.Cubby:AddItemByName(raw)
  addEditBox:SetText("")
  addEditBox:SetFocus()
  if status == "duplicate" then
    addHintText:SetText("Already tracking that item.")
  elseif resolved then
    addHintText:SetText("Added.")
  else
    addHintText:SetText("Added to \"Not yet seen\" — the game hasn't shown "
      .. "this item to this character yet. The icon and live counts will "
      .. "fill in the first time you encounter it.")
  end
end

local function openAddPopup()
  if not addPopup then return end
  addPopup:Show()
  addEditBox:SetText("")
  addEditBox:SetFocus()
  addHintText:SetText("Type or paste an item name, then press Enter.")
end

local function closeAddPopup()
  if not addPopup then return end
  addEditBox:ClearFocus()
  addPopup:Hide()
end

function UI:IsAddPopupFocused()
  return addEditBox and addEditBox:HasFocus()
end

local function refreshSettingsPage()
  if not settingsPage or not CubbyDB then return end
  if CubbyDB.tracker then
    settingsPage.trackerCb:SetChecked(CubbyDB.tracker.shown ~= false)
    settingsPage.lockCb   :SetChecked(CubbyDB.tracker.locked == true)
  end
  local bank = CubbyDB.bank or {}
  if settingsPage.bankDisabledCb then
    settingsPage.bankDisabledCb:SetChecked(bank.disabled == true)
  end
  if settingsPage.bankDebugCb then
    settingsPage.bankDebugCb:SetChecked(bank.debug == true)
  end
  if settingsPage.bankIntervalEdit then
    settingsPage.bankIntervalEdit:SetText(tostring(bank.intervalMs or 500))
  end
end

local refreshBuffsPage  -- forward-declared; populated when buffsPage built

-- Tab switching. 1=Items (original list), 2=Buffs, 3=Settings. Each tab
-- owns a set of widgets; switching just toggles their visibility.
local function showTab(n)
  local onItems = (n == 1)
  for _, w in ipairs(itemsTabWidgets) do
    if onItems then w:Show() else w:Hide() end
  end
  if buffsPage    then if n == 2 then buffsPage:Show()    else buffsPage:Hide()    end end
  if settingsPage then if n == 3 then settingsPage:Show() else settingsPage:Hide() end end
  -- Close the add popup when leaving Items (it overlays the list area).
  if not onItems and addPopup and addPopup:IsShown() then addPopup:Hide() end
  if PanelTemplates_SetTab and mainFrame then
    PanelTemplates_SetTab(mainFrame, n)
  end
  -- Re-sync widgets on the tab we're entering — saved-vars or other UI
  -- paths may have changed state since the user last looked.
  if n == 2 and refreshBuffsPage    then refreshBuffsPage()    end
  if n == 3                         then refreshSettingsPage() end
end

function UI:ApplyPosition()
  if not mainFrame then return end
  local p = CubbyDB.framePos or {}
  mainFrame:ClearAllPoints()
  mainFrame:SetPoint(p.point or "CENTER", UIParent, p.point or "CENTER", p.x or 0, p.y or 0)
end

local function savePosition()
  local point, _, _, x, y = mainFrame:GetPoint(1)
  CubbyDB.framePos = { point = point, x = x, y = y }
end

function UI:IsSearchFocused()
  return searchBox and searchBox:HasFocus()
end

function UI:Show()
  if not mainFrame then return end
  if not mainFrame:IsShown() then
    mainFrame:Show()
    if self.missingCb then
      self.missingCb:SetChecked(CubbyDB.showOnlyMissing == true)
    end
    self:Refresh()
  end
end

function UI:Hide()
  if not mainFrame then return end
  if mainFrame:IsShown() then mainFrame:Hide() end
end

function UI:Toggle()
  if not mainFrame then return end
  if mainFrame:IsShown() then
    self:Hide()
  else
    self:Show()
  end
end

-- Built on first call. Standalone draggable popup with a multi-line EditBox
-- the user can Ctrl+A / Ctrl+C out of. Refresh re-pulls the live buffer;
-- Clear wipes Bank's saved-vars log.
local logFrame
local function buildLogFrame()
  if logFrame then return logFrame end

  logFrame = CreateFrame("Frame", "CubbyBankLogFrame", UIParent, "BasicFrameTemplateWithInset")
  logFrame:SetSize(560, 400)
  logFrame:SetPoint("CENTER")
  logFrame:SetFrameStrata("DIALOG")
  logFrame:SetClampedToScreen(true)
  logFrame:SetMovable(true)
  logFrame:EnableMouse(true)
  logFrame:RegisterForDrag("LeftButton")
  logFrame:SetScript("OnDragStart", logFrame.StartMoving)
  logFrame:SetScript("OnDragStop", logFrame.StopMovingOrSizing)
  tinsert(UISpecialFrames, "CubbyBankLogFrame")

  if logFrame.TitleText then logFrame.TitleText:SetText("Cubby bank log") end

  local hint = logFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 10, -28)
  hint:SetText("Click in the text, Ctrl+A, Ctrl+C.")

  local scroll = CreateFrame("ScrollFrame", "CubbyBankLogScroll", logFrame,
    "InputScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT",     logFrame, "TOPLEFT",      10, -44)
  scroll:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -32,  36)
  if scroll.CharCount then scroll.CharCount:Hide() end

  local edit = scroll.EditBox
  edit:SetFontObject(ChatFontNormal)
  edit:SetMaxLetters(0)
  edit:SetWidth(scroll:GetWidth() - 18)
  edit:SetAutoFocus(false)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  local refreshBtn = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  refreshBtn:SetSize(80, 22)
  refreshBtn:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -10, 8)
  refreshBtn:SetText("Refresh")
  refreshBtn:SetScript("OnClick", function()
    edit:SetText((ns.Bank and ns.Bank:GetLog()) or "")
    edit:SetCursorPosition(0)
    edit:HighlightText(0, 0)
  end)

  local clearBtn = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  clearBtn:SetSize(80, 22)
  clearBtn:SetPoint("RIGHT", refreshBtn, "LEFT", -6, 0)
  clearBtn:SetText("Clear")
  clearBtn:SetScript("OnClick", function()
    if ns.Bank then ns.Bank:ClearLog() end
    edit:SetText("")
  end)

  logFrame.edit = edit
  return logFrame
end

function UI:ShowBankLog()
  local f = buildLogFrame()
  f.edit:SetText((ns.Bank and ns.Bank:GetLog()) or "")
  f.edit:SetCursorPosition(0)
  f.edit:HighlightText(0, 0)
  f:Show()
end

-- Buff-debug log window. Clone of the bank log popup — different title,
-- fresh snapshot per Refresh, no Clear (each open is a fresh snapshot).
local buffLogFrame
local function buildBuffLogFrame()
  if buffLogFrame then return buffLogFrame end

  buffLogFrame = CreateFrame("Frame", "CubbyBuffLogFrame", UIParent,
    "BasicFrameTemplateWithInset")
  buffLogFrame:SetSize(620, 460)
  buffLogFrame:SetPoint("CENTER")
  buffLogFrame:SetFrameStrata("DIALOG")
  buffLogFrame:SetClampedToScreen(true)
  buffLogFrame:SetMovable(true)
  buffLogFrame:EnableMouse(true)
  buffLogFrame:RegisterForDrag("LeftButton")
  buffLogFrame:SetScript("OnDragStart", buffLogFrame.StartMoving)
  buffLogFrame:SetScript("OnDragStop", buffLogFrame.StopMovingOrSizing)
  tinsert(UISpecialFrames, "CubbyBuffLogFrame")

  if buffLogFrame.TitleText then
    buffLogFrame.TitleText:SetText("Cubby buff debug")
  end

  local hint = buffLogFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", buffLogFrame, "TOPLEFT", 10, -28)
  hint:SetText("Click in the text, Ctrl+A, Ctrl+C to copy.")

  local scroll = CreateFrame("ScrollFrame", "CubbyBuffLogScroll", buffLogFrame,
    "InputScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT",     buffLogFrame, "TOPLEFT",      10, -44)
  scroll:SetPoint("BOTTOMRIGHT", buffLogFrame, "BOTTOMRIGHT", -32,  36)
  if scroll.CharCount then scroll.CharCount:Hide() end

  local edit = scroll.EditBox
  edit:SetFontObject(ChatFontNormal)
  edit:SetMaxLetters(0)
  edit:SetWidth(scroll:GetWidth() - 18)
  edit:SetAutoFocus(false)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  local refreshBtn = CreateFrame("Button", nil, buffLogFrame, "UIPanelButtonTemplate")
  refreshBtn:SetSize(80, 22)
  refreshBtn:SetPoint("BOTTOMRIGHT", buffLogFrame, "BOTTOMRIGHT", -10, 8)
  refreshBtn:SetText("Refresh")
  refreshBtn:SetScript("OnClick", function()
    edit:SetText((ns.Buffs and ns.Buffs:DebugDump()) or "")
    edit:SetCursorPosition(0)
    edit:HighlightText(0, 0)
  end)

  buffLogFrame.edit = edit
  return buffLogFrame
end

function UI:ShowBuffLog()
  local f = buildBuffLogFrame()
  f.edit:SetText((ns.Buffs and ns.Buffs:DebugDump()) or "")
  f.edit:SetCursorPosition(0)
  f.edit:HighlightText(0, 0)
  f:Show()
end

-- Floating progress bar Bank updates while it's working. Lazy-built on
-- first Show; pinned to top-center, draggable, doesn't save position so
-- it's a transient indicator rather than a tracked widget.
local progressFrame

local function buildProgressFrame()
  if progressFrame then return progressFrame end

  progressFrame = CreateFrame("Frame", "CubbyBankProgress", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  progressFrame:SetSize(320, 56)
  progressFrame:SetPoint("TOP", UIParent, "TOP", 0, -120)
  progressFrame:SetFrameStrata("HIGH")
  progressFrame:SetMovable(true)
  progressFrame:EnableMouse(true)
  progressFrame:RegisterForDrag("LeftButton")
  progressFrame:SetScript("OnDragStart", progressFrame.StartMoving)
  progressFrame:SetScript("OnDragStop", progressFrame.StopMovingOrSizing)
  if progressFrame.SetBackdrop then
    progressFrame:SetBackdrop({
      bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    progressFrame:SetBackdropColor(0, 0, 0, 0.85)
  else
    local bg = progressFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(progressFrame)
    bg:SetColorTexture(0, 0, 0, 0.85)
  end

  progressFrame.label = progressFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  progressFrame.label:SetPoint("TOPLEFT",  progressFrame, "TOPLEFT",  10, -8)
  progressFrame.label:SetPoint("TOPRIGHT", progressFrame, "TOPRIGHT", -10, -8)
  progressFrame.label:SetJustifyH("LEFT")
  progressFrame.label:SetText("Cubby Bank")

  progressFrame.bar = CreateFrame("StatusBar", nil, progressFrame)
  progressFrame.bar:SetPoint("TOPLEFT",     progressFrame.label, "BOTTOMLEFT",  0, -4)
  progressFrame.bar:SetPoint("TOPRIGHT",    progressFrame.label, "BOTTOMRIGHT", 0, -4)
  progressFrame.bar:SetHeight(12)
  progressFrame.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  progressFrame.bar:SetStatusBarColor(0.55, 0.39, 1, 1)
  progressFrame.bar:SetMinMaxValues(0, 1)
  progressFrame.bar:SetValue(0)

  local bg = progressFrame.bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(progressFrame.bar)
  bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)

  progressFrame.detail = progressFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  progressFrame.detail:SetPoint("TOPLEFT",  progressFrame.bar, "BOTTOMLEFT",  0, -3)
  progressFrame.detail:SetPoint("TOPRIGHT", progressFrame.bar, "BOTTOMRIGHT", 0, -3)
  progressFrame.detail:SetJustifyH("LEFT")
  progressFrame.detail:SetTextColor(0.85, 0.85, 0.85)

  progressFrame:Hide()
  return progressFrame
end

-- current/total: integers. label: e.g. "Withdrawing". detail: most-recent
-- action string. Bank calls this on Start and after every move.
function UI:SetBankProgress(current, total, label, detail)
  local f = buildProgressFrame()
  f.label:SetText(string.format("Cubby Bank — %s (%d/%d)",
    label or "working", current, total))
  f.bar:SetMinMaxValues(0, math.max(total, 1))
  f.bar:SetValue(current)
  f.detail:SetText(detail or "")
  f:Show()
end

function UI:HideBankProgress()
  if progressFrame then progressFrame:Hide() end
end

function UI:Build()
  if mainFrame then return end

  mainFrame = CreateFrame("Frame", "CubbyFrame", UIParent, "BasicFrameTemplateWithInset")
  mainFrame:SetSize(FRAME_W, FRAME_H)
  mainFrame:SetFrameStrata("HIGH")
  mainFrame:SetClampedToScreen(true)
  mainFrame:SetMovable(true)
  mainFrame:EnableMouse(true)
  mainFrame:RegisterForDrag("LeftButton")
  mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
  mainFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePosition()
  end)
  mainFrame:SetScript("OnReceiveDrag", addFromCursor)
  mainFrame:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then addFromCursor() end
  end)
  tinsert(UISpecialFrames, "CubbyFrame")

  -- Pull the version straight from Cubby.toc at runtime so bumping the
  -- TOC is the single source of truth — no risk of the header drifting
  -- out of sync with what the packager shipped. GetAddOnMetadata moved
  -- to C_AddOns in Retail 10.x; shim it the same way as our other APIs.
  local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ver = getMeta and getMeta(ADDON_NAME, "Version") or nil
  -- Append the per-regen build stamp (last 6 chars = UTC HHMMSS) so
  -- successive dev pushes are visually distinguishable in the title bar
  -- even though the TOC Version doesn't change between real releases.
  local stamp = ns.BUILD_STAMP
  local suffix = (stamp and #stamp >= 6) and (" |cff666666b" .. stamp:sub(-6) .. "|r") or ""
  mainFrame.TitleText:SetText(
    ver and ("Cubby  |cff888888v" .. ver .. "|r" .. suffix) or "Cubby")

  local refreshBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
  refreshBtn:SetSize(60, 22)
  refreshBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -10, -30)
  refreshBtn:SetText("Refresh")
  refreshBtn:SetScript("OnClick", function()
    if ns.Bank and ns.Bank:IsAvailable() then ns.Bank:Refresh() end
    if ns.Restock and MerchantFrame and MerchantFrame:IsShown() then
      ns.Restock:OnMerchantShow()
    end
    UI:RefreshStatuses()
  end)
  refreshBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Recheck targets")
    GameTooltip:AddLine("At bank: shuffle between bags and bank to match targets.", 0.85, 0.85, 0.85, true)
    GameTooltip:AddLine("At merchant: buy any shortfall.", 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
  end)
  refreshBtn:SetScript("OnLeave", GameTooltip_Hide)

  -- "Only missing" filter — anchored just left of Refresh, search bar fills the rest.
  local missingCb = CreateFrame("CheckButton", nil, mainFrame, "UICheckButtonTemplate")
  missingCb:SetSize(22, 22)
  missingCb:SetPoint("RIGHT", refreshBtn, "LEFT", -2, 0)
  missingCb:SetHitRectInsets(0, 0, 0, 0)

  local missingLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  missingLabel:SetPoint("RIGHT", missingCb, "LEFT", -1, 0)
  missingLabel:SetText("Only missing")

  missingCb:SetScript("OnClick", function(self)
    CubbyDB.showOnlyMissing = self:GetChecked() and true or false
    UI:Refresh()
  end)
  missingCb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Only missing items")
    GameTooltip:AddLine("Hide categories and show only items where bag count is below target.",
      0.85, 0.85, 0.85, true)
    GameTooltip:Show()
  end)
  missingCb:SetScript("OnLeave", GameTooltip_Hide)
  UI.missingCb = missingCb

  searchBox = CreateFrame("EditBox", nil, mainFrame, "SearchBoxTemplate")
  searchBox:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 12, -30)
  searchBox:SetPoint("RIGHT", missingLabel, "LEFT", -4, 0)
  searchBox:SetHeight(22)
  searchBox:SetAutoFocus(false)
  searchBox:SetScript("OnTextChanged", function(self, userInput)
    SearchBoxTemplate_OnTextChanged(self)
    searchFilter = trim(self:GetText() or ""):lower()
    UI:Refresh()
  end)
  searchBox:SetScript("OnReceiveDrag", addFromCursor)
  searchBox:HookScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then addFromCursor() end
  end)

  listScroll = CreateFrame("ScrollFrame", "CubbyListScroll", mainFrame, "UIPanelScrollFrameTemplate")
  listScroll:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 8, -LIST_TOP_INSET)
  listScroll:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -28, LIST_BOTTOM_INSET)

  listChild = CreateFrame("Frame", nil, listScroll)
  listChild:SetSize(FRAME_W - 36, 1)
  listScroll:SetScrollChild(listChild)

  listChild:EnableMouse(true)
  listChild:SetScript("OnReceiveDrag", addFromCursor)
  listChild:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then addFromCursor() end
  end)

  -- Permanent drop zone at the bottom — discoverable target for adding items
  local dropZone = CreateFrame("Frame", nil, mainFrame,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  dropZone:SetSize(FRAME_W - 24, DROPZONE_H)
  dropZone:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 30)
  if dropZone.SetBackdrop then
    dropZone:SetBackdrop({
      bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    dropZone:SetBackdropColor(0, 0, 0, 0.35)
    dropZone:SetBackdropBorderColor(0.55, 0.55, 0.65, 1)
  end
  dropZone:EnableMouse(true)
  dropZone:SetScript("OnReceiveDrag", addFromCursor)
  dropZone:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then
      -- If the cursor is holding an item, drop it; otherwise open the
      -- search popup so the player can add an item they don't currently
      -- have on the cursor.
      if cursorIsItem() then
        addFromCursor()
      else
        openAddPopup()
      end
    end
  end)
  dropZone:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Add an item")
    GameTooltip:AddLine("Drag an item here, or click to add one by name.",
      0.85, 0.85, 0.85, true)
    GameTooltip:Show()
  end)
  dropZone:SetScript("OnLeave", GameTooltip_Hide)

  local dropZoneText = dropZone:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  dropZoneText:SetPoint("CENTER", dropZone, "CENTER")
  dropZoneText:SetText("Drop an item or click here to track an item")
  dropZoneText:SetTextColor(0.85, 0.85, 0.9)

  statusText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  statusText:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 12)

  -- "Track an item" popup. Just a name input + Add button. Overlays the
  -- main list area so the window doesn't need to grow. Opened by clicking
  -- the drop zone with an empty cursor; closed by Esc or the X button.
  addPopup = CreateFrame("Frame", "CubbyAddPopup", mainFrame,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  addPopup:SetFrameStrata("DIALOG")
  addPopup:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
  -- Anchor near the top of the list area; tall enough for the input + hint.
  addPopup:SetPoint("TOPLEFT",     listScroll, "TOPLEFT",     -4,  4)
  addPopup:SetPoint("TOPRIGHT",    listScroll, "TOPRIGHT",    24,  4)
  addPopup:SetHeight(110)
  if addPopup.SetBackdrop then
    addPopup:SetBackdrop({
      bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 14,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    addPopup:SetBackdropColor(0, 0, 0, 0.9)
    addPopup:SetBackdropBorderColor(0.5, 0.5, 0.6, 1)
  end
  addPopup:EnableMouse(true)
  addPopup:Hide()

  -- Belt-and-braces opaque background. The BackdropTemplate texture renders
  -- semi-transparent on some clients (notably Classic Era), letting the
  -- underlying list rows bleed through. A plain color texture guarantees
  -- an opaque fill.
  local popupBg = addPopup:CreateTexture(nil, "BACKGROUND")
  popupBg:SetPoint("TOPLEFT",     addPopup, "TOPLEFT",      4,  -4)
  popupBg:SetPoint("BOTTOMRIGHT", addPopup, "BOTTOMRIGHT", -4,   4)
  popupBg:SetColorTexture(0.04, 0.04, 0.06, 1.0)

  local addTitle = addPopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  addTitle:SetPoint("TOPLEFT", addPopup, "TOPLEFT", 10, -8)
  addTitle:SetText("Track an item by name")

  local addClose = CreateFrame("Button", nil, addPopup, "UIPanelCloseButton")
  addClose:SetSize(22, 22)
  addClose:SetPoint("TOPRIGHT", addPopup, "TOPRIGHT", -2, -2)
  addClose:SetScript("OnClick", closeAddPopup)

  local addBtn = CreateFrame("Button", nil, addPopup, "UIPanelButtonTemplate")
  addBtn:SetSize(54, 22)
  addBtn:SetPoint("TOPRIGHT", addPopup, "TOPRIGHT", -10, -30)
  addBtn:SetText("Add")
  addBtn:SetScript("OnClick", submitAddPopup)

  addEditBox = CreateFrame("EditBox", nil, addPopup, "InputBoxTemplate")
  addEditBox:SetPoint("TOPLEFT",  addPopup, "TOPLEFT",  16, -30)
  addEditBox:SetPoint("RIGHT",    addBtn,   "LEFT",      -6,   0)
  addEditBox:SetHeight(22)
  addEditBox:SetAutoFocus(false)
  addEditBox:SetMaxLetters(80)
  addEditBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    closeAddPopup()
  end)
  addEditBox:SetScript("OnEnterPressed", submitAddPopup)

  addHintText = addPopup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  addHintText:SetPoint("TOPLEFT",  addPopup, "TOPLEFT",  12, -60)
  addHintText:SetPoint("TOPRIGHT", addPopup, "TOPRIGHT", -12, -60)
  addHintText:SetJustifyH("LEFT")
  addHintText:SetSpacing(2)
  addHintText:SetText("Type or paste an item name, then press Enter.")

  -- Helper: stock UICheckButtonTemplate, no texture overrides. Returns
  -- the checkbox; the caller positions it.
  local function makeCheckbox(parent, label)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    cb.text:SetText(label)
    return cb
  end

  -- ---------------------------------------------------------------------
  -- Buffs tab page. One row per applicable buff: checkbox ticked = the
  -- buff is required (tracked); unticked = ignored. Storage remains
  -- CubbyDB.buffs.ignored — the UI just presents the opposite, which is
  -- the more intuitive direction ("tick what you want").
  -- ---------------------------------------------------------------------
  buffsPage = CreateFrame("Frame", nil, mainFrame)
  buffsPage:SetPoint("TOPLEFT",     listScroll, "TOPLEFT",     0, 0)
  buffsPage:SetPoint("BOTTOMRIGHT", listScroll, "BOTTOMRIGHT", 0, 0)
  buffsPage:Hide()

  local LEFT_PAD = 6
  local RIGHT_PAD = 6

  local buffsHeading = buffsPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  buffsHeading:SetPoint("TOPLEFT", buffsPage, "TOPLEFT", LEFT_PAD, -2)
  buffsHeading:SetText("World buffs")

  local buffsHelp = buffsPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  buffsHelp:SetPoint("TOPLEFT",  buffsHeading, "BOTTOMLEFT", 0,  -3)
  buffsHelp:SetPoint("RIGHT",    buffsPage,    "RIGHT",     -RIGHT_PAD, 0)
  buffsHelp:SetJustifyH("LEFT")
  buffsHelp:SetSpacing(2)
  buffsHelp:SetHeight(14)
  buffsHelp:SetText("Tick the ones you want tracked.")

  -- Duration threshold control. The number is the percentage of each
  -- buff's max duration below which it's flagged as "short" instead of
  -- "ok". Default 90.
  local durationLabel = buffsPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  durationLabel:SetPoint("TOPLEFT", buffsHelp, "BOTTOMLEFT", 0, -10)
  durationLabel:SetText("Required duration:")

  local durationEdit = CreateFrame("EditBox", nil, buffsPage, "InputBoxTemplate")
  durationEdit:SetPoint("LEFT", durationLabel, "RIGHT", 8, 0)
  durationEdit:SetSize(36, 20)
  durationEdit:SetAutoFocus(false)
  durationEdit:SetNumeric(true)
  durationEdit:SetMaxLetters(3)
  durationEdit:SetJustifyH("CENTER")

  local durationSuffix = buffsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  durationSuffix:SetPoint("LEFT", durationEdit, "RIGHT", 4, 0)
  durationSuffix:SetText("% of max")

  durationEdit:SetScript("OnEnterPressed", function(self)
    ns.Buffs:SetDurationPct(tonumber(self:GetText()) or 90)
    self:SetText(tostring(ns.Buffs:GetDurationPct()))
    self:ClearFocus()
    if ns.Tracker then ns.Tracker:Refresh() end
  end)
  durationEdit:SetScript("OnEscapePressed", function(self)
    self:SetText(tostring(ns.Buffs:GetDurationPct()))
    self:ClearFocus()
  end)

  -- Thin separator under the duration line to break it off from the list
  -- visually. Keeps the eye from blending the controls with the rows.
  local sep = buffsPage:CreateTexture(nil, "ARTWORK")
  sep:SetPoint("TOPLEFT",  durationLabel, "BOTTOMLEFT", 0, -8)
  sep:SetPoint("RIGHT",    buffsPage,     "RIGHT",     -RIGHT_PAD, 0)
  sep:SetHeight(1)
  sep:SetColorTexture(1, 1, 1, 0.1)

  -- Column header sitting just above the first row, with the label
  -- right-justified over the checkbox column. Must span the full width
  -- (TOPLEFT *and* TOPRIGHT) so its BOTTOMLEFT — which every row chains
  -- off — actually lands on the left edge of the page. Anchoring only
  -- by TOPRIGHT collapses the bounding box to a sliver on the right and
  -- pulls all the rows over with it.
  local trackHeader = buffsPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  trackHeader:SetPoint("TOPLEFT",  sep, "BOTTOMLEFT",  LEFT_PAD, -4)
  trackHeader:SetPoint("TOPRIGHT", sep, "BOTTOMRIGHT", -6,       -4)
  trackHeader:SetJustifyH("RIGHT")
  trackHeader:SetText("Track")
  trackHeader:SetTextColor(0.85, 0.85, 0.85)

  -- Per-buff config row: [icon] Name (class hint)    [✓]
  -- Icon is in a holder frame so it can carry its own mouse-enter for the
  -- spell tooltip; name fills the middle; checkbox is right-aligned.
  -- A subtle alternating row background keeps the eye on the right row
  -- when scanning down a long list.
  local BUFF_ROW_H = 26
  local function makeBuffConfigRow(buff, evenRow)
    local row = CreateFrame("Frame", nil, buffsPage)
    row:SetHeight(BUFF_ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    bg:SetColorTexture(1, 1, 1, evenRow and 0.04 or 0)

    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    cb:SetScript("OnClick", function(self)
      -- Storage is still "ignored"; UI is the inverse so tick = tracked.
      ns.Buffs:SetIgnored(buff.key, not self:GetChecked())
      if ns.Tracker then ns.Tracker:Refresh() end
    end)
    row.cb = cb

    local iconHolder = CreateFrame("Frame", nil, row)
    iconHolder:SetSize(BUFF_ROW_H - 6, BUFF_ROW_H - 6)
    iconHolder:SetPoint("LEFT", row, "LEFT", LEFT_PAD, 0)
    iconHolder:EnableMouse(true)
    row.iconHolder = iconHolder

    local iconTex = iconHolder:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints(iconHolder)
    iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    iconTex:SetTexture(ns.Buffs:IconFor(buff))

    local iconBg = iconHolder:CreateTexture(nil, "BORDER")
    iconBg:SetPoint("TOPLEFT",     iconHolder, "TOPLEFT",     -1, 1)
    iconBg:SetPoint("BOTTOMRIGHT", iconHolder, "BOTTOMRIGHT",  1, -1)
    iconBg:SetColorTexture(0, 0, 0, 0.5)

    -- Hover the icon to get the spell tooltip. Keeps the row chrome
    -- clean and lets the icon carry the detail. Falls back to
    -- SetHyperlink on clients without SetSpellByID.
    local primarySpellId = buff.spell_ids and buff.spell_ids[1]
    iconHolder:SetScript("OnEnter", function(self)
      if not primarySpellId then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if GameTooltip.SetSpellByID then
        GameTooltip:SetSpellByID(primarySpellId)
      else
        GameTooltip:SetHyperlink("spell:" .. primarySpellId)
      end
      GameTooltip:Show()
    end)
    iconHolder:SetScript("OnLeave", GameTooltip_Hide)

    local hint = ns.Buffs:ClassHint(buff)
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT",  iconHolder, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", cb,         "LEFT", -6, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    if hint then
      name:SetText(buff.name .. " |cff888888(" .. hint .. ")|r")
    else
      name:SetText(buff.name)
    end

    return row
  end

  -- Build a row per buff, stacked vertically under the column header.
  buffsPage.buffRows = {}
  local prevAnchor, prevOffset = trackHeader, -4
  local rowIndex = 0
  for _, buff in ipairs(ns.Buffs:GetCatalog()) do
    if ns.Buffs:IsApplicable(buff) then
      rowIndex = rowIndex + 1
      local row = makeBuffConfigRow(buff, rowIndex % 2 == 0)
      row.buffKey = buff.key
      row:SetPoint("TOPLEFT",  prevAnchor, "BOTTOMLEFT", 0, prevOffset)
      row:SetPoint("RIGHT",    buffsPage,  "RIGHT",     -2, 0)
      table.insert(buffsPage.buffRows, row)
      prevAnchor, prevOffset = row, 0
    end
  end

  refreshBuffsPage = function()
    if not buffsPage then return end
    durationEdit:SetText(tostring(ns.Buffs:GetDurationPct()))
    for _, row in ipairs(buffsPage.buffRows) do
      -- UI is inverse of storage: tracked = ticked, ignored = unticked.
      row.cb:SetChecked(not ns.Buffs:IsIgnored(row.buffKey))
    end
  end

  -- Settings tab page. Sits inside the same inset region as the list,
  -- only one is visible at a time. No popup, no overlay.
  settingsPage = CreateFrame("Frame", nil, mainFrame)
  settingsPage:SetPoint("TOPLEFT",     listScroll, "TOPLEFT",     0, 0)
  settingsPage:SetPoint("BOTTOMRIGHT", listScroll, "BOTTOMRIGHT", 0, 0)
  settingsPage:Hide()

  local settingsHeading = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  settingsHeading:SetPoint("TOPLEFT", settingsPage, "TOPLEFT", 4, -2)
  settingsHeading:SetText("Tracker")

  settingsPage.trackerCb = makeCheckbox(settingsPage, "Show tracker on screen")
  settingsPage.trackerCb:SetPoint("TOPLEFT", settingsHeading, "BOTTOMLEFT", -2, -6)
  settingsPage.trackerCb:SetScript("OnClick", function(self)
    if self:GetChecked() then ns.Tracker:Show() else ns.Tracker:Hide() end
  end)

  settingsPage.lockCb = makeCheckbox(settingsPage, "Lock tracker position")
  settingsPage.lockCb:SetPoint("TOPLEFT", settingsPage.trackerCb, "BOTTOMLEFT", 0, 0)
  settingsPage.lockCb:SetScript("OnClick", function(self)
    CubbyDB.tracker = CubbyDB.tracker or {}
    CubbyDB.tracker.locked = self:GetChecked() and true or false
    ns.Tracker:ApplyLock()
  end)

  -- Bank auto-shuffle controls. The disable checkbox is the escape hatch
  -- when the shuffle misbehaves (stuck cursor, "couldn't split" errors,
  -- etc.) — toggling it off immediately stops the ticker and clears the
  -- cursor so the user can use bags/bank normally again. The debug
  -- checkbox makes Bank.lua log every decision to chat.
  local bankHeading = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  bankHeading:SetPoint("TOPLEFT", settingsPage.lockCb, "BOTTOMLEFT", 2, -10)
  bankHeading:SetText("Bank")

  settingsPage.bankDisabledCb = makeCheckbox(settingsPage, "Disable bank auto-shuffle")
  settingsPage.bankDisabledCb:SetPoint("TOPLEFT", bankHeading, "BOTTOMLEFT", -2, -6)
  settingsPage.bankDisabledCb:SetScript("OnClick", function(self)
    ns.Bank:SetDisabled(self:GetChecked() and true or false)
  end)

  settingsPage.bankDebugCb = makeCheckbox(settingsPage, "Log bank actions (debug)")
  settingsPage.bankDebugCb:SetPoint("TOPLEFT", settingsPage.bankDisabledCb, "BOTTOMLEFT", 0, 0)
  settingsPage.bankDebugCb:SetScript("OnClick", function(self)
    CubbyDB.bank = CubbyDB.bank or {}
    CubbyDB.bank.debug = self:GetChecked() and true or false
  end)

  -- The lines are always captured to a saved-vars ring buffer (see Bank.lua)
  -- regardless of the debug checkbox; this button just opens the copy popup.
  settingsPage.bankLogBtn = CreateFrame("Button", nil, settingsPage, "UIPanelButtonTemplate")
  settingsPage.bankLogBtn:SetSize(90, 22)
  settingsPage.bankLogBtn:SetPoint("TOPLEFT", settingsPage.bankDebugCb, "BOTTOMLEFT", 4, -4)
  settingsPage.bankLogBtn:SetText("Show log")
  settingsPage.bankLogBtn:SetScript("OnClick", function() UI:ShowBankLog() end)

  -- Buff-decode diagnostic. Opens a copyable snapshot of what Cubby's
  -- Chronoboon decode currently sees — API detection, raw AuraData points,
  -- flattened tuple, and slot-map cross-check. Paste the output when
  -- reporting buff-detection weirdness.
  settingsPage.buffDebugBtn = CreateFrame("Button", nil, settingsPage,
    "UIPanelButtonTemplate")
  settingsPage.buffDebugBtn:SetSize(110, 22)
  settingsPage.buffDebugBtn:SetPoint("LEFT", settingsPage.bankLogBtn, "RIGHT", 6, 0)
  settingsPage.buffDebugBtn:SetText("Buff debug")
  settingsPage.buffDebugBtn:SetScript("OnClick", function() UI:ShowBuffLog() end)

  -- Tick interval (ms). Higher = more time for the client/server to settle
  -- between container actions, which tends to eliminate "Couldn't split"
  -- rejections at the cost of slower bank visits. Reads on the next Start /
  -- Refresh — no need to relog. Bank.lua clamps the value to a safe range.
  local intervalLabel = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  intervalLabel:SetPoint("TOPLEFT", settingsPage.bankLogBtn, "BOTTOMLEFT", -4, -8)
  intervalLabel:SetText("Move interval:")

  settingsPage.bankIntervalEdit = CreateFrame("EditBox", nil, settingsPage, "InputBoxTemplate")
  settingsPage.bankIntervalEdit:SetPoint("LEFT", intervalLabel, "RIGHT", 8, 0)
  settingsPage.bankIntervalEdit:SetSize(48, 20)
  settingsPage.bankIntervalEdit:SetAutoFocus(false)
  settingsPage.bankIntervalEdit:SetNumeric(true)
  settingsPage.bankIntervalEdit:SetMaxLetters(4)
  settingsPage.bankIntervalEdit:SetJustifyH("CENTER")

  local intervalSuffix = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  intervalSuffix:SetPoint("LEFT", settingsPage.bankIntervalEdit, "RIGHT", 4, 0)
  intervalSuffix:SetText("ms")

  local function commitInterval(self)
    CubbyDB.bank = CubbyDB.bank or {}
    local n = tonumber(self:GetText()) or 500
    if n < 100 then n = 100 end
    if n > 5000 then n = 5000 end
    CubbyDB.bank.intervalMs = n
    self:SetText(tostring(n))
    self:ClearFocus()
  end
  settingsPage.bankIntervalEdit:SetScript("OnEnterPressed", commitInterval)
  settingsPage.bankIntervalEdit:SetScript("OnEscapePressed", function(self)
    self:SetText(tostring((CubbyDB.bank and CubbyDB.bank.intervalMs) or 500))
    self:ClearFocus()
  end)

  -- Tab buttons hang below the bottom edge, Blizzard-classic style.
  -- Using CharacterFrameTabButtonTemplate + PanelTemplates_SetNumTabs to
  -- get the standard 9-slice tab look.
  -- PanelTemplates_SetTab looks the buttons up via the global name
  -- pattern "<frameName>Tab<id>". The names MUST match that or it
  -- crashes with "attempt to index local 'tab' (a nil value)". Our frame
  -- is CubbyFrame, so tabs are named CubbyFrameTab1, CubbyFrameTab2, …
  local function makeTab(id, label)
    local tab = CreateFrame("Button", "CubbyFrameTab" .. id, mainFrame,
      "CharacterFrameTabButtonTemplate")
    tab:SetID(id)
    tab:SetText(label)
    tab:SetScript("OnClick", function(self) showTab(self:GetID()) end)
    if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end
    tabButtons[id] = tab
    return tab
  end

  local itemsTab    = makeTab(1, "Items")
  local buffsTab    = makeTab(2, "Buffs")
  local settingsTab = makeTab(3, "Settings")
  itemsTab   :SetPoint("TOPLEFT", mainFrame, "BOTTOMLEFT", 14,  6)
  buffsTab   :SetPoint("LEFT",    itemsTab,  "RIGHT",      -16, 0)
  settingsTab:SetPoint("LEFT",    buffsTab,  "RIGHT",      -16, 0)
  if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(mainFrame, 3) end

  -- Register the items-tab widgets so showTab() can toggle them as a group.
  itemsTabWidgets = {
    searchBox, missingCb, missingLabel, refreshBtn,
    listScroll, dropZone, statusText,
  }

  showTab(1)
  refreshSettingsPage()

  UI:ApplyPosition()
  mainFrame:Hide()
end
