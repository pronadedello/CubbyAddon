local ADDON_NAME, ns = ...

ns.Bank = {}
local Bank = ns.Bank

-- Default tick interval between container actions, in seconds. The actual
-- interval is read from CubbyDB.bank.intervalMs at Start time so the user
-- can dial it up on the Settings tab when they hit rejections. Clamped to a
-- sane range when read.
local DEFAULT_INTERVAL_MS = 500
local MIN_INTERVAL_MS, MAX_INTERVAL_MS = 100, 5000

local function currentInterval()
  local ms = (CubbyDB and CubbyDB.bank and CubbyDB.bank.intervalMs) or DEFAULT_INTERVAL_MS
  if type(ms) ~= "number" then ms = DEFAULT_INTERVAL_MS end
  if ms < MIN_INTERVAL_MS then ms = MIN_INTERVAL_MS end
  if ms > MAX_INTERVAL_MS then ms = MAX_INTERVAL_MS end
  return ms / 1000
end

-- Watchdog: how many consecutive ticks we'll wait on a locked source slot
-- before giving up and moving on. A genuine lock from a split/pickup clears
-- in 1–2 ticks; anything longer is either stuck server-side or a slot that
-- (mis-)reports `isLocked` permanently. Without this, the ticker spins on
-- the first locked slot forever and no other item ever gets a turn.
local MAX_WAITS = 10

local BANK_CONTAINER     = BANK_CONTAINER     or -1
local BACKPACK_CONTAINER = BACKPACK_CONTAINER or 0
local NUM_BAG_SLOTS_LOC  = NUM_BAG_SLOTS      or 4
local NUM_BANKBAGSLOTS_LOC = NUM_BANKBAGSLOTS or 7

local moveQueue = {}
local ticker
Bank.bankOpen = false

-- Forward-declared so Bank:OnUIError (defined just below) and the
-- retroactive failure check in executeNext share the *same* upvalues —
-- otherwise OnUIError ends up writing to a stray global of the same name
-- and the check never sees it. Real values are set in Start / when a move
-- is actually issued.
local lastIssued    = nil
local lastWasStack  = false
local sawUIError    = false

-- Kill switch + verbose log gated by CubbyDB.bank (see Cubby.lua defaults).
-- isDisabled() guards every entry point; dprint() is a no-op unless the user
-- ticked the Settings → Bank debug checkbox.
local function isDisabled()
  return CubbyDB and CubbyDB.bank and CubbyDB.bank.disabled == true
end

-- Capped persistent log buffer. Always populates regardless of the debug
-- checkbox — that way the lines are already there to copy from Settings →
-- Show log even if the user only thought to turn debugging on after the
-- problem. The chat echo is the only thing the checkbox gates.
local LOG_MAX = 500

local function ensureLog()
  CubbyDB.bank = CubbyDB.bank or { disabled = false, debug = false }
  CubbyDB.bank.log = CubbyDB.bank.log or {}
  return CubbyDB.bank.log
end

local function pushLog(line)
  if not CubbyDB then return end
  local log = ensureLog()
  table.insert(log, string.format("[%s] %s", date("%H:%M:%S"), line))
  while #log > LOG_MAX do table.remove(log, 1) end
end

local function dprint(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do parts[i] = tostring((select(i, ...))) end
  local msg = table.concat(parts, " ")
  pushLog(msg)
  if CubbyDB and CubbyDB.bank and CubbyDB.bank.debug and ns.Cubby then
    ns.Cubby:Print("Bank: " .. msg)
  end
end

function Bank:GetLog()
  return table.concat(ensureLog(), "\n")
end

function Bank:ClearLog()
  if CubbyDB and CubbyDB.bank then CubbyDB.bank.log = {} end
end

-- Dispatched from Cubby.lua's central event frame when WoW posts to its
-- UIErrors area ("Couldn't split those items", "Inventory is full", etc.).
-- We only care about errors while a Bank run is active — random UI errors
-- from combat shouldn't pollute the log.
function Bank:OnUIError(_errorType, msg)
  if not ticker or not msg then return end
  pushLog("UI error: " .. tostring(msg))
  -- These are the server rejections that mean "your last container action
  -- didn't actually happen." We arm a flag the next tick will react to.
  -- Plain `find` with plain=true keeps it case-sensitive but fast; the
  -- canonical Blizzard strings are all capitalised.
  if msg:find("Couldn't", 1, true) or msg:find("locked", 1, true)
      or msg:find("split", 1, true) then
    sawUIError = true
  end
end

local function itemLabel(itemId)
  if not itemId then return "?" end
  local name = GetItemInfo(itemId)
  return (name or ("item:" .. tostring(itemId)))
end

local function getContainerItemInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    return C_Container.GetContainerItemInfo(bag, slot)
  end
  return nil
end

local function getContainerNumSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then
    return C_Container.GetContainerNumSlots(bag) or 0
  end
  return 0
end

local function useContainerItem(bag, slot)
  if C_Container and C_Container.UseContainerItem then
    C_Container.UseContainerItem(bag, slot)
  else
    UseContainerItem(bag, slot)
  end
end

local function splitContainerItem(bag, slot, count)
  if C_Container and C_Container.SplitContainerItem then
    C_Container.SplitContainerItem(bag, slot, count)
  else
    SplitContainerItem(bag, slot, count)
  end
end

local function pickupContainerItem(bag, slot)
  if C_Container and C_Container.PickupContainerItem then
    C_Container.PickupContainerItem(bag, slot)
  else
    PickupContainerItem(bag, slot)
  end
end

-- Reservations on destination slots we've already issued a pickup into this
-- run. The client's container cache lags the server by a tick or two after
-- a split+pickup, so firstEmptyBagSlot() would otherwise hand back the same
-- slot for every queued partial — every subsequent pickup then collides on
-- the (server-side already occupied) slot and Blizzard fires "couldn't split
-- those items." Entries are aged each tick: dropped once the slot is
-- observed occupied (= the move landed) or after RESERVE_TTL ticks (= it
-- never will, so don't reserve forever).
--
-- Must sit *below* getContainerItemInfo so ageReservations() captures it as
-- an upvalue, not the (nil) global of the same name.
local pendingDests = {}
local RESERVE_TTL = 15  -- 3s at the 0.2s tick

-- Replan-once retry. A bank slot can report `isLocked=true` for the entire
-- duration of one queue run (whatever Blizzard's reason) and then clear by
-- the time we'd be done with everything else. So when the queue drains and
-- anything was abandoned, we wait a moment and re-plan once. Bounded by
-- MAX_REPLAN_ATTEMPTS so a genuinely-stuck slot doesn't trap us in a loop.
local hadAbandon = false
local replanAttempts = 0
local MAX_REPLAN_ATTEMPTS = 5

-- Slots whose source side reports a permanent isLocked=true. We mark on
-- abandon and exclude in subsequent planMoves passes, so the replan picks
-- a *different* stack of the same item rather than re-trying the wedged
-- one. Cleared on fresh Start / Stop so a new bank visit starts blank.
local lockedSlots = {}

-- Slots where a partial split() failed (UI error "Couldn't split those
-- items"). Almost always a cache/server mismatch — the client thinks the
-- stack has N items, but the server has fewer, so split(planned-count) is
-- rejected. For those slots we fall back to useContainerItem, which moves
-- whatever is *actually* there regardless of count. Overshoot is fine
-- (the next plan will stash the excess back). Cleared on fresh Start.
local splitFailedSlots = {}

-- Per-run stats. Printed once when the queue drains so the user has a tidy
-- recap to copy alongside the per-move lines, rather than counting by eye.
local runStats = { full = 0, stacked = 0, empty = 0, abandoned = 0, splitFailed = 0 }
local function resetStats()
  runStats.full = 0; runStats.stacked = 0; runStats.empty = 0
  runStats.abandoned = 0; runStats.splitFailed = 0
end

-- Per-cycle progress fed to UI:SetBankProgress so the user sees a bar
-- while Bank is working. Reset on every fresh plan (Start + replan);
-- hidden on final drain / Stop / Refresh.
local cycleTotal, cycleLabel = 0, ""

local function describeQueue(queue)
  local w, s = 0, 0
  for _, m in ipairs(queue) do
    if m.dir == "withdraw" then w = w + 1 else s = s + 1 end
  end
  if w > 0 and s == 0 then return string.format("Withdrawing %d", w)  end
  if s > 0 and w == 0 then return string.format("Stashing %d",    s)  end
  return string.format("Shuffling %d", w + s)
end

local function startCycleProgress()
  cycleTotal = #moveQueue
  cycleLabel = describeQueue(moveQueue)
  if cycleTotal > 0 and ns.UI and ns.UI.SetBankProgress then
    ns.UI:SetBankProgress(0, cycleTotal, cycleLabel, "")
  end
end

local function updateCycleProgress(detail)
  if cycleTotal <= 0 or not ns.UI or not ns.UI.SetBankProgress then return end
  local done = cycleTotal - #moveQueue
  if done < 0 then done = 0 end
  ns.UI:SetBankProgress(done, cycleTotal, cycleLabel, detail or "")
end

local function hideCycleProgress()
  cycleTotal = 0
  if ns.UI and ns.UI.HideBankProgress then ns.UI:HideBankProgress() end
end

-- (lastIssued / lastWasStack / sawUIError live near the top of the file,
-- forward-declared above Bank:OnUIError so both reference the same upvalue.)

local function destKey(bag, slot) return bag .. ":" .. slot end

local function reserveDest(bag, slot)
  pendingDests[destKey(bag, slot)] = 0
end

local function isReserved(bag, slot)
  return pendingDests[destKey(bag, slot)] ~= nil
end

local function ageReservations()
  for k, age in pairs(pendingDests) do
    local b, s = k:match("(%-?%d+):(%d+)")
    b, s = tonumber(b), tonumber(s)
    local info = b and getContainerItemInfo(b, s)
    if info and info.itemID then
      pendingDests[k] = nil           -- landed
    elseif age >= RESERVE_TTL then
      pendingDests[k] = nil           -- gave up waiting; fall through
    else
      pendingDests[k] = age + 1
    end
  end
end

local function playerBagIds()
  local ids = { BACKPACK_CONTAINER }
  for i = 1, NUM_BAG_SLOTS_LOC do table.insert(ids, i) end
  return ids
end

local function bankBagIds()
  local ids = { BANK_CONTAINER }
  for i = NUM_BAG_SLOTS_LOC + 1, NUM_BAG_SLOTS_LOC + NUM_BANKBAGSLOTS_LOC do
    table.insert(ids, i)
  end
  return ids
end

-- Scan a list of bags, returning { [itemId] = { count=N, slots={ {bag,slot,count}, ... } } }
local function scan(bags)
  local out = {}
  for _, bag in ipairs(bags) do
    local n = getContainerNumSlots(bag)
    for slot = 1, n do
      local info = getContainerItemInfo(bag, slot)
      if info and info.itemID then
        local id = info.itemID
        local cnt = info.stackCount or 1
        local entry = out[id]
        if not entry then
          entry = { count = 0, slots = {} }
          out[id] = entry
        end
        entry.count = entry.count + cnt
        table.insert(entry.slots, { bag = bag, slot = slot, count = cnt })
      end
    end
  end
  return out
end

-- Find an empty slot in the player's bags (or backpack first). Skips slots
-- we've already reserved this tick burst — see pendingDests above.
local function firstEmptyBagSlot()
  for _, bag in ipairs(playerBagIds()) do
    local n = getContainerNumSlots(bag)
    for slot = 1, n do
      if not getContainerItemInfo(bag, slot) and not isReserved(bag, slot) then
        return bag, slot
      end
    end
  end
  return nil, nil
end

local function firstEmptyBankSlot()
  for _, bag in ipairs(bankBagIds()) do
    local n = getContainerNumSlots(bag)
    for slot = 1, n do
      if not getContainerItemInfo(bag, slot) and not isReserved(bag, slot) then
        return bag, slot
      end
    end
  end
  return nil, nil
end

-- Stacking targets. Same lag story as pendingDests: when we pickup N items
-- onto a non-empty same-item slot, the slot's stackCount won't reflect that
-- for a tick or two, so we'd otherwise oversend on the next tick. pendingAdds
-- tracks the in-flight adds so the room calculation stays honest.
local pendingAdds = {}

local function pendingAddAt(bag, slot)
  local e = pendingAdds[destKey(bag, slot)]
  return e and e.added or 0
end

local function noteStackedAdd(bag, slot, count)
  local k = destKey(bag, slot)
  local e = pendingAdds[k] or { added = 0, age = 0 }
  e.added = e.added + count
  e.age = 0
  pendingAdds[k] = e
end

local function agePendingAdds()
  for k, e in pairs(pendingAdds) do
    e.age = e.age + 1
    if e.age >= RESERVE_TTL then pendingAdds[k] = nil end
  end
end

-- Look for an existing same-item stack on the receiving side that has at
-- least `count` headroom (real stack count + already-in-flight adds). When
-- found, the next partial pickup drops into it — keeps bags compact, the
-- user's actual ask. Returns nil if no room or max-stack info isn't cached.
local function findStackableSlotIn(bagIds, itemId, count)
  if not itemId or not count or count <= 0 then return nil end
  local _, _, _, _, _, _, _, maxStack = GetItemInfo(itemId)
  if not maxStack or maxStack <= 1 then return nil end
  for _, bag in ipairs(bagIds()) do
    local n = getContainerNumSlots(bag)
    for slot = 1, n do
      local info = getContainerItemInfo(bag, slot)
      if info and info.itemID == itemId then
        local cur = (info.stackCount or 0) + pendingAddAt(bag, slot)
        if (maxStack - cur) >= count then
          return bag, slot
        end
      end
    end
  end
end

local function findStackableBagSlot(itemId, count)
  return findStackableSlotIn(playerBagIds, itemId, count)
end

local function findStackableBankSlot(itemId, count)
  return findStackableSlotIn(bankBagIds, itemId, count)
end

-- Subset of `stacks` whose total count is the largest possible value ≤
-- `limit`. Returns total and the picked entries. Used by planMoves on both
-- withdraw and stash so each phase converges to a stable state: withdraw
-- never overshoots `need` (no excess to stash), stash never overshoots
-- `excess` (no shortfall to re-withdraw). With strict full-only moves
-- this is the only way to break the withdraw-→-stash-→-withdraw loop
-- that descending greedy produced.
--
-- Exhaustive for n ≤ 14 (16k subsets — instant). Falls back to descending
-- greedy beyond that, which is a tiny accuracy loss for very fragmented
-- stacks. Empty pick is returned if no single stack fits under `limit`.
local function bestSubsetLE(stacks, limit)
  if limit <= 0 then return 0, {} end
  local n = #stacks
  if n == 0 then return 0, {} end
  if n > 14 then
    local sorted = {}
    for _, s in ipairs(stacks) do table.insert(sorted, s) end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    local taken, picked = 0, {}
    for _, s in ipairs(sorted) do
      if taken + s.count <= limit then
        taken = taken + s.count
        table.insert(picked, s)
      end
    end
    return taken, picked
  end
  local best, bestMask = 0, 0
  for mask = 1, (2 ^ n) - 1 do
    local sum, m = 0, mask
    for i = 1, n do
      if m % 2 == 1 then sum = sum + stacks[i].count end
      m = math.floor(m / 2)
    end
    if sum <= limit and sum > best then
      best, bestMask = sum, mask
    end
  end
  local picked = {}
  if bestMask > 0 then
    local m = bestMask
    for i = 1, n do
      if m % 2 == 1 then table.insert(picked, stacks[i]) end
      m = math.floor(m / 2)
    end
  end
  return best, picked
end

local function planMoves()
  if not CubbyDB or not CubbyDB.items then return {} end

  local inBag  = scan(playerBagIds())
  local inBank = scan(bankBagIds())
  local moves = {}

  local withdrawCount, stashCount = 0, 0

  -- Pulls the usable (non-blacklisted) slots + total count for `id` out of
  -- a scan result. Used for both directions so withdraw and stash both
  -- skip the same wedged source slots.
  local function usable(byId, id)
    local entry = byId[id]
    if not entry then return 0, {} end
    local slots, count = {}, 0
    for _, s in ipairs(entry.slots) do
      if not lockedSlots[destKey(s.bag, s.slot)] then
        table.insert(slots, s)
        count = count + s.count
      end
    end
    return count, slots
  end

  for id, item in pairs(CubbyDB.items) do
    local target = item.target or 0
    if target > 0 then
      local bagCount  = (inBag[id]  and inBag[id].count)  or 0
      local bankCount = (inBank[id] and inBank[id].count) or 0
      local need = target - bagCount

      if need > 0 then
        local usableBank, usableBankSlots = usable(inBank, id)
        if usableBank > 0 then
          withdrawCount = withdrawCount + 1
          dprint(string.format("plan withdraw %s: bag=%d, bank=%d, target=%d, need=%d",
            itemLabel(id), bagCount, bankCount, target, need))
          -- Three-tier strategy. Splits *do* work reliably when they're
          -- the *only* move for an item — failures only happened when a
          -- partial followed a useContainerItem of the same item from
          -- the same bag. So:
          --   1. exact-sum full stacks if any combination sums to `need`,
          --   2. otherwise a single partial split — guaranteed safe
          --      because we don't emit any other move for this item,
          --   3. otherwise undershoot (no stack > need, no exact sum).
          local taken, picked = bestSubsetLE(usableBankSlots, need)
          if taken == need then
            dprint(string.format("  → withdrawing %d via %d full stack(s) (exact)",
              taken, #picked))
            for _, s in ipairs(picked) do
              table.insert(moves, { dir = "withdraw", itemID = id, bag = s.bag, slot = s.slot, count = s.count, full = true })
            end
          else
            local partialStack
            for _, s in ipairs(usableBankSlots) do
              if s.count > need and (not partialStack or s.count < partialStack.count) then
                partialStack = s
              end
            end
            if partialStack then
              dprint(string.format("  → withdrawing %d via single partial split from stack of %d",
                need, partialStack.count))
              table.insert(moves, { dir = "withdraw", itemID = id, bag = partialStack.bag, slot = partialStack.slot, count = need, full = false })
            else
              dprint(string.format("  → withdrawing %d via %d full stack(s) (undershoot — no stack has > %d)",
                taken, #picked, need))
              for _, s in ipairs(picked) do
                table.insert(moves, { dir = "withdraw", itemID = id, bag = s.bag, slot = s.slot, count = s.count, full = true })
              end
            end
          end
        end
      elseif need < 0 then
        local usableBag, usableBagSlots = usable(inBag, id)
        if usableBag > 0 then
          stashCount = stashCount + 1
          dprint(string.format("plan stash %s: bag=%d, target=%d, excess=%d",
            itemLabel(id), bagCount, target, -need))
          -- Same three-tier strategy as withdraw: exact full stacks if
          -- possible, otherwise a single partial split, otherwise
          -- subset-LE undershoot. Stash partials are equally safe in
          -- isolation — no preceding same-item move triggers the lock.
          local needStash = -need
          local stashed, picked = bestSubsetLE(usableBagSlots, needStash)
          if stashed == needStash then
            dprint(string.format("  → stashing %d via %d full stack(s) (exact)",
              stashed, #picked))
            for _, s in ipairs(picked) do
              table.insert(moves, { dir = "stash", itemID = id, bag = s.bag, slot = s.slot, count = s.count, full = true })
            end
          else
            local partialStack
            for _, s in ipairs(usableBagSlots) do
              if s.count > needStash and (not partialStack or s.count < partialStack.count) then
                partialStack = s
              end
            end
            if partialStack then
              dprint(string.format("  → stashing %d via single partial split from stack of %d",
                needStash, partialStack.count))
              table.insert(moves, { dir = "stash", itemID = id, bag = partialStack.bag, slot = partialStack.slot, count = needStash, full = false })
            else
              dprint(string.format("  → stashing %d via %d full stack(s) (undershoot — no stack has > %d)",
                stashed, #picked, needStash))
              for _, s in ipairs(picked) do
                table.insert(moves, { dir = "stash", itemID = id, bag = s.bag, slot = s.slot, count = s.count, full = true })
              end
            end
          end
        end
      end
    end
  end

  local fullCount, partialCount = 0, 0
  for _, m in ipairs(moves) do
    if m.full then fullCount = fullCount + 1 else partialCount = partialCount + 1 end
  end
  dprint(string.format("planned %d moves (%d withdraw groups, %d stash groups; %d full, %d partial)",
    #moves, withdrawCount, stashCount, fullCount, partialCount))
  return moves
end

local function isSlotLocked(bag, slot)
  local info = getContainerItemInfo(bag, slot)
  -- Strict-equality on purpose: `isLocked` is documented bool, and a stray
  -- truthy value of a different shape (number, table) should not strand us.
  return info and info.isLocked == true
end

-- Reads the current item name out of each blacklisted slot. Used to tell
-- the user *which* items couldn't be withdrawn after the replans exhaust.
local function lockedItemNames()
  local seen, out = {}, {}
  for k in pairs(lockedSlots) do
    local b, s = k:match("(%-?%d+):(%d+)")
    b, s = tonumber(b), tonumber(s)
    local info = b and getContainerItemInfo(b, s)
    local id = info and info.itemID
    local name = id and itemLabel(id)
    if name and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  return out
end

local function executeNext()
  -- Hard guard: bank must still be open. UseContainerItem on a bag slot
  -- with the bank closed CONSUMES the item (drinks potions, eats food).
  if not Bank.bankOpen then
    Bank:Stop()
    return
  end

  -- User toggled the kill switch mid-run — abandon everything.
  if isDisabled() then
    dprint("disabled mid-run, stopping")
    Bank:Stop()
    return
  end

  -- Safety net: if a previous tick left something on the cursor (a partial
  -- split that couldn't drop), put it back before doing anything else.
  if CursorHasItem and CursorHasItem() then
    dprint("cursor non-empty at tick start, clearing")
    ClearCursor()
    return -- give WoW a tick to settle, retry next
  end

  -- Did WoW reject the last move we issued? `sawUIError` was set by
  -- Bank:OnUIError between this tick and the previous one. Two paths:
  --   * partial split rejected → almost always stale-count; mark the
  --     slot split-failed and re-queue the same move as a full move
  --     (useContainerItem ignores count and just moves whatever's
  --     actually there). Overshoot gets stashed on the next plan.
  --   * full move rejected → genuinely stuck server-side; blacklist and
  --     let the user know after replan exhaustion.
  -- Also captures the post-error source-slot state so the log says what
  -- the client *thought* the slot looked like at the moment of failure.
  if sawUIError and lastIssued then
    local m = lastIssued
    local postInfo = getContainerItemInfo(m.bag, m.slot)
    local postDesc = postInfo
      and string.format("id=%s count=%d locked=%s",
            tostring(postInfo.itemID), postInfo.stackCount or 0,
            tostring(postInfo.isLocked))
      or "empty"

    if m.full then
      dprint(string.format("full move rejected: %s %s bag=%d slot=%d (src now: %s) → blacklisting",
        m.dir, itemLabel(m.itemID), m.bag, m.slot, postDesc))
      lockedSlots[destKey(m.bag, m.slot)] = true
      runStats.full = runStats.full - 1
      runStats.splitFailed = runStats.splitFailed + 1
      hadAbandon = true
    else
      dprint(string.format("split rejected: %s %s bag=%d slot=%d (src now: %s) → retrying as full",
        m.dir, itemLabel(m.itemID), m.bag, m.slot, postDesc))
      splitFailedSlots[destKey(m.bag, m.slot)] = true
      runStats.splitFailed = runStats.splitFailed + 1
      if lastWasStack then
        runStats.stacked = runStats.stacked - 1
      else
        runStats.empty = runStats.empty - 1
      end
      -- Re-queue at front as a full move *if* the slot still holds the
      -- expected item. useContainerItem doesn't read m.count, but we
      -- record whatever the client now thinks so the log line is honest.
      if postInfo and postInfo.itemID == m.itemID and (postInfo.stackCount or 0) > 0 then
        table.insert(moveQueue, 1, {
          dir = m.dir, itemID = m.itemID,
          bag = m.bag, slot = m.slot,
          count = postInfo.stackCount, full = true, retried = true,
        })
      else
        -- Slot drained or item changed; nothing to retry. Treat as abandon
        -- so the replan path gets a chance at any other usable stacks.
        hadAbandon = true
      end
    end
    if CursorHasItem and CursorHasItem() then ClearCursor() end
  end
  sawUIError = false
  lastIssued = nil

  -- Age the destination reservations *before* picking the next move, so
  -- a slot we wrote to last tick gets released as soon as the client's
  -- container cache catches up. Same for pending stack-adds.
  ageReservations()
  agePendingAdds()

  if #moveQueue == 0 then
    if ticker then ticker:Cancel() end
    ticker = nil
    dprint(string.format("queue drained: %d full, %d stacked, %d into empty, %d abandoned, %d split-failed",
      runStats.full, runStats.stacked, runStats.empty, runStats.abandoned, runStats.splitFailed))
    -- One retry: if the just-finished run abandoned any moves (persistently
    -- locked source slots), pause briefly so the locks can clear, then
    -- re-plan. Items still need-met after the retry stay that way.
    if replanAttempts < MAX_REPLAN_ATTEMPTS then
      -- Always re-plan once the queue drains, not only on abandons. The
      -- split-rejection → full-stack retry path can overshoot the target
      -- (planned ×4 became ×5 because the whole stack moved), and the
      -- only way to catch that automatically is to scan again and let
      -- planMoves emit stashes for the excess. If there's genuinely
      -- nothing left to do, the replan prints "nothing to do" and we
      -- stop naturally.
      replanAttempts = replanAttempts + 1
      local why = hadAbandon and "abandons" or "scanning for overshoot"
      hadAbandon = false
      dprint(string.format("queue drained; replan attempt %d (%s) in 0.5s",
        replanAttempts, why))
      C_Timer.After(0.5, function()
        if not Bank.bankOpen or isDisabled() or ticker then return end
        pendingDests = {}
        pendingAdds = {}
        moveQueue = planMoves()
        if #moveQueue == 0 then
          dprint("replan: nothing to do")
          hideCycleProgress()
          if ns.UI then ns.UI:RefreshStatuses() end
          return
        end
        dprint(string.format("replan: ticker on, %d moves queued", #moveQueue))
        startCycleProgress()
        ticker = C_Timer.NewTicker(currentInterval(), executeNext)
      end)
    else
      -- We've given up on the locked slots. Surface a user-actionable
      -- message naming the items so they're not left guessing why the
      -- counts didn't reach target. WoW is telling us those slots are
      -- locked; the user can usually clear that by clicking the item in
      -- the bank window — and then `/cubby bank retry` re-runs without
      -- needing to close+reopen the bank.
      if hadAbandon then
        local names = lockedItemNames()
        if #names > 0 and ns.Cubby then
          -- After 5 auto-retries the slots are almost certainly genuinely
          -- locked server-side; closing+reopening the bank (or a relog) is
          -- the only thing that'll move them. Phrased as info, not a chore.
          ns.Cubby:Print(string.format(
            "couldn't withdraw %s — slot(s) stayed locked. Closing and reopening the bank usually clears it.",
            table.concat(names, ", ")))
        end
      end
      hideCycleProgress()
      if ns.UI then ns.UI:RefreshStatuses() end
    end
    return
  end

  local m = moveQueue[1]

  -- If the source slot is mid-animation (locked from a previous move), wait
  -- — but cap how long. The original spin-forever behaviour wedged Bank on
  -- the first persistently-locked slot and blocked every other queued move.
  if isSlotLocked(m.bag, m.slot) then
    m.waits = (m.waits or 0) + 1
    if m.waits == 1 then
      local srcInfo = getContainerItemInfo(m.bag, m.slot)
      local itemId = srcInfo and srcInfo.itemID
      dprint(string.format("wait: %s %s bag=%d slot=%d locked",
        m.dir, itemLabel(itemId), m.bag, m.slot))
    end
    if m.waits > MAX_WAITS then
      local srcInfo = getContainerItemInfo(m.bag, m.slot)
      local itemId = srcInfo and srcInfo.itemID
      dprint(string.format("abandon: %s %s bag=%d slot=%d (locked %d ticks)",
        m.dir, itemLabel(itemId), m.bag, m.slot, m.waits))
      table.remove(moveQueue, 1)
      hadAbandon = true
      runStats.abandoned = runStats.abandoned + 1
      -- Blacklist so the next replan picks a different stack of this item
      -- instead of re-queuing exactly this wedged slot.
      lockedSlots[destKey(m.bag, m.slot)] = true
    end
    return
  end

  -- Re-validate: the slot might be empty now, hold a different item, or
  -- hold fewer than we planned to take (the user clicked things, or a
  -- previous move shifted state, or the container cache was stale at
  -- plan time). Drop stale moves silently; the next planMoves will pick
  -- up any genuine remaining need.
  local srcInfo = getContainerItemInfo(m.bag, m.slot)
  if not srcInfo or not srcInfo.itemID then
    dprint(string.format("drop stale move: %s bag=%d slot=%d (slot now empty)",
      m.dir, m.bag, m.slot))
    table.remove(moveQueue, 1)
    return
  end
  if m.itemID and srcInfo.itemID ~= m.itemID then
    dprint(string.format("drop stale move: %s bag=%d slot=%d (item changed: expected %s, got %s)",
      m.dir, m.bag, m.slot, itemLabel(m.itemID), itemLabel(srcInfo.itemID)))
    table.remove(moveQueue, 1)
    return
  end
  if (srcInfo.stackCount or 0) < m.count then
    dprint(string.format("drop stale move: %s %s bag=%d slot=%d (have %d, planned %d)",
      m.dir, itemLabel(srcInfo.itemID), m.bag, m.slot, srcInfo.stackCount or 0, m.count))
    table.remove(moveQueue, 1)
    return
  end

  -- Pick a destination on the receiving side. For partial moves we prefer
  -- topping up an existing same-item stack so the bag stays compact, and
  -- only fall back to an empty slot when no such stack has room. Full
  -- moves don't pass a dest (useContainerItem picks one itself and stacks
  -- when it can), but we still want to confirm *some* viable slot exists,
  -- otherwise the move is hopeless.
  local destBag, destSlot, intoStack = nil, nil, false
  if not m.full then
    if m.dir == "withdraw" then
      destBag, destSlot = findStackableBagSlot(srcInfo.itemID, m.count)
    else
      destBag, destSlot = findStackableBankSlot(srcInfo.itemID, m.count)
    end
    intoStack = destBag ~= nil
  end
  if not destBag then
    if m.dir == "withdraw" then
      destBag, destSlot = firstEmptyBagSlot()
    else
      destBag, destSlot = firstEmptyBankSlot()
    end
  end

  if not destBag then
    -- Receiving side has no room. Drain the queue of any remaining moves
    -- in the same direction (they'd all fail the same way), and tell the
    -- user once. Moves in the opposite direction stay queued.
    local stillUseful = {}
    for _, q in ipairs(moveQueue) do
      if q.dir ~= m.dir then table.insert(stillUseful, q) end
    end
    local skipped = #moveQueue - #stillUseful
    moveQueue = stillUseful
    local target = (m.dir == "withdraw" and "your bags" or "your bank")
    dprint(string.format("%s full, skipped %d %s move(s)", target, skipped, m.dir))
    ns.Cubby:Print(string.format("Cubby: %s is full, skipped %d move%s.",
      target, skipped, skipped == 1 and "" or "s"))
    return
  end

  table.remove(moveQueue, 1)

  if m.full then
    -- With the bank open, UseContainerItem on either side shuffles to the
    -- other side. Picks the first free destination slot itself and stacks
    -- where it can.
    dprint(string.format("%s %s ×%d  bag=%d slot=%d → (auto)",
      m.dir, itemLabel(srcInfo.itemID), m.count, m.bag, m.slot))
    useContainerItem(m.bag, m.slot)
    runStats.full = runStats.full + 1
    updateCycleProgress(string.format("%s %s ×%d",
      m.dir, itemLabel(srcInfo.itemID), m.count))
  else
    -- Partial: pick up `count` from source, drop on the chosen dest.
    -- `intoStack` means we're topping up a same-item stack; track the add
    -- so the next tick doesn't overshoot its remaining room. Otherwise the
    -- dest is an empty slot and we reserve it the original way.
    if intoStack then
      noteStackedAdd(destBag, destSlot, m.count)
    else
      reserveDest(destBag, destSlot)
    end
    dprint(string.format("%s %s ×%d (partial)  bag=%d slot=%d → bag=%d slot=%d%s",
      m.dir, itemLabel(srcInfo.itemID), m.count, m.bag, m.slot, destBag, destSlot,
      intoStack and " [stack]" or ""))
    splitContainerItem(m.bag, m.slot, m.count)
    -- splitContainerItem is synchronous client-side: it either puts items
    -- on the cursor or fails (showing "Couldn't split those items"). If
    -- the cursor is empty, the split failed — issuing the pickup anyway
    -- would mis-grab whatever's at the dest. Abandon the move so the next
    -- replan can retry it after the cache settles.
    if not (CursorHasItem and CursorHasItem()) then
      dprint(string.format("split failed for %s bag=%d slot=%d — abandoning move",
        itemLabel(srcInfo.itemID), m.bag, m.slot))
      runStats.splitFailed = runStats.splitFailed + 1
      hadAbandon = true
      lockedSlots[destKey(m.bag, m.slot)] = true
      return
    end
    pickupContainerItem(destBag, destSlot)
    if intoStack then
      runStats.stacked = runStats.stacked + 1
    else
      runStats.empty = runStats.empty + 1
    end
    lastIssued = m
    lastWasStack = intoStack
    updateCycleProgress(string.format("%s %s ×%d (partial)",
      m.dir, itemLabel(srcInfo.itemID), m.count))
  end
end

function Bank:Start()
  if not Bank.bankOpen then return end
  if isDisabled() then
    dprint("Start: disabled, no-op")
    return
  end
  if ticker then return end
  dprint("Start: planning…")
  pendingDests = {}
  pendingAdds = {}
  hadAbandon = false
  replanAttempts = 0
  lockedSlots = {}
  splitFailedSlots = {}
  lastIssued, lastWasStack, sawUIError = nil, false, false
  resetStats()
  moveQueue = planMoves()
  if #moveQueue == 0 then
    dprint("Start: nothing to do")
    hideCycleProgress()
    if ns.UI then ns.UI:RefreshStatuses() end
    return
  end
  dprint(string.format("Start: ticker on, %d moves queued", #moveQueue))
  startCycleProgress()
  ticker = C_Timer.NewTicker(currentInterval(), executeNext)
end

function Bank:Refresh()
  if not Bank.bankOpen then return end
  if isDisabled() then
    dprint("Refresh: disabled, no-op")
    return
  end
  dprint("Refresh: cancelling current queue, will replan after settle")
  if ticker then ticker:Cancel() end
  ticker = nil
  moveQueue = {}
  pendingDests = {}
  pendingAdds = {}
  lastIssued, lastWasStack, sawUIError = nil, false, false
  hideCycleProgress()
  ClearCursor()
  -- Brief settle window so the client's container cache has time to catch
  -- up with whatever the user (or our last burst) just did. Planning on a
  -- stale cache produces moves whose source slots no longer match, which
  -- then makes splitContainerItem fail with "couldn't split those items".
  C_Timer.After(0.4, function()
    if Bank.bankOpen and not isDisabled() and not ticker then
      Bank:Start()
    end
  end)
end

function Bank:Stop()
  if ticker then dprint("Stop: cancelling ticker") end
  if ticker then ticker:Cancel() end
  ticker = nil
  moveQueue = {}
  pendingDests = {}
  pendingAdds = {}
  hadAbandon = false
  replanAttempts = 0
  lockedSlots = {}
  splitFailedSlots = {}
  lastIssued, lastWasStack, sawUIError = nil, false, false
  hideCycleProgress()
  ClearCursor()
end

function Bank:IsAvailable()
  return Bank.bankOpen and not isDisabled()
end

-- Called from `/cubby bank retry` after the user has manually clicked the
-- wedged slots to clear them. Wipes the blacklist + replan budget and runs
-- a fresh plan, without needing the user to close+reopen the bank.
function Bank:Retry()
  if not Bank.bankOpen then
    if ns.Cubby then ns.Cubby:Print("Bank isn't open.") end
    return
  end
  if isDisabled() then
    if ns.Cubby then ns.Cubby:Print("Bank auto-shuffle is disabled — turn it on first.") end
    return
  end
  if ticker then ticker:Cancel() end
  ticker = nil
  moveQueue = {}
  pendingDests = {}
  pendingAdds = {}
  lockedSlots = {}
  hadAbandon = false
  replanAttempts = 0
  ClearCursor()
  dprint("retry: blacklist cleared, replanning")
  Bank:Start()
end

-- Settings checkbox hook. Disabling: stop immediately and clear the cursor
-- so nothing keeps moving and the user can interact with bags/bank again.
-- Enabling at an already-open bank: start a fresh plan so they don't have
-- to close+reopen.
function Bank:SetDisabled(disabled)
  CubbyDB.bank = CubbyDB.bank or { disabled = false, debug = false }
  CubbyDB.bank.disabled = disabled and true or false
  if disabled then
    Bank:Stop()
    if ns.Cubby then ns.Cubby:Print("Bank auto-shuffle disabled.") end
  else
    if ns.Cubby then ns.Cubby:Print("Bank auto-shuffle enabled.") end
    if Bank.bankOpen then Bank:Start() end
  end
end
