-- Minimal WoW API emulation to smoke-test GatherScout outside the game (Lua 5.4 via lupa).
-- Client language: set TEST_LOCALE ("enUS", "ruRU", ...) before running this file; Russian by default.
local unpack = table.unpack
_G.unpack = _G.unpack or table.unpack   -- WoW's Lua 5.1 global
math.log10 = math.log10 or function(x) return math.log(x, 10) end
math.atan2 = math.atan2 or math.atan
loadstring = loadstring or load
TEST_LOCALE = TEST_LOCALE or "ruRU"

-- Everything the addon shows (chat, tooltips, font strings), kept for CheckOutputLanguage()
local OUTPUT = {}
local function shown(t) if t ~= nil then OUTPUT[#OUTPUT + 1] = tostring(t) end end

local LOG = {}
local function log(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end LOG[#LOG + 1] = table.concat(t, " "); shown(LOG[#LOG]) end
print = function(...) log(...) end

local clock = 0
local timeOffset = 0
date = os.date
time = function(t) if t then return os.time(t) end return os.time() + timeOffset end
GetTime = function() return clock end

function strsplit(sep, s)
  local out = {}
  for piece in (s .. sep):gmatch("(.-)%" .. sep) do out[#out + 1] = piece end
  return unpack(out)
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
UISpecialFrames = {}
SlashCmdList = {}
Enum = { TooltipDataType = { Unit = 2 }, AuctionHouseSortOrder = { Price = 0 } }

---------------------------------------------------------------- frames
local registered = {}
local allFrames = {}
local Frame = {}
local methods = {}
Frame.__index = function(self, k)
  local v = methods[k]
  if v then return v end
  if type(k) ~= "string" or k:find("^GatherScout") or not k:find("^[A-Z]") then return nil end
  return function() return nil end
end
local function newObj(kind, parent)
  local o = setmetatable({ _kind = kind, _shown = true, _w = 100, _h = 20, _scripts = {}, _parent = parent,
    _text = "", _lines = {} }, Frame)
  allFrames[#allFrames + 1] = o
  return o
end
function methods:CreateTexture() return newObj("Texture", self) end
function methods:CreateFontString() return newObj("FontString", self) end
function methods:CreateLine() return newObj("Line", self) end
function methods:SetSize(w, h) self._w, self._h = w, h end
function methods:SetWidth(w) self._w = w end
function methods:SetHeight(h) self._h = h end
function methods:GetWidth() return self._w end
function methods:GetHeight() return self._h end
function methods:GetStringWidth() return #(self._text or "") * 4 end
function methods:GetStringHeight()
  local n = 1
  for _ in (self._text or ""):gmatch("\n") do n = n + 1 end
  return n * 14 + (n - 1) * 4
end
function methods:SetText(t) self._text = t; shown(t) end
function methods:GetText() return self._text end
function methods:Show() local was = self._shown; self._shown = true; if not was and self._scripts.OnShow then self._scripts.OnShow(self) end end
function methods:Hide() local was = self._shown; self._shown = false; if was and self._scripts.OnHide then self._scripts.OnHide(self) end end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:IsShown() return self._shown end
function methods:SetScript(name, fn) self._scripts[name] = fn end
function methods:GetScript(name) return self._scripts[name] end
function methods:HookScript(name, fn) self._scripts[name] = fn end
function methods:HasScript() return true end
function methods:RegisterEvent(e) registered[e] = registered[e] or {}; table.insert(registered[e], self) end
function methods:GetChecked() return self._checked end
function methods:SetChecked(v) self._checked = v end
function methods:GetParent() return self._parent end
function methods:SetParent(p) self._parent = p end
function methods:GetCenter() return 100, 100 end
function methods:GetEffectiveScale() return 1 end
function methods:AddLine(t) self._lines[#self._lines + 1] = tostring(t); shown(t) end
function methods:AddDoubleLine(a, b) self._lines[#self._lines + 1] = tostring(a) .. "  ||  " .. tostring(b); shown(a); shown(b) end
function methods:SetOwner() self._lines = {} end
function methods:SetItemByID(id) self._lines[#self._lines + 1] = "[item " .. id .. "]" end

function CreateFrame(kind, name, parent, template)
  local f = newObj(kind, parent)
  if name then _G[name] = f end
  return f
end

UIParent = CreateFrame("Frame", "UIParent")
GameTooltip = CreateFrame("GameTooltip", "GameTooltip")
GameTooltip_Hide = function() end
TargetFrame = CreateFrame("Frame", "TargetFrame")
Minimap = CreateFrame("Frame", "Minimap"); Minimap._w = 140
BackdropTemplateMixin = {}
ITEM_QUALITY_COLORS = { [1] = { hex = "|cffffffff" }, [2] = { hex = "|cff1eff00" } }
GetLocale = function() return TEST_LOCALE end
-- names the client itself gives in its language (creature types, skill lines)
local CLIENT = {
  ruRU = { beast = "Животное", humanoid = "Гуманоид", professions = "Профессии", herbalism = "Травничество",
    skinning = "Снятие шкур", cooking = "Кулинария" },
  enUS = { beast = "Beast", humanoid = "Humanoid", professions = "Professions", herbalism = "Herbalism",
    skinning = "Skinning", cooking = "Cooking" },
}
CT = CLIENT[TEST_LOCALE] or CLIENT.enUS

-- Fails when a non-Russian client would see Cyrillic anywhere in what the addon showed so far.
-- Returns how many texts were checked.
function CheckOutputLanguage()
  if TEST_LOCALE == "ruRU" then return #OUTPUT end
  local bad = {}
  for _, s in ipairs(OUTPUT) do
    if s:find("[\208-\211][\128-\191]") then bad[#bad + 1] = s end
  end
  if #bad > 0 then
    error(string.format("%d Cyrillic texts in %s output, e.g.: %s", #bad, TEST_LOCALE,
      table.concat(bad, " // ", 1, math.min(5, #bad))), 0)
  end
  return #OUTPUT
end
GetCursorPosition = function() return 0, 0 end
IsModifiedClick = function() return false end
ChatEdit_InsertLink = function() end
GetQuestDifficultyColor = function(l) return { r = 1, g = 1, b = 0 } end
IsInInstance = function() return false end
GetRealmName = function() return "TestRealm" end

---------------------------------------------------------------- timers & events
local timers = {}
C_Timer = { After = function(s, fn) timers[#timers + 1] = fn end }
local pendingEvents = {}
function FireEvent(e, ...)
  for _, f in ipairs(registered[e] or {}) do
    local h = f._scripts.OnEvent
    if h then h(f, e, ...) end
  end
end
function Tick(n)
  for _ = 1, (n or 1) do
    clock = clock + 0.05
    local t = timers; timers = {}
    for _, fn in ipairs(t) do fn() end
    local ev = pendingEvents; pendingEvents = {}
    for _, e in ipairs(ev) do FireEvent(unpack(e)) end
    for _, f in ipairs(allFrames) do
      if f._shown and f._scripts.OnUpdate then f._scripts.OnUpdate(f, 0.05) end
    end
  end
end
function ShiftTime(sec) timeOffset = timeOffset + sec end

---------------------------------------------------------------- player / world
PLAYER_LEVEL = 35
UnitLevel = function(u) if u == "player" then return PLAYER_LEVEL end return MOB_LEVEL or 54 end
UnitFactionGroup = function() return "Alliance" end
MOB_GUID = "Creature-0-1-2-3-6498-00001"
UnitGUID = function(u) if u == "player" then return "Player-1-1" end return MOB_GUID end
UnitIsPlayer = function() return false end
UnitCanAttack = function() return true end
UnitExists = function() return true end
UnitCreatureType = function() return MOB_TYPE or CT.beast end
C_SkillInfo = {
  GetNumSkillLines = function() return 4 end,
  GetSkillLineInfo = function(i)
    return ({ { name = CT.professions, isHeader = true },
      { name = CT.herbalism, skillID = 182, rank = 190 },
      { name = CT.skinning, skillID = 393, rank = SKIN_RANK or 200 },
      { name = CT.cooking, skillID = 185, rank = 50 } })[i]
  end,
  ExpandSkillHeader = function() end,
}
C_Map = {
  GetBestMapForUnit = function() return 1417 end,
  GetMapInfo = function(id) return { name = "Zone" .. id } end,
}
C_Item = {
  GetItemInfo = function(id) return "Item" .. id, "|cffffffff|Hitem:" .. id .. "::::|h[Item" .. id .. "]|h|r", 1 end,
  GetItemIconByID = function() return 134400 end,
  RequestLoadItemDataByID = function() end,
}
local plate = CreateFrame("Frame")
plate.UnitFrame = CreateFrame("Frame"); plate.UnitFrame.healthBar = CreateFrame("StatusBar")
plate.namePlateUnitToken = "nameplate1"
C_NamePlate = { GetNamePlateForUnit = function() return plate end, GetNamePlates = function() return { plate } end }
TEST_PLATE = plate

local postCalls = {}
TooltipDataProcessor = { AddTooltipPostCall = function(t, fn) postCalls[#postCalls + 1] = fn end }
function FireUnitTooltip(guid)
  GameTooltip._lines = {}
  for _, fn in ipairs(postCalls) do fn(GameTooltip, { guid = guid }) end
  return GameTooltip._lines
end

-- loot
LOOT = {}
GetNumLootItems = function() return #LOOT end
GetLootSlotLink = function(i) return "|cffffffff|Hitem:" .. LOOT[i].id .. "::|h[x]|h|r" end
GetLootSourceInfo = function(i) return LOOT[i].guid, LOOT[i].qty end

---------------------------------------------------------------- auction house
AH_QTY = {}   -- itemID -> total quantity (0 = none), set by the test
local function key(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end
local function rowsFor(id)
  local q = AH_QTY[id] or 0
  local rows = {}
  local base = 100 + (id % 97) * 37
  local left, i = q, 0
  while left > 0 do
    i = i + 1
    local take = math.min(left, 20)
    rows[#rows + 1] = { unitPrice = base + i * 3, quantity = take }
    left = left - take
  end
  return rows
end
C_AuctionHouse = {
  MakeItemKey = key,
  GetItemKeyInfo = function() return {} end,
  IsThrottledMessageSystemReady = function() return true end,
  SendSearchQuery = function(k)
    if k.itemID % 5 == 0 then
      pendingEvents[#pendingEvents + 1] = { "ITEM_SEARCH_RESULTS_UPDATED", key(k.itemID) }
    else
      pendingEvents[#pendingEvents + 1] = { "COMMODITY_SEARCH_RESULTS_UPDATED", k.itemID }
    end
  end,
  HasSearchResults = function() return true end,
  HasFullCommoditySearchResults = function() return true end,
  HasFullItemSearchResults = function() return true end,
  GetCommoditySearchResultsQuantity = function(id) return AH_QTY[id] or 0 end,
  GetItemSearchResultsQuantity = function(k) return AH_QTY[k.itemID] or 0 end,
  GetNumCommoditySearchResults = function(id) return #rowsFor(id) end,
  GetNumItemSearchResults = function(k) return #rowsFor(k.itemID) end,
  GetCommoditySearchResultInfo = function(id, i) return rowsFor(id)[i] end,
  GetItemSearchResultInfo = function(k, i)
    local r = rowsFor(k.itemID)[i]
    return r and { buyoutAmount = r.unitPrice * r.quantity, quantity = r.quantity }
  end,
}
AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame")

---------------------------------------------------------------- optional Auctionator mock
function InstallAuctionator()
  local day0 = os.time({ year = 2020, month = 1, day = 1, hour = 0 })
  local today = math.floor((os.time() - day0) / 86400)
  Auctionator = {
    Constants = { SCAN_DAY_0 = day0 },
    API = { v1 = { GetAuctionPriceByItemID = function(_, id) return 5000 + id end } },
    Database = {
      GetPriceHistory = function(self, dbKey)
        local id = tonumber(dbKey)
        if id ~= 13464 and id ~= 2447 then return {} end
        local out = {}
        for d = 0, 14 do
          out[#out + 1] = { rawDay = tostring(today - d), minSeen = 900 + d * 20, maxSeen = 1100 + d * 20, available = 300 + d * 10 }
        end
        return out
      end,
    },
  }
end

function LOGS() local l = LOG; LOG = {}; return l end

---------------------------------------------------------------- v2 mocks: tickers, replicate scan, world map
local tickers = {}
C_Timer.NewTicker = function(sec, fn)
  local t = { fn = fn, cancelled = false }
  function t:Cancel() self.cancelled = true end
  tickers[#tickers + 1] = t
  return t
end
local baseTick = Tick
function Tick(n)
  for _ = 1, (n or 1) do
    baseTick(1)
    for _, t in ipairs(tickers) do if not t.cancelled then t.fn() end end
  end
end
IsShiftKeyDown = function() return false end
InCombatLockdown = function() return false end

REPL = {}  -- { {itemID, count, buyout}, ... }
C_AuctionHouse.ReplicateItems = function() pendingEvents[#pendingEvents + 1] = { "REPLICATE_ITEM_LIST_UPDATE" } end
C_AuctionHouse.GetNumReplicateItems = function() return #REPL end
C_AuctionHouse.GetReplicateItemInfo = function(i)
  local r = REPL[i + 1]
  if not r then return nil end
  return "n", 1, r[2], 1, true, 1, 0, 0, 0, r[3], 0, false, nil, "x", "x", 0, r[1], true
end

function CreateFromMixins(...)
  local out = {}
  for i = 1, select("#", ...) do for k, v in pairs((select(i, ...))) do out[k] = v end end
  return out
end
MapCanvasPinMixin = { SetPosition = function(self, x, y) self._x, self._y = x, y end,
  SetScalingLimits = function() end, UseFrameLevelType = function() end }
MapCanvasDataProviderMixin = { GetMap = function(self) return self._map end,
  RefreshAllData = function() end, RemoveAllData = function() end }
CUR_MAP = 1440
PINS = {}
WorldMapFrame = CreateFrame("Frame", "WorldMapFrame"); WorldMapFrame._shown = false
WorldMapFrame.AddDataProvider = function(self, p) p._map = self; self._provider = p end
WorldMapFrame.GetMapID = function() return CUR_MAP end
WorldMapFrame.SetMapID = function(self, id) CUR_MAP = id; if self._provider then self._provider:RefreshAllData() end end
WorldMapFrame.RemoveAllPinsByTemplate = function() PINS = {} end
WorldMapFrame.AcquirePin = function(self, template, info)
  local pin = CreateFrame("Frame")
  for k, v in pairs(GatherScoutMapPinMixin) do pin[k] = v end
  pin.Texture = pin:CreateTexture(); pin.Edge = pin:CreateTexture(); pin.Shadow = pin:CreateTexture()
  pin:OnLoad(); pin:OnAcquired(info)
  PINS[#PINS + 1] = pin
  return pin
end
ToggleWorldMap = function() WorldMapFrame:Show(); if WorldMapFrame._provider then WorldMapFrame._provider:RefreshAllData() end end
C_Map.GetMapInfo = function(id) return { name = "Zone" .. id, mapType = (id == 1414 or id == 1415) and 2 or 3 } end
C_Map.GetMapRectOnMap = function(zone, cont) return 0.1, 0.3, 0.2, 0.4 end

---------------------------------------------------------------- v3: typed tooltip post-calls (unit / object)
Enum.TooltipDataType.Object = 3
local typed = {}
TooltipDataProcessor.AddTooltipPostCall = function(t, fn) typed[#typed + 1] = { t = t, fn = fn } end
GameTooltip.GetPrimaryTooltipData = function(self) return self._primary end
function FireUnitTooltip(guid)
  GameTooltip._lines = {}
  local data = { guid = guid }
  GameTooltip._primary = data
  for _, e in ipairs(typed) do if e.t == 2 then e.fn(GameTooltip, data) end end
  return GameTooltip._lines
end
function FireObjectTooltip(name)
  GameTooltip._lines = {}
  local scr = GameTooltip._scripts.OnTooltipCleared
  if scr then scr(GameTooltip) end
  local data = { lines = { { leftText = name } } }
  GameTooltip._primary = data
  for _, e in ipairs(typed) do if e.t == 3 then e.fn(GameTooltip, data) end end
  return GameTooltip._lines
end
