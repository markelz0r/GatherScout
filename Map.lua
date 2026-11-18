-- GatherScout world map: on a zone map, mob spawns (and, if enabled, herb/ore spawn points) for the selected
-- items; on a continent map, one marker per zone where you can get them (level range, difficulty for you).
-- Selected = items you toggled with "На карте" this session + pinned items (option).
-- A button on the map toggles everything (left click) or the herb/ore points (right click).
local _, ns = ...

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

-- { {x, y, npcID|nil}, ... } for item `id` on zone map `mapID`; herb/ore spawn points only with `withNodes`
local function pointsFor(id, mapID, withNodes)
  local out = {}
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

function GatherScoutMapPinMixin:OnLoad()
  -- Hover only, no clicks: for click-enabled pins the map runs extra setup (SetPassThroughButtons) that can
  -- fail on new clients, which used to abort the whole refresh after a few pins.
  if self.SetMouseClickEnabled then self:SetMouseClickEnabled(false) end
  if self.SetMouseMotionEnabled then self:SetMouseMotionEnabled(true) end
  if self.UseFrameLevelType then pcall(self.UseFrameLevelType, self, "PIN_FRAME_LEVEL_AREA_POI") end
  if self.SetScalingLimits then self:SetScalingLimits(1, 1.0, 1.25) end
end

-- same workaround as HereBeDragons-Pins ("hack to avoid in-combat error")
GatherScoutMapPinMixin.SetPassThroughButtons = function() end

function GatherScoutMapPinMixin:OnAcquired(info)
  self.info = info
  self:SetSize(info.size, info.size)
  self.Texture:SetTexture(info.icon)
  self.Texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  self.Border:SetShown(info.agg == true)
  self:SetPosition(info.x, info.y)
end

function GatherScoutMapPinMixin:OnMouseEnter()
  local info = self.info
  if not info then return end
  local tt = GameTooltip
  tt:SetOwner(self, "ANCHOR_RIGHT")
  tt:AddLine(ns.ItemName(info.id) or ("item " .. info.id))
  local row = ns.rowById and ns.rowById[info.id]
  if info.agg then
    local src = info.src
    tt:AddLine(ns.WhereText(src, info.id), 1, 1, 1)
    tt:AddDoubleLine("Сложность для тебя", (ns.DiffLabel(src.mult)), 0.8, 0.8, 0.8)
    if src.note and src.note ~= "" then tt:AddLine(src.note, 1, 0.6, 0.3, true) end
    if ns.NpcList(info.id) then
      tt:AddLine("На карте зоны видны мобы", 0.6, 0.6, 0.6)
    elseif ns.GEN.nodeItems[info.id] and ns.S.mapNodes then
      tt:AddLine("На карте зоны видны точки сбора", 0.6, 0.6, 0.6)
    end
  elseif info.npc then
    local n = ns.GEN.npcs[info.npc]
    local lv = n and (n[1] == n[2] and tostring(n[1]) or (n[1] .. "–" .. n[2])) or "?"
    tt:AddDoubleLine(ns.NpcName(info.npc), ns.LevelColor(n and n[1]) .. lv .. "|r", 1, 1, 1)
    if n and (n[3] == 1 or n[3] == 2) then tt:AddLine("элитный", 1, 0.5, 0.5) end
    local c, csrc, corpses = ns.DropChance(info.id, info.npc)
    if c then tt:AddDoubleLine("шанс", ns.ChanceText(c, csrc, corpses), 0.8, 0.8, 0.8) end
  else
    tt:AddLine("точка сбора", 1, 1, 1)
  end
  if row and row.price then tt:AddDoubleLine("цена", ns.Money(row.price), 0.8, 0.8, 0.8) end
  if row and row.dem and not row.dem.none then tt:AddDoubleLine("спрос", row.dem.label, 0.8, 0.8, 0.8) end
  tt:Show()
end

function GatherScoutMapPinMixin:OnMouseLeave()
  GameTooltip:Hide()
end

---------------------------------------------------------------- data provider
local TEMPLATE = "GatherScoutMapPinTemplate"
local provider
local MAX_PINS = 1500

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

  if ns.ZoneRange(mapID) or ns.GEN.zones[mapID] then
    for id in pairs(items) do
      local icon = ns.ItemIcon(id)
      local pts = pointsFor(id, mapID, ns.S.mapNodes)
      local step = math.max(1, math.ceil(#pts / math.max(1, budget)))
      for i = 1, #pts, step do
        local p = pts[i]
        acquire(map, { x = p[1], y = p[2], id = id, icon = icon, size = p[3] and 14 or 12, npc = p[3] })
        budget = budget - 1
      end
    end
  elseif isContinent(mapID) and C_Map.GetMapRectOnMap then
    local ctx = ns.Context()
    for id in pairs(items) do
      local icon = ns.ItemIcon(id)
      local row = ns.rowById and ns.rowById[id]
      local sources = (row and row.sources) or ns.Sources(id, ctx)
      local done = {}
      for _, src in ipairs(sources) do
        if not done[src.map] then
          done[src.map] = true
          local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(src.map, mapID)
          if minX and maxX and maxX > minX then
            local pts = pointsFor(id, src.map, true)
            local cx, cy = 0.5, 0.5
            if #pts > 0 then
              cx, cy = 0, 0
              for _, p in ipairs(pts) do cx, cy = cx + p[1], cy + p[2] end
              cx, cy = cx / #pts, cy / #pts
            end
            acquire(map, { x = minX + cx * (maxX - minX), y = minY + cy * (maxY - minY), id = id,
              icon = icon, size = 24, agg = true, src = src })
          end
        end
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
  GameTooltip:AddLine("GatherScout на карте: " .. (S.mapShow and "|cff00ff00вкл|r" or "|cffff4040выкл|r"))
  GameTooltip:AddLine("ЛКМ — показать / скрыть всё", 1, 1, 1)
  GameTooltip:AddLine("ПКМ — точки трав и руды: " .. (S.mapNodes and "|cff00ff00вкл|r" or "|cffff4040выкл|r"), 1, 1, 1)
  GameTooltip:AddLine("Показывается закреплённое (звезда) и выбранное кнопкой «На карте» в карточке предмета.",
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
  WorldMapFrame:AddDataProvider(provider)
end

function ns.Map_Refresh()
  if provider and WorldMapFrame and WorldMapFrame:IsShown() then provider:RefreshAllData() end
end

-- Toggle an item on the map; with `open`, also open the map on its best zone for you
function ns.Map_Toggle(id, open)
  if ns.mapSel[id] then ns.mapSel[id] = nil else ns.mapSel[id] = true end
  ns.Map_Refresh()
  if open and ns.mapSel[id] then ns.Map_OpenFor(id) end
end

function ns.Map_OpenFor(id)
  if InCombatLockdown() then
    ns.Print("карту можно открыть после боя.")
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
