-- GatherScout world map: on a zone map, mob spawns (and, if enabled, herb/ore spawn points) for the selected
-- items; on a continent map, one small marker per zone for all selected items (count badge when several),
-- limited to each item's best places. Markers are item icons in a thin frame colored by difficulty for you,
-- drawn below quests and the player, hover-only (clicks go through); details are in the tooltip.
-- Selected = items you toggled with the card's map button this session + pinned items (option).
-- A button on the map toggles everything (left click), the herb/ore points (right click) or how many places
-- per item the continent shows (Shift+click: best / best 3 / all).
local _, ns = ...
local L = ns.L

ns.mapSel = {}

---------------------------------------------------------------- packed coordinates (see tools/gen.py)
local function idx(c) return c < 92 and c - 35 or c - 36 end
function ns.UnpackCoords(s)
  local pts = {}
  for i = 1, #s - 3, 4 do
    local a, b, c, d = s:byte(i, i + 3)
    pts[#pts + 1] = (idx(a) * 91 + idx(b)) / 1000
    pts[#pts + 1] = (idx(c) * 91 + idx(d)) / 1000
  end
  return pts
end

-- { {x, y, npcID|nil, school|nil}, ... } for item `id` on zone map `mapID`; herb/ore spawn points only with
-- `withNodes`; fishing schools always (they are few); with `maxLevel`, only mobs up to that level (cloth and
-- leather come from hundreds of mobs: the map shows the ones you can farm)
local function pointsFor(id, mapID, withNodes, maxLevel)
  local out = {}
  local fish = ns.GEN.fish and ns.GEN.fish[id]
  local pools = fish and fish.p and fish.p[mapID]
  if pools then
    for pool in pairs(pools) do
      local s = ns.GEN.fishPools[pool] and ns.GEN.fishPools[pool][mapID]
      if s then
        local p = ns.UnpackCoords(s)
        for i = 1, #p, 2 do out[#out + 1] = { p[i], p[i + 1], nil, pool } end
      end
    end
  end
  local node = withNodes and ns.GEN.nodeItems[id]
  if node and node.nodes then
    for _, nodeName in ipairs(node.nodes) do
      local per = ns.GEN.nodeCoords[nodeName]
      local s = per and per[mapID]
      if s then
        local p = ns.UnpackCoords(s)
        for i = 1, #p, 2 do out[#out + 1] = { p[i], p[i + 1] } end
      end
    end
  end
  local npcs = ns.NpcList(id)
  if npcs then
    for _, npcID in ipairs(npcs) do
      local per = ns.GEN.npcCoords[npcID]
      local s = per and per[mapID]
      local n = ns.GEN.npcs[npcID]
      if s and maxLevel and n and n[1] > maxLevel then s = nil end
      if s then
        local p = ns.UnpackCoords(s)
        for i = 1, #p, 2 do out[#out + 1] = { p[i], p[i + 1], npcID } end
      end
    end
  end
  return out
end

function ns.MapItems()
  local items = {}
  for id in pairs(ns.mapSel) do items[id] = true end
  if ns.S and ns.S.mapPinned then
    for id in pairs(ns.db.pins) do
      if ns.IsTracked(id) then items[id] = true end
    end
  end
  return items
end

---------------------------------------------------------------- pin
GatherScoutMapPinMixin = CreateFromMixins and MapCanvasPinMixin and CreateFromMixins(MapCanvasPinMixin) or {}

-- Pins sit below quest givers, quest objectives, flight masters and the player: the lowest frame level type
-- this client's map knows, falling back to the area-POI level that every client has.
local LEVEL_TYPES = { "PIN_FRAME_LEVEL_DIG_SITE", "PIN_FRAME_LEVEL_MAP_LINK", "PIN_FRAME_LEVEL_FLIGHT_POINT" }
local levelType
local function pinLevelType()
  if levelType then return levelType end
  levelType = "PIN_FRAME_LEVEL_AREA_POI"
  local ok, mgr = pcall(function() return WorldMapFrame:GetPinFrameLevelsManager() end)
  local defs = ok and mgr and (mgr.definitions or mgr.frameLevelDefinitions)
  if type(defs) == "table" then
    for _, t in ipairs(LEVEL_TYPES) do
      if defs[t] then levelType = t break end
    end
  end
  return levelType
end

function GatherScoutMapPinMixin:OnLoad()
  -- Hover only, no clicks: clicks go through to quests and other pins under ours. (For click-enabled pins the
  -- map also runs extra setup, SetPassThroughButtons, that can fail on new clients.)
  if self.SetMouseClickEnabled then self:SetMouseClickEnabled(false) end
  if self.SetMouseMotionEnabled then self:SetMouseMotionEnabled(true) end
  if self.UseFrameLevelType then pcall(self.UseFrameLevelType, self, pinLevelType()) end
  -- constant size on screen at any zoom, a little bigger when zoomed in
  if self.SetScalingLimits then self:SetScalingLimits(1, 1.0, 1.2) end
  local font = _G.NumberFontNormalSmall and "NumberFontNormalSmall" or "GameFontHighlightSmall"
  self.Count = self:CreateFontString(nil, "OVERLAY", font)
  self.Count:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 5, -3)
end

-- same workaround as HereBeDragons-Pins ("hack to avoid in-combat error")
GatherScoutMapPinMixin.SetPassThroughButtons = function() end

-- info: x, y, id, icon, size, r/g/b (frame = difficulty for you), alpha, count (continent: items in the zone)
function GatherScoutMapPinMixin:OnAcquired(info)
  self.info = info
  self:SetSize(info.size, info.size)
  self.Texture:SetTexture(info.icon)
  self.Texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  self.Edge:SetColorTexture(info.r or 0.5, info.g or 0.5, info.b or 0.5, 1)
  self.Count:SetText((info.count and info.count > 1) and tostring(info.count) or "")
  self:SetAlpha(info.alpha or 1)
  self:SetPosition(info.x, info.y)
end

-- drop chance at a source; "??" when unknown; nil for gathering places (no chance there)
local function srcChance(id, src)
  local c, csrc = nil, nil
  if src.kind == "npc" then c, csrc = ns.DropChance(id, src.npcs[1]) end
  if not c and src.chance then c, csrc = src.chance, src.chanceSrc end
  if not c and src.kind == "zone" then return nil end
  return ns.ChanceText(c, csrc, true)
end

local function itemLine(tt, id)
  local row = ns.rowById and ns.rowById[id]
  local right = row and row.price and ns.Money(row.price) or ""
  if row and row.dem and not row.dem.none then right = right .. " " .. ns.DemandIcon(row.dem, 12) end
  tt:AddDoubleLine(string.format("|T%d:0|t %s", ns.ItemIcon(id), ns.ItemName(id) or string.format(L["item %d"], id)),
    right, 1, 1, 1, 1, 1, 1)
end

-- Zone map: one marker stands for the spawns close to each other on screen; list what is there
local function clusterTooltip(tt, info)
  tt:AddLine(ns.MapName(info.zone))
  for _, e in ipairs(info.cluster.list) do
    itemLine(tt, e.id)
    if e.src then
      tt:AddLine("      " .. (ns.DiffLabel(e.src.mult))
        .. ((e.src.note and e.src.note ~= "") and ("  |cffff9a50" .. e.src.note .. "|r") or ""), 0.85, 0.85, 0.85)
    end
    local mobs = {}
    for npcID, k in pairs(e.mobs) do mobs[#mobs + 1] = { npcID, k } end
    table.sort(mobs, function(a, b) return a[2] > b[2] end) -- most spawns here first
    for i = 1, math.min(5, #mobs) do
      local npcID = mobs[i][1]
      local n = ns.GEN.npcs[npcID]
      local lv = n and ((n.guess and "~" or "") .. (n[1] == n[2] and tostring(n[1]) or (n[1] .. "–" .. n[2]))) or "?"
      local c, csrc = ns.DropChance(e.id, npcID)
      tt:AddDoubleLine("      " .. ns.NpcName(npcID) .. ((n and (n[3] == 1 or n[3] == 2)) and (" |cffff8080" .. L["elite"] .. "|r") or ""),
        ns.LevelColor(n and n[1]) .. lv .. "|r" .. "   " .. ns.ChanceText(c, csrc, true), 0.85, 0.85, 0.85)
    end
    if #mobs > 5 then tt:AddLine("      |cff909090" .. string.format(L["…and %d more"], #mobs - 5) .. "|r") end
    for pool in pairs(e.pools) do tt:AddLine("      " .. ns.SchoolLabel(pool), 0.85, 0.85, 0.85) end
    if e.nodes > 0 then tt:AddLine("      " .. L["gathering node"] .. (e.nodes > 1 and (" (" .. e.nodes .. ")") or ""), 0.85, 0.85, 0.85) end
  end
  tt:Show()
end

function GatherScoutMapPinMixin:OnMouseEnter()
  local info = self.info
  if not info then return end
  local tt = GameTooltip
  tt:SetOwner(self, "ANCHOR_RIGHT")
  if info.cluster then return clusterTooltip(tt, info) end
  if info.agg then
    -- continent: everything selected you can get in this zone, best for you first
    tt:AddLine(ns.MapName(info.map))
    local anyNpc, anyNode = false, false
    for _, e in ipairs(info.list) do
      local row = ns.rowById and ns.rowById[e.id]
      local right = row and row.price and ns.Money(row.price) or ""
      if row and row.dem and not row.dem.none then right = right .. " " .. ns.DemandIcon(row.dem, 12) end
      tt:AddDoubleLine(string.format("|T%d:0|t %s", ns.ItemIcon(e.id), ns.ItemName(e.id) or string.format(L["item %d"], e.id)),
        right, 1, 1, 1, 1, 1, 1)
      local ch = srcChance(e.id, e.src)
      tt:AddLine("      " .. (ns.DiffLabel(e.src.mult)) .. "  " .. ns.WhereText(e.src, e.id) .. (ch and ("  " .. ch) or ""),
        0.85, 0.85, 0.85)
      if e.src.note and e.src.note ~= "" then tt:AddLine("      " .. e.src.note, 1, 0.6, 0.3, true) end
      if ns.NpcList(e.id) then anyNpc = true elseif ns.GEN.nodeItems[e.id] then anyNode = true end
    end
    if anyNpc then
      tt:AddLine(L["Mobs are shown on the zone map"], 0.6, 0.6, 0.6)
    elseif anyNode and ns.S.mapNodes then
      tt:AddLine(L["Gathering nodes are shown on the zone map"], 0.6, 0.6, 0.6)
    end
    tt:Show()
    return
  end
  tt:AddLine(ns.ItemName(info.id) or string.format(L["item %d"], info.id))
  local row = ns.rowById and ns.rowById[info.id]
  if info.src then
    tt:AddDoubleLine(L["Difficulty for you"], (ns.DiffLabel(info.src.mult)), 0.8, 0.8, 0.8)
    if info.src.note and info.src.note ~= "" then tt:AddLine(info.src.note, 1, 0.6, 0.3, true) end
  end
  if info.npc then
    local n = ns.GEN.npcs[info.npc]
    local lv = n and ((n.guess and "~" or "") .. (n[1] == n[2] and tostring(n[1]) or (n[1] .. "–" .. n[2]))) or "?"
    tt:AddDoubleLine(ns.NpcName(info.npc), ns.LevelColor(n and n[1]) .. lv .. "|r", 1, 1, 1)
    if n and (n[3] == 1 or n[3] == 2) then tt:AddLine(L["elite"], 1, 0.5, 0.5) end
    local c, csrc, corpses = ns.DropChance(info.id, info.npc)
    tt:AddDoubleLine(L["chance"], ns.ChanceText(c, csrc, true), 0.8, 0.8, 0.8)
  elseif info.pool then
    tt:AddLine(ns.SchoolLabel(info.pool), 1, 1, 1)
    local f = ns.GEN.fish[info.id]
    local pct = f and f.p and f.p[info.zone] and f.p[info.zone][info.pool]
    if pct then tt:AddDoubleLine(L["chance"], ns.ChanceText(pct, "classic"), 0.8, 0.8, 0.8) end
  else
    tt:AddLine(L["gathering node"], 1, 1, 1)
  end
  if row and row.price then tt:AddDoubleLine(L["price"], ns.Money(row.price), 0.8, 0.8, 0.8) end
  if row and row.dem and not row.dem.none then tt:AddDoubleLine(L["demand"], row.dem.label, 0.8, 0.8, 0.8) end
  tt:Show()
end

function GatherScoutMapPinMixin:OnMouseLeave()
  GameTooltip:Hide()
end

---------------------------------------------------------------- data provider
local TEMPLATE = "GatherScoutMapPinTemplate"
local provider
local MAX_PINS = 1500
local PER_ITEM = 600   -- spawn points per item taken on one zone map (evenly thinned beyond that)
local CLUSTER_PX = 20  -- spawns closer than this on screen share one marker

-- Map distance (0..1) that is CLUSTER_PX on screen at the current zoom
local function clusterCell(map)
  local okW, w = pcall(function() return map:GetCanvas():GetWidth() end)
  local okS, s = pcall(function() return map:GetCanvasScale() end)
  w = (okW and type(w) == "number" and w > 0) and w or 1000
  s = (okS and type(s) == "number" and s > 0) and s or 1
  return CLUSTER_PX / (w * s)
end

local function isContinent(mapID)
  local info = C_Map.GetMapInfo(mapID)
  local cont = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
  return info and info.mapType == cont
end

-- every pin is acquired on its own, so one failure can never cut the refresh short
local failed, lastError = 0, nil
local function acquire(map, info)
  local ok, err = pcall(map.AcquirePin, map, TEMPLATE, info)
  if not ok then
    failed = failed + 1
    lastError = err
  end
end

local function populate(map)
  failed, lastError = 0, nil
  local mapID = map:GetMapID()
  if not mapID or not ns.S or not ns.S.mapShow then return end
  local items = ns.MapItems()
  if not next(items) then return end
  ns.Compute()
  local budget = MAX_PINS
  local ctx = ns.Context()
  -- mobs above what the list allows you are not drawn (unless "show dangerous" is on)
  local reachLevel = not ns.S.showDangerous and (ctx.level + (ns.S.maxAbove or 4)) or nil
  local function sourcesOf(id)
    local row = ns.rowById and ns.rowById[id]
    return (row and row.sources) or ns.Sources(id, ctx)
  end

  if ns.ZoneRange(mapID) or ns.GEN.zones[mapID] then
    -- zone map: spawns that would overlap on screen become one marker (all selected items together, a count
    -- when several items share it); zooming in splits them again. Framed in the difficulty color for you.
    local cell = clusterCell(map)
    local cells, order = {}, {}
    for id in pairs(items) do
      local src
      for _, s in ipairs(sourcesOf(id)) do
        if s.map == mapID then src = s break end -- sorted best first
      end
      local pts = pointsFor(id, mapID, ns.S.mapNodes, reachLevel)
      local step = math.max(1, math.ceil(#pts / PER_ITEM))
      for i = 1, #pts, step do
        local p = pts[i]
        local key = math.floor(p[1] / cell) * 4096 + math.floor(p[2] / cell)
        local c = cells[key]
        if not c then
          c = { x = 0, y = 0, n = 0, items = {}, list = {} }
          cells[key] = c
          order[#order + 1] = c
        end
        c.x, c.y, c.n = c.x + p[1], c.y + p[2], c.n + 1
        local e = c.items[id]
        if not e then
          e = { id = id, src = src, n = 0, mobs = {}, pools = {}, nodes = 0 }
          c.items[id] = e
          c.list[#c.list + 1] = e
        end
        e.n = e.n + 1
        if p[3] then e.mobs[p[3]] = (e.mobs[p[3]] or 0) + 1
        elseif p[4] then e.pools[p[4]] = true
        else e.nodes = e.nodes + 1 end
      end
    end
    for _, c in ipairs(order) do c.x, c.y = c.x / c.n, c.y / c.n end
    -- neighbours across a grid line can still touch: merge centres closer than one cell
    for i = 1, #order do
      local a = order[i]
      if not a.dead then
        for j = i + 1, #order do
          local b = order[j]
          if not b.dead and math.abs(a.x - b.x) < cell and math.abs(a.y - b.y) < cell then
            a.x, a.y = (a.x * a.n + b.x * b.n) / (a.n + b.n), (a.y * a.n + b.y * b.n) / (a.n + b.n)
            a.n = a.n + b.n
            for id, eb in pairs(b.items) do
              local ea = a.items[id]
              if not ea then
                a.items[id] = eb
                a.list[#a.list + 1] = eb
              else
                ea.n, ea.nodes = ea.n + eb.n, ea.nodes + eb.nodes
                for k, v in pairs(eb.mobs) do ea.mobs[k] = (ea.mobs[k] or 0) + v end
                for k in pairs(eb.pools) do ea.pools[k] = true end
              end
            end
            b.dead = true
          end
        end
      end
    end
    for _, c in ipairs(order) do
      if not c.dead and budget > 0 then
        table.sort(c.list, function(a, b) return ((a.src and a.src.mult) or 99) < ((b.src and b.src.mult) or 99) end)
        local main = c.list[1]
        local r, g, b = ns.DiffColor(main.src and main.src.mult)
        acquire(map, { x = c.x, y = c.y, id = main.id, icon = ns.ItemIcon(main.id), size = c.n >= 3 and 13 or 11,
          cluster = c, zone = mapID, count = #c.list, r = r, g = g, b = b, alpha = 0.95 })
        budget = budget - 1
      end
    end
  elseif isContinent(mapID) and C_Map.GetMapRectOnMap then
    -- continent: one small marker per zone for all selected items (no stacks), only each item's best places
    local limit = ns.S.mapSources or 3
    local rects = {}
    local function rectOf(zoneMap) -- zones of other continents have no rect here
      local r = rects[zoneMap]
      if r == nil then
        local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(zoneMap, mapID)
        r = (minX and maxX and maxX > minX) and { minX, maxX, minY, maxY } or false
        rects[zoneMap] = r
      end
      return r
    end
    local zones = {}
    for id in pairs(items) do
      local seen, n = {}, 0
      for _, src in ipairs(sourcesOf(id)) do
        if not seen[src.map] and rectOf(src.map) then -- the limit counts places on this continent
          seen[src.map] = true
          n = n + 1
          if limit > 0 and n > limit then break end
          local z = zones[src.map]
          if not z then z = { list = {} }; zones[src.map] = z end
          z.list[#z.list + 1] = { id = id, src = src }
        end
      end
    end
    for zoneMap, z in pairs(zones) do
      local minX, maxX, minY, maxY = unpack(rectOf(zoneMap))
      do
        table.sort(z.list, function(a, b) return a.src.mult < b.src.mult end)
        local best = z.list[1]
        -- where the best item's mobs / nodes are in the zone, else the zone's middle
        local pts = pointsFor(best.id, zoneMap, true, reachLevel)
        if #pts == 0 then pts = pointsFor(best.id, zoneMap, true) end
        local cx, cy = 0.5, 0.5
        if #pts > 0 then
          cx, cy = 0, 0
          for _, p in ipairs(pts) do cx, cy = cx + p[1], cy + p[2] end
          cx, cy = cx / #pts, cy / #pts
        end
        local r, g, b = ns.DiffColor(best.src.mult)
        acquire(map, { x = minX + cx * (maxX - minX), y = minY + cy * (maxY - minY), id = best.id,
          icon = ns.ItemIcon(best.id), size = 14, agg = true, map = zoneMap, list = z.list, count = #z.list,
          r = r, g = g, b = b, alpha = 0.95 })
      end
    end
  end
end

---------------------------------------------------------------- toggle button on the world map
local mapBtn

function ns.Map_UpdateButton()
  if not mapBtn then return end
  local on = ns.S.mapShow
  mapBtn.icon:SetDesaturated(not on)
  mapBtn.icon:SetAlpha(on and 1 or 0.45)
end

local function mapButtonTooltip(self)
  local S = ns.S
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(string.format(L["GatherScout on the map: %s"], ns.OnOff(S.mapShow)))
  GameTooltip:AddLine(L["Left-click: show / hide everything"], 1, 1, 1)
  GameTooltip:AddLine(string.format(L["Right-click: herb and ore nodes: %s"], ns.OnOff(S.mapNodes)), 1, 1, 1)
  local n = S.mapSources or 3
  GameTooltip:AddLine(string.format(L["Shift+left-click: places per item on the continent: %s"],
    "|cffffff00" .. (n == 0 and L["all"] or n == 1 and L["best only"] or string.format(L["best %d"], n)) .. "|r"), 1, 1, 1)
  GameTooltip:AddLine(string.format(L["Shows pinned items (star) and items picked with the “%s” button in the item card."],
    L["Show on map"]),
    0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

local function createMapButton()
  if mapBtn or not WorldMapFrame then return end
  local holder = type(WorldMapFrame.ScrollContainer) == "table" and WorldMapFrame.ScrollContainer or WorldMapFrame
  mapBtn = CreateFrame("Button", "GatherScoutMapToggle", holder)
  mapBtn:SetSize(32, 32)
  mapBtn:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 6, 6)
  if WorldMapFrame.GetFrameStrata then mapBtn:SetFrameStrata(WorldMapFrame:GetFrameStrata() or "HIGH") end
  mapBtn:SetFrameLevel(math.min(9000, (holder:GetFrameLevel() or 1) + 500))
  mapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  mapBtn.icon = mapBtn:CreateTexture(nil, "BACKGROUND")
  mapBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Herb_07")
  mapBtn.icon:SetSize(20, 20)
  mapBtn.icon:SetPoint("TOPLEFT", 7, -6)
  local border = mapBtn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(54, 54)
  border:SetPoint("TOPLEFT")
  mapBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  mapBtn:SetScript("OnClick", function(self, mouse)
    local S = ns.S
    if mouse == "RightButton" then
      S.mapNodes = not S.mapNodes
      S.mapShow = true
    elseif IsShiftKeyDown() then
      -- continent markers: best place per item -> best 3 -> all
      local NEXT = { [1] = 3, [3] = 0, [0] = 1 }
      S.mapSources = NEXT[S.mapSources or 3] or 3
      S.mapShow = true
    else
      S.mapShow = not S.mapShow
    end
    ns.Map_UpdateButton()
    ns.Map_Refresh()
    mapButtonTooltip(self)
  end)
  mapBtn:SetScript("OnEnter", mapButtonTooltip)
  mapBtn:SetScript("OnLeave", GameTooltip_Hide)
  ns.Map_UpdateButton()
end

local function createProvider()
  local okBtn, err = pcall(createMapButton)   -- the button must never block the pins
  if not okBtn and ns.debug then ns.Print("map button: %s", tostring(err)) end
  if provider or not (WorldMapFrame and WorldMapFrame.AddDataProvider and MapCanvasDataProviderMixin) then return end
  provider = CreateFromMixins(MapCanvasDataProviderMixin)
  function provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(TEMPLATE)
  end
  function provider:RefreshAllData()
    self:RemoveAllData()
    local ok, err = pcall(populate, self:GetMap())
    if ns.debug then
      if not ok then ns.Print("map: %s", tostring(err)) end
      if failed > 0 then ns.Print("map: %d pins failed, last error: %s", failed, tostring(lastError)) end
    end
  end
  -- zooming changes what overlaps on screen: regroup the markers once the zoom settles
  local zoomPending = false
  function provider:OnCanvasScaleChanged()
    if zoomPending then return end
    zoomPending = true
    C_Timer.After(0.2, function()
      zoomPending = false
      if WorldMapFrame:IsShown() then self:RefreshAllData() end
    end)
  end
  WorldMapFrame:AddDataProvider(provider)
end

function ns.Map_Refresh()
  if provider and WorldMapFrame and WorldMapFrame:IsShown() then provider:RefreshAllData() end
end

-- The card's map button: open the map on the item's best zone for you and show that item there. Only the
-- last item opened this way stays shown; pinned items follow their own setting ("Pinned on the map").
function ns.Map_Show(id)
  wipe(ns.mapSel)
  ns.mapSel[id] = true
  ns.Map_OpenFor(id)
end

function ns.Map_OpenFor(id)
  if InCombatLockdown() then
    ns.Print("%s", L["the map can be opened after combat."])
    return
  end
  local row = ns.rowById and ns.rowById[id]
  local best = row and row.best
  if WorldMapFrame and not WorldMapFrame:IsShown() then
    if ToggleWorldMap then ToggleWorldMap() else WorldMapFrame:Show() end
  end
  if best and WorldMapFrame then WorldMapFrame:SetMapID(best.map) end
  ns.Map_Refresh()
end

ns.On("PLAYER_LOGIN", createProvider)
ns.On("ADDON_LOADED", function(name)
  if name == "Blizzard_WorldMap" then createProvider() end
end)
