local ADDON_NAME, ns = ...

ns.Restock = {}
local Restock = ns.Restock

local lastRun = 0

local function getMerchantStack(slot)
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local info = C_MerchantFrame.GetItemInfo(slot)
    if info then
      return info.stackCount or 1, info.numAvailable or -1
    end
  end
  local _, _, _, stackCount, numAvailable = GetMerchantItemInfo(slot)
  return stackCount or 1, numAvailable or -1
end

function Restock:OnMerchantShow()
  local now = GetTime()
  if now - lastRun < 0.5 then return end
  lastRun = now

  if not CubbyDB or not CubbyDB.items then return end

  local wantById = {}
  local any = false
  for id, item in pairs(CubbyDB.items) do
    local target = item.target or 0
    if target > 0 then
      local have = GetItemCount(id, false, false) or 0
      local need = target - have
      if need > 0 then
        wantById[id] = need
        any = true
      end
    end
  end
  if not any then return end

  local purchases = 0
  for slot = 1, GetMerchantNumItems() do
    local link = GetMerchantItemLink(slot)
    local id = link and tonumber(link:match("item:(%d+)"))
    local need = id and wantById[id]
    if need and need > 0 then
      local stackCount, numAvailable = getMerchantStack(slot)
      stackCount = math.max(1, stackCount)
      local cap = need
      if numAvailable and numAvailable > 0 and cap > numAvailable then
        cap = numAvailable
      end
      while cap > 0 do
        local n = math.min(cap, stackCount)
        BuyMerchantItem(slot, n)
        cap = cap - n
        purchases = purchases + 1
      end
      wantById[id] = 0
    end
  end

  if purchases > 0 then
    ns.Cubby:Print("Restocked " .. purchases .. " stack" .. (purchases == 1 and "" or "s") .. ".")
  end
end
