-- GatherScout AH scanner (modern C_AuctionHouse API used by WoW Forever). Two modes:
--  * full scan: C_AuctionHouse.ReplicateItems() returns the whole AH at once (server allows it every 15 min).
--    Also picks up full scans started by other addons (Auctionator) for free.
--  * quick scan: searches the ~120 gathering materials one by one, like Auctionator's shopping lists do:
--    wait for item key info in cache -> wait for throttle -> SendSearchQuery -> read commodity/item results.
-- Stores per item: market price (avg of the cheapest ~10% of units), min price, total quantity, and a history of
-- snapshots that the demand model uses.
local _, ns = ...

local scan = { active = false }
ns.scan = scan

local SORTS = { { sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0,
  reverseSort = false } }
local HISTORY_MAX = 40       -- snapshots kept for gathering materials
local HISTORY_MAX_DROP = 12  -- and for other mob drops (keeps saved variables small)
local SNAPSHOT_MERGE = 15 * 60
local DAILY_KEEP = 30

local driver = CreateFrame("Frame")
driver:Hide()

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

local function finishItem(cur, rows, total)
  if rows then
    local q = total
    if not q then
      q = 0
      for _, r in ipairs(rows) do q = q + r[2] end
    end
    local p, minp = marketPrice(rows, q)
    scan.results[cur.id] = { p = p, min = minp, q = q }
    if q > 0 then scan.found = scan.found + 1 end
  elseif cur.answered then
    -- the server answered but reported nothing: no auctions for this item
    scan.results[cur.id] = { q = 0 }
  end
  scan.done = scan.done + 1
  scan.cur = nil
  setStatus(string.format("Скан %d/%d…", scan.done, scan.total))
end

local function store(results, partial)
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
  if not partial then
    m.lastScan = now
    m.scanned = n
  elseif n > 0 then
    m.lastScan = math.max(m.lastScan or 0, now - 1)
    m.scanned = n
  end
  return n
end

local function finishScan(aborted)
  if not scan.active then return end
  scan.active = false
  scan.cur = nil
  driver:Hide()
  local n = store(scan.results, aborted)
  if aborted then
    setStatus(string.format("Скан прерван: сохранено %d", n))
    ns.Print("скан прерван (аукцион закрыт), сохранено %d предметов.", n)
  else
    setStatus(string.format("Готово: %d, на аукционе %d", n, scan.found))
    ns.Print("скан завершён за %d c: %d предметов, %d есть на аукционе. |cffffff00/gs|r — открыть список.",
      math.floor(GetTime() - scan.started + 0.5), n, scan.found)
  end
  ns.Invalidate()
end

local function nextItem()
  scan.i = scan.i + 1
  local id = scan.queue[scan.i]
  if not id then
    finishScan(false)
    return
  end
  scan.cur = { id = id, key = C_AuctionHouse.MakeItemKey(id), state = "info", t0 = GetTime(), tries = 0 }
end

driver:SetScript("OnUpdate", function(self)
  if not scan.active then self:Hide() return end
  local cur = scan.cur
  if not cur then nextItem() cur = scan.cur end
  if not cur then return end
  local now = GetTime()
  if cur.state == "info" then
    if C_AuctionHouse.GetItemKeyInfo(cur.key) then
      cur.state = "throttle"
    elseif now - cur.t0 > 3 then
      finishItem(cur, nil)
      return
    end
  end
  if cur.state == "throttle" then
    if C_AuctionHouse.IsThrottledMessageSystemReady() then
      cur.state = "wait"
      cur.t1 = now
      C_AuctionHouse.SendSearchQuery(cur.key, SORTS, false)
    elseif now - cur.t0 > 20 then
      finishItem(cur, nil)
    end
  elseif cur.state == "wait" and now - cur.t1 > 5 then
    cur.tries = cur.tries + 1
    if cur.tries <= 2 then cur.state = "throttle" else finishItem(cur, nil) end
  end
end)

local function retryOrEmpty(cur)
  cur.answered = true
  cur.tries = cur.tries + 1
  if cur.tries <= 2 then cur.state = "throttle" else finishItem(cur, nil) end
end

ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
  local cur = scan.active and scan.cur
  if not cur or cur.state ~= "wait" or itemID ~= cur.id then return end
  local AH = C_AuctionHouse
  local has = AH.HasSearchResults(cur.key)
  local full = AH.HasFullCommoditySearchResults(itemID)
  local total = AH.GetCommoditySearchResultsQuantity(itemID) or 0
  if not has or (not full and total == 0) then return retryOrEmpty(cur) end
  local rows = {}
  for i = 1, AH.GetNumCommoditySearchResults(itemID) or 0 do
    local info = AH.GetCommoditySearchResultInfo(itemID, i)
    if info and info.unitPrice and info.quantity and info.quantity > 0 then
      rows[#rows + 1] = { info.unitPrice, info.quantity }
    end
  end
  cur.answered = true
  finishItem(cur, rows, total)
end)

ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
  local cur = scan.active and scan.cur
  if not cur or cur.state ~= "wait" or type(itemKey) ~= "table" or itemKey.itemID ~= cur.id then return end
  local AH = C_AuctionHouse
  local has = AH.HasSearchResults(itemKey)
  local full = AH.HasFullItemSearchResults(itemKey)
  local total = AH.GetItemSearchResultsQuantity(itemKey) or 0
  if not has or (not full and total == 0) then return retryOrEmpty(cur) end
  local rows = {}
  for i = 1, AH.GetNumItemSearchResults(itemKey) or 0 do
    local info = AH.GetItemSearchResultInfo(itemKey, i)
    if info and info.buyoutAmount and info.quantity and info.quantity > 0 then
      rows[#rows + 1] = { info.buyoutAmount / info.quantity, info.quantity }
    end
  end
  cur.answered = true
  finishItem(cur, rows, nil)
end)

function ns.Scan_Start(manual)
  if scan.active then
    if manual then ns.Print("скан уже идёт…") end
    return
  end
  if not ns.ahOpen then
    if manual then ns.Print("открой аукцион — сканировать можно только у аукциониста.") end
    return
  end
  if not (C_AuctionHouse and C_AuctionHouse.SendSearchQuery and C_AuctionHouse.MakeItemKey) then
    ns.Print("в этом клиенте нет современного API аукциона, скан недоступен.")
    return
  end
  scan.queue = {}
  -- scan every tracked material (cheap, ~1-2 min) so switching categories later needs no rescan
  for id in pairs(ns.MAT) do scan.queue[#scan.queue + 1] = id end
  table.sort(scan.queue)
  scan.i, scan.total, scan.done, scan.found = 0, #scan.queue, 0, 0
  scan.results = {}
  scan.started = GetTime()
  scan.active = true
  setStatus(string.format("Скан 0/%d…", scan.total))
  driver:Show()
end

function ns.Scan_Stop()
  if scan.active then finishScan(true) end
end

---------------------------------------------------------------- full scan (ReplicateItems)
local full = { active = false }
ns.full = full
local REPLICATE_COOLDOWN = 15 * 60 + 5

function ns.Scan_FullReady()
  return time() - (ns.db.lastReplicate or 0) >= REPLICATE_COOLDOWN
end

-- Fingerprint of the replicate list: the client keeps the last list, and an event without fresh server data
-- must not be stored again as a "new" scan with today's timestamp.
local lastFingerprint

local function fingerprint(AH, n)
  local acc = n
  local step = math.max(1, math.floor(n / 400))
  for i = 0, n - 1, step do
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = AH.GetReplicateItemInfo(i)
    acc = (acc * 31 + (itemID or 0) * 7 + (count or 0) * 13 + (buyout or 0)) % 2147483647
  end
  return acc
end

local function processReplicate(source)
  if full.processing then return end
  local AH = C_AuctionHouse
  local n = AH.GetNumReplicateItems and AH.GetNumReplicateItems() or 0
  if n <= 0 then return end
  local fp = fingerprint(AH, n)
  if fp == lastFingerprint then
    full.active = false
    setStatus("Полный скан: новых данных нет")
    if source == "mine" then
      ns.Print("сервер вернул тот же снимок аукциона, что уже учтён; делаю быстрый скан сырья.")
      ns.Scan_Start(false)
    end
    return
  end
  lastFingerprint = fp
  full.processing, full.active = true, true
  local acc, i, started = {}, 0, GetTime()
  local ticker
  ticker = C_Timer.NewTicker(0, function()
    if not ns.ahOpen then
      ticker:Cancel()
      full.processing, full.active = false, false
      setStatus("Полный скан прерван")
      return
    end
    local stop = math.min(n, i + 2000)
    while i < stop do
      local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = AH.GetReplicateItemInfo(i)
      if itemID and count and count > 0 and buyout and buyout > 0 and ns.IsTracked(itemID) then
        local t = acc[itemID]
        if not t then t = {}; acc[itemID] = t end
        t[#t + 1] = { buyout / count, count }
      end
      i = i + 1
    end
    setStatus(string.format("Полный скан: %d%%", math.floor(i / n * 100)))
    if i < n then return end
    ticker:Cancel()

    local results, found = {}, 0
    for id, rows in pairs(acc) do
      local q = 0
      for _, r in ipairs(rows) do q = q + r[2] end
      local p, minp = marketPrice(rows, q)
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
    local stored = store(results, false)
    full.processing, full.active = false, false
    setStatus(string.format("Полный скан: %d лотов, наших %d", n, found))
    ns.Print("полный скан%s: %d лотов за %d c, отслеживаемых предметов на аукционе: %d.",
      source == "other" and " (данные другого аддона)" or "", n, math.floor(GetTime() - started + 0.5), found)
    ns.Invalidate()
  end)
end

-- Fires for our own request and for full scans done by other addons (e.g. Auctionator)
ns.On("REPLICATE_ITEM_LIST_UPDATE", function()
  if not ns.ahOpen then return end
  local mine = full.requested
  full.requested = nil
  ns.db.lastReplicate = math.max(ns.db.lastReplicate or 0, time())
  processReplicate(mine and "mine" or "other")
end)

function ns.Scan_Full(manual)
  if scan.active or full.active then
    if manual then ns.Print("скан уже идёт…") end
    return
  end
  if not ns.ahOpen then
    if manual then ns.Print("открой аукцион — сканировать можно только у аукциониста.") end
    return
  end
  if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then return ns.Scan_Start(manual) end
  -- Automatic scans respect our own 15-minute timer; a click always asks the server (our timer can be stale,
  -- e.g. after a relog), and if the server refuses we fall back to the quick scan after 15 seconds.
  -- The timer itself only moves when a full scan actually arrives (REPLICATE_ITEM_LIST_UPDATE).
  if not ns.Scan_FullReady() and not manual then
    return ns.Scan_Start(false)
  end
  full.active, full.requested = true, true
  setStatus("Полный скан: ждём сервер…")
  C_AuctionHouse.ReplicateItems()
  C_Timer.After(15, function()
    if full.active and not full.processing then
      full.active, full.requested = false, nil
      ns.Print("сервер не прислал полный скан (вероятно, его недавно делал другой аддон), делаю быстрый скан сырья.")
      ns.Scan_Start(false)
    end
  end)
end

---------------------------------------------------------------- AH open/close + button
local button

function ns.AHButton_Update()
  if not button then return end
  if scan.active or full.active then
    button:SetText(scan.status or "Скан…")
  else
    button:SetText("GatherScout: скан")
  end
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
    elseif scan.active then
      ns.Scan_Stop()
    elseif IsShiftKeyDown() then
      ns.Scan_Start(true)
    else
      ns.Scan_Full(true)
    end
  end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("GatherScout")
    GameTooltip:AddLine("ЛКМ — полный скан аукциона (раз в 15 мин, несколько секунд)", 1, 1, 1)
    GameTooltip:AddLine("Shift+ЛКМ — быстрый скан только сырья (~1–2 мин)", 1, 1, 1)
    GameTooltip:AddLine("ЛКМ во время быстрого скана — остановить", 1, 1, 1)
    GameTooltip:AddLine("ПКМ — открыть список «что фармить»", 1, 1, 1)
    local m = ns.Market()
    if m.lastScan and m.lastScan > 0 then
      GameTooltip:AddLine(string.format("Последний скан: %d мин назад", math.floor((time() - m.lastScan) / 60)),
        0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", GameTooltip_Hide)

  -- separate "open the window" button next to the scan/progress button
  local open = CreateFrame("Button", "GatherScoutAHOpenButton", parent, "UIPanelButtonTemplate")
  open:SetSize(100, 22)
  open:SetPoint("RIGHT", button, "LEFT", -4, 0)
  open:SetText("Окно GS")
  open:SetScript("OnClick", function() if ns.UI_Toggle then ns.UI_Toggle() end end)
  open:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("GatherScout")
    GameTooltip:AddLine("Открыть / закрыть список «что фармить»", 1, 1, 1)
    GameTooltip:Show()
  end)
  open:SetScript("OnLeave", GameTooltip_Hide)
  ns.AHButton_Update()
end

ns.On("AUCTION_HOUSE_SHOW", function()
  ns.ahOpen = true
  createButton()
  if button then button:Show() end
  local S = ns.S
  if S.autoScan then
    -- give other addons a moment: if Auctionator does its own full scan we just reuse it
    C_Timer.After(4, function()
      if not ns.ahOpen or scan.active or full.active then return end
      local stale = (time() - (ns.Market().lastScan or 0)) > S.autoScanMinutes * 60
      if not stale then return end
      if ns.Scan_FullReady() then ns.Scan_Full(false) else ns.Scan_Start(false) end
    end)
  end
  if ns.UI_Refresh then ns.UI_Refresh() end
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
  ns.ahOpen = false
  ns.Scan_Stop()
  if ns.UI_Refresh then ns.UI_Refresh() end
end)
