-- GatherScout AH scanner: the full scan only. C_AuctionHouse.ReplicateItems() returns the whole AH at once and the
-- server allows it once every 15 minutes, per character, whoever asks.
--  * With Auctionator on the modern AH the full scan is done by Auctionator (see "Auctionator" below): GatherScout
--    asks Auctionator for it, both addons get the data, and GatherScout takes it when Auctionator has finished.
--  * Full scans that other addons start are picked up as well.
--  * Nothing else touches the AH: no searches, so Auctionator's shopping and selling views are never disturbed.
-- Stores per item: market price (cheap part of the market, see marketPrice), min price, total quantity, and a
-- history of snapshots that the demand model uses.
local _, ns = ...
local L = ns.L

local scan = {}   -- scan.status: the status line of the AH button and the list window
ns.scan = scan

local HISTORY_MAX = 40       -- snapshots kept for gathering materials
local HISTORY_MAX_DROP = 12  -- and for other mob drops (keeps saved variables small)
local SNAPSHOT_MERGE = 15 * 60
local DAILY_KEEP = 30

local function setStatus(text)
  scan.status = text
  if ns.AHButton_Update then ns.AHButton_Update() end
  if ns.UI_Status then ns.UI_Status(text) end
end

-- Market price that ignores dumping (similar to TSM's market value):
--   1. sort listings by unit price, take the cheapest 15% of all units; keep adding up to 30% while each
--      price step is no more than +20%;
--   2. drop listings further than 1.5 standard deviations from the (unit-weighted) mean of that slice;
--   3. the unit-weighted mean of what is left is the market price.
-- So 50 dumped units in front of thousands at the normal price do not drag the price down, while a large
-- cheap supply (which really is the market) does. Returns market price, lowest price.
local function marketPrice(rows)
  if #rows == 0 then return nil, nil end
  table.sort(rows, function(a, b) return a[1] < b[1] end)
  local low, total = rows[1][1], 0
  for _, r in ipairs(rows) do total = total + r[2] end
  local base = math.max(math.min(5, total), math.ceil(total * 0.15))
  local cap = math.max(base, math.ceil(total * 0.30))
  local sel, units, prev = {}, 0, nil
  for _, r in ipairs(rows) do
    if units >= cap then break end
    if units >= base and prev and r[1] > prev * 1.2 then break end
    local take = math.min(r[2], cap - units)
    sel[#sel + 1] = { r[1], take }
    units = units + take
    prev = r[1]
  end
  local sum = 0
  for _, s in ipairs(sel) do sum = sum + s[1] * s[2] end
  local mean = sum / units
  local var = 0
  for _, s in ipairs(sel) do var = var + s[2] * (s[1] - mean) ^ 2 end
  local limit = 1.5 * math.sqrt(var / units)
  local sum2, n2 = 0, 0
  for _, s in ipairs(sel) do
    if math.abs(s[1] - mean) <= limit then
      sum2 = sum2 + s[1] * s[2]
      n2 = n2 + s[2]
    end
  end
  return n2 > 0 and (sum2 / n2) or mean, low
end

local function store(results)
  local m = ns.Market()
  local now = time()
  local n = 0
  for id, res in pairs(results) do
    local r = m.items[id] or { h = {} }
    r.h = r.h or {}
    r.t, r.q, r.min, r.p = now, res.q, res.min, res.p
    if res.p then r.lp = res.p end
    local h = r.h
    local snap = { now, res.p, res.q, res.min }
    local last = h[#h]
    if last and now - last[1] < SNAPSHOT_MERGE then h[#h] = snap else h[#h + 1] = snap end
    local keep = ns.MAT[id] and HISTORY_MAX or HISTORY_MAX_DROP
    while #h > keep do table.remove(h, 1) end
    -- daily aggregate {lowest min price, highest min price, most units, avg market price, scans}; kept 30 days
    r.d = r.d or {}
    local day = ns.DayIndex(now)
    local dd = r.d[day]
    if not dd then dd = {}; r.d[day] = dd end
    if res.min then
      dd[1] = dd[1] and math.min(dd[1], res.min) or res.min
      dd[2] = dd[2] and math.max(dd[2], res.min) or res.min
    end
    if res.q then dd[3] = math.max(dd[3] or 0, res.q) end
    local n0 = dd[5] or 0
    if res.p then dd[4] = dd[4] and (dd[4] * n0 + res.p) / (n0 + 1) or res.p end
    dd[5] = n0 + 1
    for d in pairs(r.d) do
      if d < day - DAILY_KEEP then r.d[d] = nil end
    end
    m.items[id] = r
    n = n + 1
  end
  m.lastScan = now
  m.scanned = n
  return n
end

---------------------------------------------------------------- full scan (ReplicateItems)
-- full.active: a scan is asked for, running in Auctionator or being read; full.requested: the next replicate list
-- answers our own request (open until the list comes or the AH closes); full.processing: a list is being read.
local full = { active = false }
ns.full = full
local REPLICATE_COOLDOWN = 15 * 60 + 5

function ns.Scan_FullReady()
  return time() - (ns.db.lastReplicate or 0) >= REPLICATE_COOLDOWN
end

-- One auction of the client's replicate list: quantity, buyout of the whole stack, itemID
local function replicateRow(i)
  local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
  return count, buyout, itemID
end

-- Fingerprint of the replicate list: the client keeps the last list, and an event without fresh server data
-- must not be stored again as a "new" scan with today's timestamp.
local lastFingerprint

local function fingerprint(read, n)
  local acc = n
  local step = math.max(1, math.floor(n / 400))
  for i = 0, n - 1, step do
    local count, buyout, itemID = read(i)
    acc = (acc * 31 + (itemID or 0) * 7 + (count or 0) * 13 + (buyout or 0)) % 2147483647
  end
  return acc
end

-- Reads a list of n auctions, read(i) -> quantity, buyout of the stack, itemID (i from 0), and stores the snapshot.
-- source: "mine" (our own request, or Auctionator's scan we asked for), "other" (another addon's full scan) or
-- "auctionator" (a full scan Auctionator started by itself).
-- clientList: the list is the client's replicate list, which is fingerprinted and needs the AH open.
-- Returns true when a new snapshot is being processed. Only reads, so it never gets in the way of another addon.
local function readList(source, n, read, clientList)
  if full.processing or n <= 0 then return false end
  if clientList then
    local fp = fingerprint(read, n)
    if fp == lastFingerprint then
      -- The client fires the event again for a list it has already sent (e.g. when item data arrives later;
      -- Auctionator unsubscribes after the first one for that reason). A repeat nobody asked for changes
      -- nothing: the status keeps the result of the real scan. Only our own request gets an answer.
      if source ~= "mine" then return false end
      full.active, full.wait = false, nil
      setStatus(L["Full scan: no new data"])
      ns.Print("%s", L["the server sent the auction snapshot that is already counted: a new one comes 15 minutes after the last full scan."])
      return false
    end
    lastFingerprint = fp
  end
  full.processing, full.active, full.wait = true, true, nil
  local acc, i, started = {}, 0, GetTime()
  local ticker
  ticker = C_Timer.NewTicker(0, function()
    if clientList and not ns.ahOpen then
      ticker:Cancel()
      full.processing, full.active = false, false
      setStatus(L["Full scan stopped"])
      return
    end
    -- at most 2000 auctions or ~4 ms a frame, so reading a big AH keeps the frame rate
    local stop, t0 = math.min(n, i + 2000), debugprofilestop and debugprofilestop()
    while i < stop do
      local count, buyout, itemID = read(i)
      if itemID and count and count > 0 and buyout and buyout > 0 and ns.IsTracked(itemID) then
        local t = acc[itemID]
        if not t then t = {}; acc[itemID] = t end
        t[#t + 1] = { buyout / count, count }
      end
      i = i + 1
      if t0 and i % 250 == 0 and debugprofilestop() - t0 > 4 then break end
    end
    setStatus(string.format(L["Full scan: %d%%"], math.floor(i / n * 100)))
    if i < n then return end
    ticker:Cancel()

    local results, found = {}, 0
    for id, rows in pairs(acc) do
      local q = 0
      for _, r in ipairs(rows) do q = q + r[2] end
      local p, minp = marketPrice(rows)
      results[id] = { p = p, min = minp, q = q }
      found = found + 1
    end
    -- tracked items missing from the AH: gathering materials always, drops only if we already follow them
    local items = ns.Market().items
    for id in pairs(ns.MAT) do
      if not results[id] then results[id] = { q = 0 } end
    end
    for id in pairs(ns.DROP) do
      if not results[id] and items[id] then results[id] = { q = 0 } end
    end
    store(results)
    full.processing, full.active = false, false
    setStatus(string.format(L["Full scan: %s auctions, %d tracked"], ns.Num(n), found))
    ns.Print(source == "mine"
      and L["full scan: %s auctions in %d s, tracked items on the auction house: %d."]
      or L["full scan (data from another addon): %s auctions in %d s, tracked items on the auction house: %d."],
      ns.Num(n), math.floor(GetTime() - started + 0.5), found)
    ns.Invalidate()
  end)
  return true
end

local function processReplicate(source)
  if full.processing then return false end
  local AH = C_AuctionHouse
  local n = AH.GetNumReplicateItems and AH.GetNumReplicateItems() or 0
  return readList(source, n, replicateRow, true)
end

local function newSnapshot()
  ns.db.lastReplicate = math.max(ns.db.lastReplicate or 0, time())
end

---------------------------------------------------------------- Auctionator
-- With Auctionator on the modern AH the full scan is done by Auctionator: the server allows one per 15 minutes and
-- Auctionator reads only the scans it started itself, so GatherScout asks Auctionator for it (on a click and with
-- our auto-scan when the AH opens) and both addons get the data.
--  * GatherScout takes the data when Auctionator has finished (its scan-complete event), not while Auctionator
--    still works on the list. Auctionator's scan fails if the AH closes before it is done.
--  * Auctionator's summary scan (its default mode for its own Scan button) is not used: its prices are the lowest
--    listing of each item, not a market price.
-- Auctionator's internals are looked up when needed and called through pcall; its events reach a listener that
-- never lets an error of ours into Auctionator's code.
local function auctionatorScan()
  local A = Auctionator
  local f = type(A) == "table" and type(A.State) == "table" and A.State.FullScanFrameRef
  if type(f) == "table" and type(f.InitiateScan) == "function" and type(f.CanInitiate) == "function" then
    return f
  end
end
ns.AuctionatorScan = auctionatorScan

local hooked = false    -- Auctionator's full scan events reach us
local EVENT = {}        -- Auctionator's full scan event name -> "ScanStart" | "ScanProgress" | ...
local atrBusy = false   -- Auctionator's full scan is under way: the list is Auctionator's to read, we wait for its data
local atrAsked = false  -- that scan is the one we asked for
local atrFailed = false -- it failed: what Auctionator hands out afterwards is a remnant, not a scan

-- Auctionator is busy with its full scan
local function auctionatorBusy(f)
  return atrBusy or f.inProgress == true
end

-- Auctionator's scan is over and nothing of it is being read: the button is free again
local function auctionatorDone()
  if full.active and not full.processing then
    full.active = false
    setStatus(nil)
  end
end

-- What Auctionator read, once it has finished
local function readAuctionator(data)
  local source = atrAsked and "mine" or "auctionator"
  atrAsked = false
  if full.processing then return end
  -- The client still holds the list Auctionator read: read it whole (Auctionator leaves out the items whose data
  -- did not load in time).
  local AH = C_AuctionHouse
  local n = ns.ahOpen and AH.GetNumReplicateItems and AH.GetNumReplicateItems() or 0
  local started
  if n > 0 then
    started = processReplicate(source)
  else
    -- The AH is closed by now: Auctionator's own copy of the list,
    -- { replicateInfo = { C_AuctionHouse.GetReplicateItemInfo(i) }, itemLink, timeLeft } per auction
    local read = function(i)
      local e = data[i + 1]
      local info = type(e) == "table" and e.replicateInfo
      if type(info) ~= "table" then return nil end
      return info[3], info[10], info[17]
    end
    started = readList(source, #data, read, false)
  end
  if started then newSnapshot() else auctionatorDone() end
end

local function onAuctionatorEvent(name, ...)
  local what = EVENT[name]
  if not what then return end
  if what == "ScanStart" or what == "ScanProgress" then
    if what == "ScanStart" then
      atrFailed = false
    elseif atrFailed then
      return -- Auctionator winding up a failed scan (see ScanComplete)
    end
    atrBusy = true
    if full.processing then return end
    full.active = true
    local p = what == "ScanProgress" and tonumber((...))
    setStatus(p and string.format("%s %d%%", L["Auctionator is scanning…"], math.floor(p * 100))
      or L["Auctionator is scanning…"])
  elseif what == "ScanFailed" then
    atrBusy, atrAsked, atrFailed = false, false, true
    auctionatorDone()
  elseif what == "ScanComplete" then
    atrBusy = false
    local data = ...
    -- After a failure Auctionator still ends the scan with whatever it read after the AH closed ("finished
    -- processing 0 items"): not a scan.
    if atrFailed or type(data) ~= "table" then
      atrAsked = false
      auctionatorDone()
      return
    end
    -- read it on the next frame, outside Auctionator's code
    C_Timer.After(0, function() readAuctionator(data) end)
  end
end

local listener = {}
function listener:ReceiveEvent(name, ...)
  local ok, err = pcall(onAuctionatorEvent, name, ...)
  if not ok and ns.debug then ns.Print("Auctionator event %s: %s", tostring(name), tostring(err)) end
end

local function hookAuctionator()
  local A = Auctionator
  if hooked or not auctionatorScan() or type(A.EventBus) ~= "table" or type(A.EventBus.Register) ~= "function" then return end
  local events = type(A.FullScan) == "table" and A.FullScan.Events
  if type(events) ~= "table" then return end
  local names = {}
  for _, what in ipairs({ "ScanStart", "ScanProgress", "ScanComplete", "ScanFailed" }) do
    local name = events[what]
    if type(name) == "string" then
      EVENT[name] = what
      names[#names + 1] = name
    end
  end
  if #names > 0 then hooked = pcall(A.EventBus.Register, A.EventBus, listener, names) end
end
ns.On("PLAYER_LOGIN", hookAuctionator)

-- Fires for our own request, for full scans other addons start and again for a list already sent: the client
-- repeats it while item data loads, thousands of times when Auctionator reads a scan (Auctionator itself
-- unsubscribes after the first one). Auctionator's full scan is left to Auctionator (its data comes when it has
-- finished, see above). Our own request is answered at once; a list nobody here asked for is looked at only
-- when it can be new (the server sends one at most every 15 minutes, so not within 15 minutes of the last one)
-- and at most once a second, so the repeats cost nothing. The 15-minute timer moves only when a new snapshot
-- arrives.
local otherPending = false
ns.On("REPLICATE_ITEM_LIST_UPDATE", function()
  if not ns.ahOpen or full.processing then return end
  local atr = hooked and auctionatorScan()
  if atr and auctionatorBusy(atr) then return end
  if full.requested then
    full.requested = nil
    if processReplicate("mine") then newSnapshot() end
    return
  end
  if otherPending or time() - (ns.db.lastReplicate or 0) < REPLICATE_COOLDOWN - 5 then return end
  otherPending = true
  C_Timer.After(1, function()
    otherPending = false
    if ns.ahOpen and not full.processing and not full.requested and processReplicate("other") then newSnapshot() end
  end)
end)

-- Waits for the server's answer. A big AH can take the server a minute or more to send, so the request stays
-- open until the AH is closed: a list that comes late is still read as ours. After ANSWER_WAIT seconds without
-- one the button is free again and the chat says why nothing came yet; the data of the last scan stays.
local ANSWER_WAIT = 120
local function waitForData()
  local token = {}
  full.wait = token
  C_Timer.After(ANSWER_WAIT, function()
    if full.wait == token and full.active and not full.processing then
      full.active, full.wait = false, nil -- full.requested stays: a late answer is still ours
      setStatus(L["Full scan: no answer yet"])
      ns.Print("%s", L["the server has not sent the full scan for 2 minutes: a big auction house can take longer, or the server's 15-minute limit is not over yet (another addon may have just done a scan). If it still comes, it is read; until then the data of the last scan stays."])
    end
  end)
end

-- manual: a click or /gs scan (always asks, even when our timer says it is too early: it can be stale, e.g.
-- after a relog); automatic scans respect the timer and stay quiet.
function ns.Scan_Full(manual)
  if full.active then
    if manual then ns.Print("%s", L["a scan is already running…"]) end
    return
  end
  if not ns.ahOpen then
    if manual then ns.Print("%s", L["open the auction house: scanning works only at an auctioneer."]) end
    return
  end
  if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then
    if manual then ns.Print("%s", L["this client has no modern auction house API, scanning is not available."]) end
    return
  end
  local atr = auctionatorScan()
  if atr then
    hookAuctionator()
    if auctionatorBusy(atr) then
      -- Auctionator is scanning already: its data comes to us too
      setStatus(L["Auctionator is scanning…"])
      if manual then ns.Print("%s", L["a scan is already running…"]) end
      return
    end
    local ok, can = pcall(atr.CanInitiate, atr)
    if ok and not can then
      -- Auctionator's 15-minute timer is running: a scan of ours now would leave Auctionator without data.
      -- On a click Auctionator says itself when its next scan is possible.
      if manual then pcall(atr.InitiateScan, atr) end
      return
    end
    if ok then
      atrAsked = true
      if pcall(atr.InitiateScan, atr) and auctionatorBusy(atr) then
        full.active = true -- Auctionator's events show its progress (without them: until we read its list)
        if not hooked then setStatus(L["Auctionator is scanning…"]) end
        return
      end
      atrAsked = false
    end
    -- an Auctionator we do not know how to ask: scan ourselves (it gets no data from that scan)
  end
  if not manual and not ns.Scan_FullReady() then return end
  full.active, full.requested = true, true
  setStatus(L["Full scan: waiting for the server…"])
  C_AuctionHouse.ReplicateItems()
  waitForData()
end

---------------------------------------------------------------- AH open/close + button
local button

-- Grow a button to its label (never below minW), so no state of the text gets cut off
local function fitWidth(b, minW)
  local fs = b:GetFontString()
  local w = fs and fs:GetStringWidth() or 0
  b:SetWidth(math.max(minW, math.ceil(w) + 24))
end

-- The buttons sit on the top edge of the AH frame, often right under the top of the screen: a tooltip
-- "above" gets pushed down by the screen clamp and covers both buttons. Open it above the button only
-- when it fits there, otherwise below the button row. Call after GameTooltip:Show() (needs its height).
local function anchorTip(owner)
  local tt = GameTooltip
  tt:ClearAllPoints()
  local top = (owner:GetTop() or 0) * owner:GetEffectiveScale()
  local need = (tt:GetHeight() + 8) * tt:GetEffectiveScale()
  local screen = UIParent:GetTop() * UIParent:GetEffectiveScale()
  if top + need <= screen then
    tt:SetPoint("BOTTOMRIGHT", owner, "TOPRIGHT", 0, 6)
  else
    tt:SetPoint("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -6)
  end
end

function ns.AHButton_Update()
  if not button then return end
  if full.active then
    button:SetText(scan.status or L["Scan…"])
  else
    button:SetText(L["Scan auctions"])
  end
  fitWidth(button, 170)
end

local function createButton()
  local parent = AuctionHouseFrame or AuctionFrame
  if not parent or button then return end
  button = CreateFrame("Button", "GatherScoutAHButton", parent, "UIPanelButtonTemplate")
  button:SetSize(170, 22)
  button:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", -24, 2)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then
      if ns.UI_Toggle then ns.UI_Toggle() end
    else
      ns.Scan_Full(true)
    end
  end)
  button:SetScript("OnEnter", function(self)
    local tt = GameTooltip
    tt:SetOwner(self, "ANCHOR_NONE")
    tt:AddLine("GatherScout")
    tt:AddLine(L["Left-click: full scan of the whole auction house at once (the server allows it every 15 min)"], 1, 1, 1)
    local atr = auctionatorScan()
    if atr then
      tt:AddLine(L["With Auctionator the full scan is done by Auctionator and both addons get the data once it has finished: keep the auction house open until then."], 0.7, 0.7, 0.7, true)
    end
    tt:AddLine(L["Right-click: open the “what to farm” list"], 1, 1, 1)
    local m = ns.Market()
    if m.lastScan and m.lastScan > 0 then
      tt:AddLine(string.format(L["Last scan: %d min ago"], math.floor((time() - m.lastScan) / 60)), 0.7, 0.7, 0.7)
    end
    local wait = REPLICATE_COOLDOWN - (time() - (ns.db.lastReplicate or 0))
    if wait > 0 and not atr then
      tt:AddLine(string.format(L["Full scan by our timer: in ~%d min"], math.ceil(wait / 60)), 0.7, 0.7, 0.7)
    end
    tt:Show()
    anchorTip(self)
  end)
  button:SetScript("OnLeave", GameTooltip_Hide)

  -- separate "open the window" button next to the scan/progress button
  local open = CreateFrame("Button", "GatherScoutAHOpenButton", parent, "UIPanelButtonTemplate")
  open:SetSize(100, 22)
  open:SetPoint("RIGHT", button, "LEFT", -4, 0)
  open:SetText("GatherScout")
  fitWidth(open, 100)
  open:SetScript("OnClick", function() if ns.UI_Toggle then ns.UI_Toggle() end end)
  open:SetScript("OnEnter", function(self)
    local tt = GameTooltip
    tt:SetOwner(self, "ANCHOR_NONE")
    tt:AddLine("GatherScout")
    tt:AddLine(L["Open / close the “what to farm” list"], 1, 1, 1)
    tt:Show()
    anchorTip(self)
  end)
  open:SetScript("OnLeave", GameTooltip_Hide)
  ns.AHButton_Update()
end

ns.On("AUCTION_HOUSE_SHOW", function()
  ns.ahOpen = true
  createButton()
  if button then button:Show() end
  hookAuctionator()
  local S = ns.S
  -- Give other addons a moment: one that starts a full scan on opening the AH (Auctionator with its own auto-scan
  -- on) gets it, and we take the same data. Otherwise we ask (with Auctionator: Auctionator).
  if S.autoScan then
    C_Timer.After(4, function()
      if not ns.ahOpen or full.active then return end
      local atr = auctionatorScan()
      if atr and auctionatorBusy(atr) then return end
      local stale = (time() - (ns.Market().lastScan or 0)) > S.autoScanMinutes * 60
      if stale and ns.Scan_FullReady() then ns.Scan_Full(false) end
    end)
  end
  if ns.UI_Refresh then ns.UI_Refresh() end
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
  ns.ahOpen = false
  -- a request still waiting for the server is dropped; the client's list being read stops by itself (readList).
  -- Auctionator says itself whether its scan failed or still finishes (its data can come after closing).
  atrBusy = false
  if not full.processing then
    if full.active then setStatus(nil) end
    full.active, full.requested, full.wait = false, nil, nil
  end
  if ns.UI_Refresh then ns.UI_Refresh() end
end)
