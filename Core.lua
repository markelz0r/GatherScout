-- GatherScout core: saved variables, events, player context, loot learning, slash commands.
local ADDON, ns = ...
local L = ns.L
_G.GatherScout = ns

ns.VERSION = "1.0.0"
ns.PREFIX = "|cff7fd4ffGatherScout|r: "

---------------------------------------------------------------- compat helpers
ns.C_Item = C_Item or {}
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or _G.GetItemIcon

-- WoW Forever hides some values ("secret values") inside instances; never compare or index them.
local issecret = _G.issecretvalue
function ns.Pub(v)
  if issecret and issecret(v) then return nil end
  return v
end

function ns.Print(...)
  print(ns.PREFIX .. string.format(...))
end

function ns.ItemName(id)
  local name = GetItemInfo(id)
  if not name and C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(id)
  end
  return name
end

function ns.ItemLink(id)
  local _, link = GetItemInfo(id)
  return link
end

function ns.ItemQuality(id)
  local _, _, q = GetItemInfo(id)
  return q
end

function ns.ItemIcon(id)
  return (GetItemIcon and GetItemIcon(id)) or 134400
end

function ns.MapName(mapID)
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  if info and info.name then return info.name end
  local z = ns.GEN and ns.GEN.zones[mapID]
  return z and z[3] or ("#" .. tostring(mapID))
end

-- Sub-zone name (area ID) in the client's language, nil when the client cannot tell
function ns.AreaName(areaID)
  if not (areaID and C_Map and C_Map.GetAreaInfo) then return nil end
  local ok, name = pcall(C_Map.GetAreaInfo, areaID)
  return ok and type(name) == "string" and name ~= "" and name or nil
end

-- Short money string with coin icons: 1[g] 25[s] (copper only below 1 gold, silver hidden from 100 gold)
local COIN = {
  g = "|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:2:0|t",
  s = "|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:2:0|t",
  c = "|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:2:0|t",
}
function ns.Money(copper, size)
  if not copper then return "—" end
  size = size or 12
  copper = math.floor(copper + 0.5)
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = ns.Num(g) .. COIN.g:format(size, size) end
  if s > 0 and g < 100 then parts[#parts + 1] = s .. COIN.s:format(size, size) end
  if c > 0 and g == 0 then parts[#parts + 1] = c .. COIN.c:format(size, size) end
  if #parts == 0 then return "0" .. COIN.c:format(size, size) end
  return table.concat(parts, " ")
end

-- Lower-case for searching (Lua's string.lower only handles ASCII): ASCII, Latin-1 accented capitals
-- (Ä É Ñ Ç … for de/fr/es/pt) and Cyrillic. CJK and Hangul have no case.
function ns.Lower(s)
  -- ASCII by hand: string.lower may touch UTF-8 bytes under some C locales
  s = (s or ""):gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)
  -- U+00C0..U+00DE (except U+00D7 ×) -> +0x20
  s = s:gsub("\195([\128-\158])", function(c)
    local b = c:byte()
    if b == 151 then return "\195" .. c end
    return "\195" .. string.char(b + 32)
  end)
  s = s:gsub("\208([\144-\175])", function(c)
    local b = c:byte()
    if b < 160 then return "\208" .. string.char(b + 32) end
    return "\209" .. string.char(b - 32)
  end)
  return (s:gsub("\208\129", "\209\145"))
end

function ns.LevelColor(level)
  if GetQuestDifficultyColor and level then
    local c = GetQuestDifficultyColor(level)
    if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
  end
  return "|cffffffff"
end

---------------------------------------------------------------- saved variables
local DEFAULTS = {
  settings = {
    enabled = true,       -- master switch for everything shown on mobs
    nameplates = true,
    targetIcon = true,
    tooltips = true,
    autoScan = true,
    autoScanMinutes = 30,
    onlyMyProfs = true,
    showDangerous = false,
    maxAbove = 4,         -- how many levels above you a source may be
    topN = 12,            -- how many best materials count as "hot" for mob marking
    minQty = 100,         -- hide items with fewer units than this on the AH (illiquid); 0 = show all
    markAll = false,      -- mark every mob that drops any tracked material, regardless of demand
    cats = { herb = true, ore = true, gem = true, skin = true, cloth = true, drop = true, elem = false,
             fish = true, dgoods = true, drecipe = true, dgear = false },
    minimap = { hide = false, angle = 205 },
    mapPinned = true,     -- show pinned (star) items on the world map
    mapShow = true,       -- master switch for everything GatherScout draws on the world map
    mapNodes = false,     -- herb / ore spawn points on zone maps (mobs and zone markers are always shown)
    mapSources = 3,       -- continent map: best N places per item (0 = all); Shift+click on the map button
    tipDemand = "icon",   -- demand in mob/node tooltips: icon | text | off
    npPos = "right",      -- nameplate icon: right (past the level badge) | top | left (Questie uses left)
    npX = 0, npY = 0, npSize = 18,
    tfX = -52, tfY = 25, tfSize = 20,
    sortKey = "score", sortDesc = true,
  },
  market = {},                 -- [realmKey] = { items = { [itemID] = rec }, lastScan = t, scanned = n }
  learned = { npc = {}, zone = {}, kills = {} }, -- npc[npcID][itemID] = corpses that had it; kills[npcID] = corpses looted
  pins = {},
}

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      merge(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

function ns.RealmKey()
  local realm = (GetRealmName and GetRealmName()) or "?"
  local faction = (UnitFactionGroup and UnitFactionGroup("player")) or "?"
  return realm .. "-" .. faction
end

function ns.Market()
  local key = ns.RealmKey()
  local m = ns.db.market[key]
  if not m then
    m = { items = {}, lastScan = 0, scanned = 0 }
    ns.db.market[key] = m
  end
  return m
end

---------------------------------------------------------------- events
local frame = CreateFrame("Frame")
ns.frame = frame
local handlers = {}
function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    frame:RegisterEvent(event)
  end
  table.insert(handlers[event], fn)
end
frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], ...)
    if not ok and ns.debug then ns.Print("error in %s: %s", event, tostring(err)) end
  end
end)

-- Results cache; anything that changes the ranking calls ns.Invalidate().
ns.dirty = true
local refreshPending = false
function ns.Invalidate()
  ns.dirty = true
  if refreshPending then return end
  refreshPending = true
  C_Timer.After(0.3, function()
    refreshPending = false
    if ns.UI_Refresh then ns.UI_Refresh() end
    if ns.Mobs_RefreshAll then ns.Mobs_RefreshAll() end
  end)
end

---------------------------------------------------------------- player context
local SKILL_IDS = { [182] = "herb", [186] = "mine", [393] = "skin", [356] = "fish" }
-- names only matter for very old clients without skill IDs; English plus the client's language
local SKILL_NAMES = {
  ["Herbalism"] = "herb", [L["Herbalism"]] = "herb",
  ["Mining"] = "mine", [L["Mining"]] = "mine",
  ["Skinning"] = "skin", [L["Skinning"]] = "skin",
  ["Fishing"] = "fish", [L["Fishing"]] = "fish",
}
-- Fishing counts with its bonus (fishing pole, lure): the catch chance depends on the total
local function skillValue(key, rank, modifier)
  rank = rank or 0
  if key == "fish" and type(modifier) == "number" and modifier > 0 then return rank + modifier end
  return rank
end

function ns.ReadProfessions()
  local res = {}
  if C_SkillInfo and C_SkillInfo.GetNumSkillLines then
    -- Expand collapsed headers back to front (same approach Questie uses on Forever).
    if C_SkillInfo.ExpandSkillHeader then
      for i = C_SkillInfo.GetNumSkillLines(), 1, -1 do
        local info = C_SkillInfo.GetSkillLineInfo(i)
        if info and info.isHeader and info.isCollapsed then C_SkillInfo.ExpandSkillHeader(i) end
      end
    end
    for i = 1, C_SkillInfo.GetNumSkillLines() do
      local info = C_SkillInfo.GetSkillLineInfo(i)
      if info and not info.isHeader then
        local key = SKILL_IDS[info.skillID] or SKILL_NAMES[info.name or ""]
        if key then res[key] = skillValue(key, info.rank, info.skillModifier or info.modifier) end
      end
    end
  elseif GetNumSkillLines then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank, _, modifier = GetSkillLineInfo(i)
      local key = name and not isHeader and SKILL_NAMES[name]
      if key then res[key] = skillValue(key, rank, modifier) end
    end
  end
  if not next(res) and GetProfessions then
    local p1, p2, _, fishing = GetProfessions()
    for _, idx in ipairs({ p1, p2, fishing }) do
      local _, _, rank, _, _, _, skillLine, modifier = GetProfessionInfo(idx)
      if SKILL_IDS[skillLine] then res[SKILL_IDS[skillLine]] = skillValue(SKILL_IDS[skillLine], rank, modifier) end
    end
  end
  ns.profs = res
  return res
end

function ns.Context()
  local ctx = ns.ctx
  if not ctx then
    ctx = {}
    ns.ctx = ctx
  end
  ctx.level = UnitLevel("player") or 1
  ctx.faction = UnitFactionGroup("player") -- "Alliance" | "Horde"
  ctx.profs = ns.profs or ns.ReadProfessions()
  return ctx
end

-- Current zone uiMapID (walks up from sub-zone / cave maps to a zone we know)
function ns.PlayerZone()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local id = C_Map.GetBestMapForUnit("player")
  local guard = 0
  while id and guard < 6 do
    if ns.ZoneRange(id) then return id end
    local info = C_Map.GetMapInfo(id)
    id = info and info.parentMapID
    guard = guard + 1
  end
  return nil
end

---------------------------------------------------------------- loot learning
-- Remembers which mobs dropped / were skinned for tracked materials and which zones you gathered them in.
-- That fills in Forever content the database does not cover yet (e.g. new Hyjal herbs).
local function npcIDFromGUID(guid)
  guid = ns.Pub(guid)
  if type(guid) ~= "string" then return nil end
  local kind, _, _, _, _, id = strsplit("-", guid)
  if kind == "Creature" then return tonumber(id), "npc" end
  if kind == "GameObject" then return tonumber(id), "object" end
  return nil
end
ns.NpcIDFromGUID = npcIDFromGUID

-- Also counts looted corpses per mob, so drop chances can be estimated from your own kills
-- (drops / corpses). Each corpse (GUID) counts once, even if the loot window is reopened or the mob is skinned.
local lootSeen, lootSeenCount = {}, 0
ns.On("LOOT_OPENED", function()
  if IsInInstance() then return end
  local learned = ns.db.learned
  learned.kills = learned.kills or {}
  local zone = ns.PlayerZone()
  local changed = false
  for slot = 1, (GetNumLootItems() or 0) do
    local link = ns.Pub(GetLootSlotLink(slot))
    local itemID = link and tonumber(link:match("item:(%d+)"))
    local tracked = itemID and ns.IsTracked and ns.IsTracked(itemID)
    local sources = { GetLootSourceInfo(slot) }
    for i = 1, #sources, 2 do
      local guid = ns.Pub(sources[i])
      local id, kind = npcIDFromGUID(guid)
      local qty = tonumber(ns.Pub(sources[i + 1])) or 1
      if kind == "npc" and id then
        local seen = lootSeen[guid]
        if not seen then
          seen = {}
          lootSeen[guid] = seen
          lootSeenCount = lootSeenCount + 1
          learned.kills[id] = (learned.kills[id] or 0) + 1
          changed = true
        end
        if tracked and not seen[itemID] then
          seen[itemID] = true
          learned.npc[id] = learned.npc[id] or {}
          learned.npc[id][itemID] = (learned.npc[id][itemID] or 0) + 1
        end
      end
      if tracked and zone and ns.MAT[itemID] and (kind == "object" or kind == "npc") then
        learned.zone[zone] = learned.zone[zone] or {}
        learned.zone[zone][itemID] = (learned.zone[zone][itemID] or 0) + qty
        changed = true
      end
    end
  end
  if lootSeenCount > 3000 then lootSeen, lootSeenCount = {}, 0 end
  if changed then ns.Invalidate() end
end)

---------------------------------------------------------------- lifecycle
ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  GatherScoutDB = GatherScoutDB or {}
  merge(GatherScoutDB, DEFAULTS)
  ns.db = GatherScoutDB
  ns.S = GatherScoutDB.settings
  if ns.BuildIndexes then ns.BuildIndexes() end
end)

ns.On("PLAYER_LOGIN", function()
  ns.ReadProfessions()
  if ns.UI_Init then ns.UI_Init() end
  if ns.Mobs_Init then ns.Mobs_Init() end
  -- Warm the item cache so names show up in the list.
  if C_Item and C_Item.RequestLoadItemDataByID then
    for id in pairs(ns.MAT) do C_Item.RequestLoadItemDataByID(id) end
  end
end)

ns.On("SKILL_LINES_CHANGED", function()
  ns.ReadProfessions()
  ns.Invalidate()
end)
ns.On("PLAYER_LEVEL_UP", function() C_Timer.After(0.5, ns.Invalidate) end)

local itemInfoPending = false
ns.On("GET_ITEM_INFO_RECEIVED", function(itemID)
  if not (ns.IsTracked and ns.IsTracked(itemID)) or itemInfoPending then return end
  itemInfoPending = true
  C_Timer.After(1, function()
    itemInfoPending = false
    if ns.UI_Refresh then ns.UI_Refresh(true) end
  end)
end)

---------------------------------------------------------------- slash commands
SLASH_GATHERSCOUT1 = "/gs"
SLASH_GATHERSCOUT2 = "/gatherscout"
SlashCmdList.GATHERSCOUT = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local S = ns.S
  if msg == "" then
    if ns.UI_Toggle then ns.UI_Toggle() end
  elseif msg == "scan" or msg == L["cmd:scan"] then
    if ns.Scan_Full then ns.Scan_Full(true) end
  elseif msg == "quick" or msg == L["cmd:quick"] then
    if ns.Scan_Start then ns.Scan_Start(true) end
  elseif msg == "on" or msg == "off" or msg == "toggle" then
    if msg == "toggle" then S.enabled = not S.enabled else S.enabled = (msg == "on") end
    ns.Print(L["mob markers %s"], S.enabled and ("|cff00ff00" .. L["enabled"] .. "|r") or ("|cffff4040" .. L["disabled"] .. "|r"))
    ns.Invalidate()
  elseif msg == "minimap" then
    S.minimap.hide = not S.minimap.hide
    if ns.Minimap_Update then ns.Minimap_Update() end
  elseif msg:match("^demand") or msg:find(L["cmd:demand"], 1, true) == 1 then
    local mode = msg:match("(%a+)$")
    local next = { icon = "text", text = "off", off = "icon" }
    if mode == "icon" or mode == "text" or mode == "off" then S.tipDemand = mode
    else S.tipDemand = next[S.tipDemand] or "icon" end
    ns.Print(L["demand in tooltips: %s"], ({ icon = L["icon"], text = L["text"], off = L["hidden"] })[S.tipDemand])
    if ns.UI_Refresh then ns.UI_Refresh() end
  elseif msg == "map" or msg == L["cmd:map"] then
    S.mapShow = not S.mapShow
    ns.Print(L["on the map: %s"], ns.OnOff(S.mapShow))
    if ns.Map_UpdateButton then ns.Map_UpdateButton() end
    if ns.Map_Refresh then ns.Map_Refresh() end
  elseif msg == "nodes" or msg == L["cmd:nodes"] then
    S.mapNodes = not S.mapNodes
    ns.Print(L["herb and ore nodes on the map: %s"], ns.OnOff(S.mapNodes))
    if ns.Map_Refresh then ns.Map_Refresh() end
  elseif msg:match("^icon") then
    -- /gs icon <dx> <dy> [size] : fine-tune the nameplate icon; /gs icon reset
    local dx, dy, size = msg:match("^icon%s+(%-?%d+)%s+(%-?%d+)%s*(%d*)")
    if msg:match("reset") then
      S.npX, S.npY, S.npSize = 0, 0, 18
    elseif dx then
      S.npX, S.npY = tonumber(dx), tonumber(dy)
      if size ~= "" then S.npSize = math.max(8, math.min(40, tonumber(size))) end
    end
    ns.Print(L["nameplate icon: offset %d, %d, size %d (|cffffff00/gs icon <x> <y> [size]|r, |cffffff00/gs icon reset|r)"],
      S.npX, S.npY, S.npSize)
    if ns.Mobs_RefreshAll then ns.Mobs_RefreshAll() end
  elseif msg == "reset" then
    ns.db.market[ns.RealmKey()] = nil
    ns.Print(L["auction data for %s cleared."], ns.RealmKey())
    ns.Invalidate()
  elseif msg == "forget" then
    ns.db.learned = { npc = {}, zone = {}, kills = {} }
    ns.Print("%s", L["learned drops and zones cleared."])
    ns.Invalidate()
  elseif msg == "debug" then
    ns.debug = not ns.debug
    ns.Print("debug %s", ns.debug and "on" or "off")
  else
    ns.Print("%s", L["commands: |cffffff00/gs|r — window, |cffffff00/gs scan|r — full scan (at the auction house), "
      .. "|cffffff00/gs quick|r — quick scan of materials, |cffffff00/gs on|r / |cffffff00/gs off|r — mob markers, "
      .. "|cffffff00/gs minimap|r — minimap button, |cffffff00/gs reset|r — clear prices, "
      .. "|cffffff00/gs forget|r — forget learned drops"])
  end
end
