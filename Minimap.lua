local ADDON_NAME, ns = ...

local MM_RADIUS = 80

ns.Minimap = {}
local M = ns.Minimap

local button

local function setPosFromAngle(angle)
  if not button then return end
  local x = MM_RADIUS * math.cos(angle)
  local y = MM_RADIUS * math.sin(angle)
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function M:SetAngle(angle)
  setPosFromAngle(angle)
end

function M:Build()
  if button then return end

  local b = CreateFrame("Button", "CubbyMinimapButton", Minimap)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:SetSize(31, 31)
  b:SetMovable(true)
  b:RegisterForClicks("LeftButtonUp")
  b:RegisterForDrag("LeftButton")

  local icon = b:CreateTexture(nil, "ARTWORK")
  local ok = icon:SetTexture("Interface\\AddOns\\Cubby\\Cubby.tga")
  if ok == false or not icon:GetTexture() then
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Green")
  end
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER", 0, 0)
  if icon.SetMask then
    pcall(function()
      icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    end)
  end

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(54, 54)
  border:SetPoint("TOPLEFT")

  local highlight = b:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  highlight:SetBlendMode("ADD")
  highlight:SetSize(31, 31)
  highlight:SetPoint("CENTER")

  b:SetScript("OnClick", function()
    ns.UI:Toggle()
  end)

  b:SetScript("OnDragStart", function(self)
    self:LockHighlight()
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local px, py = GetCursorPosition()
      local s = Minimap:GetEffectiveScale()
      px, py = px / s, py / s
      local angle = math.atan2(py - my, px - mx)
      setPosFromAngle(angle)
      CubbyDB.mmAngle = angle
    end)
  end)

  b:SetScript("OnDragStop", function(self)
    self:UnlockHighlight()
    self:SetScript("OnUpdate", nil)
  end)

  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Cubby", 1, 1, 1)
    GameTooltip:AddLine("Click: open Cubby", 0.85, 0.85, 0.85)
    GameTooltip:AddLine("Drag: reposition on minimap", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  button = b
  setPosFromAngle(CubbyDB.mmAngle or math.rad(225))
end
