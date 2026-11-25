-- Whole-addon smoke test with a mocked WoW API: loads every file from the .toc in order under a given
-- client locale, fires the login/AH events, builds the list window and the item card, opens tooltips.
-- Globals in: ADDON_DIR, TEST_LOCALE. Prints what the UI would show (texts only).
local ADDON, LOC = ADDON_DIR, TEST_LOCALE
local unknownGlobals = {}
local created = {}

---------------------------------------------------------------- mock objects
local methods = {}
local Mock = { __index = function(_, k)
  if methods[k] then return methods[k] end
  if type(k) == "string" and k:match("^%u") then return function() end end
  return nil
end }
local function new(kind)
  return setmetatable({ _kind = kind, _text = "", _shown = true, _scripts = {}, _w = 0, _h = 0 }, Mock)
end
local function vwidth(s)
  s = (s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "WW")
  local w = 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    w = w + ((#ch >= 3 and ch:byte() >= 0xE1) and 9 or 4.6) -- CJK/Hangul ~2x Latin
  end
  return w
end
methods.SetText = function(s, t) s._text = t or "" end
methods.GetText = function(s) return s._text end
methods.SetFormattedText = function(s, f, ...) s._text = string.format(f, ...) end
methods.Show = function(s) s._shown = true end
methods.Hide = function(s) s._shown = false end
methods.SetShown = function(s, v) s._shown = not not v end
methods.IsShown = function(s) return s._shown end
methods.IsVisible = function(s) return s._shown end
methods.CreateFontString = function(s) local o = new("fs"); o._parent = s; created[#created + 1] = o; return o end
methods.CreateTexture = function(s) local o = new("tex"); o._parent = s; return o end
methods.CreateLine = methods.CreateTexture
methods.GetStringHeight = function(s)
  local n = 1
  for _ in (s._text or ""):gmatch("\n") do n = n + 1 end
  return n * 14 + (n - 1) * 4
end
methods.GetStringWidth = function(s) return vwidth(s._text) end
methods.GetFontString = function(s)
  if not s._fs then s._fs = new("fs") end
  s._fs._text = s._text
  return s._fs
end
methods.SetScript = function(s, k, f) s._scripts[k] = f end
methods.GetScript = function(s, k) return s._scripts[k] end
methods.HookScript = methods.SetScript
methods.HasScript = function() return true end
methods.IsMouseOver = function(s) return s._mouse == true end
methods.GetWidth = function(s) return s._w end
methods.GetHeight = function(s) return s._h end
methods.SetWidth = function(s, w) s._w = w end
methods.SetHeight = function(s, h) s._h = h end
methods.SetSize = function(s, w, h) s._w, s._h = w, h end
methods.SetPoint = function(s, ...) s._pt = { ... } end
methods.GetTop = function() return 760 end
methods.GetEffectiveScale = function() return 1 end
methods.GetCenter = function() return 100, 100 end
methods.GetFont = function() return "font", 10, "" end
methods.GetChecked = function(s) return s._checked end
methods.SetChecked = function(s, v) s._checked = v end
methods.GetFrameLevel = function() return 1 end
methods.GetFrameStrata = function() return "HIGH" end
methods.HasFocus = function() return false end
methods.GetParent = function(s) return s._parent end

CreateFrame = function(t, name, parent, template)
  local o = new(t)
  o._parent = parent
  o._template = template
  if name then _G[name] = o end
  created[#created + 1] = o
  return o
end
GameTooltip = new("tooltip")
local tt = {}
GameTooltip.SetOwner = function(_, owner, anchor) tt = { anchor = anchor } end
GameTooltip.AddLine = function(_, t) tt[#tt + 1] = tostring(t) end
GameTooltip.AddDoubleLine = function(_, l, r) tt[#tt + 1] = tostring(l) .. "  ||  " .. tostring(r) end
GameTooltip.SetItemByID = function(_, id) tt[#tt + 1] = "<item " .. id .. ">" end
GameTooltip.GetHeight = function() return #tt * 14 + 20 end
GameTooltip.GetName = function() return "GameTooltip" end
GameTooltip_Hide = function() end
UIParent, Minimap, WorldFrame = new("UIParent"), new("Minimap"), new("WorldFrame")
UIParent.GetTop = function() return 768 end
AuctionHouseFrame = new("AuctionHouseFrame")
UISpecialFrames = {}
SlashCmdList = {}
ITEM_QUALITY_COLORS = {}
BackdropTemplateMixin = {}
GetLocale = function() return LOC end
date, time = os.date, os.time
GetTime = function() return os.clock() end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert, tremove = table.insert, table.remove
strsplit = function(sep, s)
  local out = {}
  for p in (s .. sep):gmatch("(.-)%" .. sep) do out[#out + 1] = p end
  return unpack(out)
end
C_Timer = { After = function() end, NewTicker = function() return { Cancel = function() end } end }
IsInInstance = function() return false end
InCombatLockdown = function() return false end
IsShiftKeyDown = function() return false end
IsModifiedClick = function() return false end
GetRealmName = function() return "Test" end
UnitFactionGroup = function() return "Horde" end
UnitLevel = function(u) return u == "player" and 14 or 15 end
UnitGUID = function(u) return u == "player" and "Player-1-1" or "Creature-0-0-0-0-1-0" end
UnitIsPlayer = function() return false end
UnitCanAttack = function() return true end
UnitCreatureType = function() return "Humanoid" end
GetQuestDifficultyColor = function(l)
  local d = l - 14
  if d >= 5 then return { r = 1, g = 0.1, b = 0.1 } elseif d >= 3 then return { r = 1, g = 0.5, b = 0.25 }
  elseif d >= -2 then return { r = 1, g = 1, b = 0 } end
  return { r = 0.25, g = 0.75, b = 0.25 }
end
C_Item = { GetItemInfo = function(id) return "Item" .. id, "|Hitem:" .. id .. "|h[x]|h", 1 end,
  GetItemIconByID = function() return 1 end, RequestLoadItemDataByID = function() end }
C_Map = { GetAreaInfo = function(a) return "Area" .. a end, GetMapInfo = function(id) return { name = "Zone" .. id, mapType = (id == 1414 or id == 1415) and 2 or 3 } end,
  GetMapRectOnMap = function(z, c) if (z % 2 == 0) ~= (c == 1414) then return nil end local k = (z % 7) / 10 return k, k + 0.1, k, k + 0.1 end, GetBestMapForUnit = function() return 1421 end }
BreakUpLargeNumbers = function(n)
  local s = tostring(math.floor(n))
  local sep = (LOC == "deDE" or LOC == "ptBR" or LOC == "esES" or LOC == "esMX") and "." or ","
  local r = s:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
  return (r:gsub("^%" .. sep, ""))
end
DECIMAL_SEPERATOR = (LOC == "enUS" or LOC:match("^zh") or LOC == "koKR") and "." or ","

---------------------------------------------------------------- world map mock
local acquired = {}
MapCanvasDataProviderMixin = {}
MapCanvasPinMixin = { SetPosition = function(self, x, y) self._x, self._y = x, y end,
  SetScalingLimits = function(self, ...) self._scaling = { ... } end,
  UseFrameLevelType = function(self, t) self._level = t end,
  SetMouseClickEnabled = function(self, v) self._click = v end, SetMouseMotionEnabled = function() end }
CreateFromMixins = function(...)
  local t = {}
  for _, m in ipairs({ ... }) do for k, v in pairs(m) do t[k] = v end end
  return t
end
local mapID = 1414
WorldMapFrame = new("WorldMapFrame")
WorldMapFrame.GetMapID = function() return mapID end
WorldMapFrame.AddDataProvider = function(self, p) self._provider = p; p.GetMap = function() return self end end
WorldMapFrame.RemoveAllPinsByTemplate = function() acquired = {} end
WorldMapFrame.GetPinFrameLevelsManager = function() return { definitions = { PIN_FRAME_LEVEL_MAP_LINK = {}, PIN_FRAME_LEVEL_AREA_POI = {} } } end
WorldMapFrame.AcquirePin = function(self, template, info)
  local pin = new("pin")
  for k, v in pairs(GatherScoutMapPinMixin) do pin[k] = v end
  pin.Shadow, pin.Edge, pin.Texture = new("tex"), new("tex"), new("tex")
  pin.Edge.SetColorTexture = function(t, r, g, b, a) t._rgb = { r, g, b } end
  pin.SetAlpha = function(p, a) p._alpha = a end
  pin:OnLoad()
  pin:OnAcquired(info)
  acquired[#acquired + 1] = pin
  return pin
end
function MAP_TEST(ns, plain, showTip, getTip)
  local function run(id, label)
    mapID = id
    acquired = {}
    WorldMapFrame._provider:RefreshAllData()
    local sizes, counts = {}, 0
    for _, p in ipairs(acquired) do sizes[p._w] = (sizes[p._w] or 0) + 1; if (p.Count._text or "") ~= "" then counts = counts + 1 end end
    local sz = {}
    for k, v in pairs(sizes) do sz[#sz + 1] = k .. "px x" .. v end
    print(string.format("map %s (%d): %d pins [%s], with count badge %d, level %s, clicks %s, alpha %s", label, id, #acquired,
      table.concat(sz, ", "), counts, tostring(acquired[1] and acquired[1]._level), tostring(acquired[1] and acquired[1]._click),
      tostring(acquired[1] and acquired[1]._alpha)))
    return acquired
  end
  ns.S.mapSources = 3
  local pins = run(1414, "Kalimdor, best 3")
  local best
  for _, p in ipairs(pins) do if not best or (p.info.count or 1) > (best.info.count or 1) then best = p end end
  if best then
    best:OnMouseEnter(); showTip("continent marker, " .. tostring(best.info.count) .. " items, edge rgb " ..
      table.concat(best.Edge._rgb, ","))
  end
  ns.S.mapSources = 0; run(1414, "Kalimdor, all")
  ns.S.mapSources = 1; run(1414, "Kalimdor, best only")
  ns.S.mapSources = 3
  pins = run(1421, "Silverpine zone")
  if pins[1] then pins[1]:OnMouseEnter(); showTip("zone pin") end
  local btn = GatherScoutMapToggle
  IsShiftKeyDown = function() return true end
  btn._scripts.OnClick(btn, "LeftButton"); print("after Shift+click mapSources = " .. ns.S.mapSources)
  btn._scripts.OnClick(btn, "LeftButton"); print("after Shift+click mapSources = " .. ns.S.mapSources)
  IsShiftKeyDown = function() return false end
  showTip("map button")
end

setmetatable(_G, { __index = function(_, k) unknownGlobals[k] = true return nil end })

---------------------------------------------------------------- load the addon
local ns = {}
local toc = assert(io.open(ADDON .. "/GatherScout.toc")):read("*a")
local loaded = {}
for line in toc:gmatch("[^\r\n]+") do
  if not line:match("^##") and line:match("%.lua$") then
    local path = ADDON .. "/" .. line:gsub("\\", "/")
    local f = io.open(path, "rb")
    if f then
      local src = f:read("*a"); f:close()
      local chunk, err = loadstring(src, line)
      assert(chunk, err)
      chunk("GatherScout", ns)
      loaded[#loaded + 1] = line
    end
  end
end
print("loaded " .. #loaded .. " files, locale " .. LOC .. ", L sample: " .. ns.L["Where to farm (best for you on top)"])

local function fire(event, ...) ns.frame._scripts.OnEvent(ns.frame, event, ...) end
ns.debug = true
fire("ADDON_LOADED", "GatherScout")
fire("PLAYER_LOGIN")
ns.S.showDangerous = true
ns.S.minQty = 0
ns.db.market[ns.RealmKey()] = { lastScan = os.time() - 600, scanned = 3, items = {
  [5784] = { p = 360, q = 2288, min = 337, t = os.time() - 600, h = {} },
  [2589] = { p = 120, q = 12345, min = 100, t = os.time() - 600, h = {} },
  [765] = { p = 50, q = 500, min = 40, t = os.time() - 600, h = {} } } }

local function plain(s) return (tostring(s or "")):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "[i]") end
local function showTip(title) print("  tooltip " .. title .. ":") for _, l in ipairs(tt) do print("    " .. plain(l)) end end

ns.UI_Toggle()
ns.UI_Refresh()
for _, id in ipairs({5784, 2589, 765, 2318, 774}) do ns.mapSel[id] = true end
local frame = GatherScoutFrame
print("window shown, list count text: " .. plain(frame.count._text))
-- layout of the window rows (W = 990): right edges must stay inside, neighbours must not overlap
do
  local rows = {}
  for _, o in ipairs(created) do
    if o._parent == frame and o._pt and (o._kind == "CheckButton" or o._template == "UIPanelButtonTemplate") then
      local pt, x, y = o._pt[1], o._pt[4], o._pt[5]
      if type(x) == "number" and (pt == "TOPLEFT" or pt == "BOTTOMLEFT") then
        local key = pt .. " y=" .. tostring(y)
        local w = o._kind == "CheckButton" and (o.width or 0) or o._w
        rows[key] = math.max(rows[key] or 0, x + w)
      end
    end
  end
  local out = {}
  for k, v in pairs(rows) do out[#out + 1] = string.format("%s right=%d%s", k, v, v > 978 and " OVERFLOW" or "") end
  table.sort(out)
  print("layout: " .. table.concat(out, " | "))
  local sp = frame.spinners
  local function label(f) for _, c in ipairs(created) do if c._parent == f and c._kind == "fs" then return c end end end
  local s1 = 14 + vwidth(label(sp[1])._text) + 52
  local s2 = 220 + vwidth(label(sp[2])._text) + 52
  local s3 = 420 + vwidth(label(sp[3])._text) + 10 + 54 + 52
  local fb -- the full scan button, bottom right
  for _, o in ipairs(created) do
    if o._parent == frame and o._template == "UIPanelButtonTemplate" and o._pt and o._pt[1] == "BOTTOMRIGHT" then fb = o end
  end
  local left = 990 - 14 - fb._w
  print(string.format("bottom: spinner1 ends %d (<220)%s, spinner2 ends %d (<420)%s, min-qty box ends %d, scan button starts %d%s",
    s1, s1 >= 216 and " OVERLAP" or "", s2, s2 >= 416 and " OVERLAP" or "", s3, left, s3 >= left - 4 and " OVERLAP" or ""))
  local hdr = {}
  for _, c in ipairs(created) do
    if c._kind == "fs" and c._parent and c._parent._kind == "Button" and c._parent._w and c._parent._w > 0 and c._parent._parent
      and c._parent._parent._parent == frame and c._text ~= "" and vwidth(c._text) > c._parent._w then
      hdr[#hdr + 1] = plain(c._text) .. " (" .. math.floor(vwidth(c._text)) .. ">" .. c._parent._w .. ")"
    end
  end
  print("column headers too wide: " .. (#hdr > 0 and table.concat(hdr, ", ") or "none"))
end
ns.Card_Show(5784)
local card = ns.card
print("card title: " .. plain(card.title._text) .. " | sub: " .. plain(card.sub._text))
print("card stats: " .. plain(card.stats._text):gsub("\n", " / "))
print("card summary: " .. plain(card.summary._text):gsub("\n", " / "))
print("where title: " .. plain(card.whereTitle._text) .. "   hint: " .. plain(card.whereHint._text))
for _, r in ipairs(card.srcRows) do
  if r._shown then
    print(string.format("  row: %-10s| %-34s| %-6s| %-7s| %s", plain(r.diff._text), plain(r.name._text), plain(r.lv._text),
      plain(r.ch._text), plain(r.zone._text)))
  end
end
for _, r in ipairs(card.srcRows) do
  if r._shown and r.head then r._scripts.OnEnter(r); showTip("source"); break end
end
-- buttons
print("card buttons: [" .. plain(card.pinBtn._text) .. "] w=" .. card.pinBtn._w .. "  [" .. plain(card.mapBtn._text) .. "] w=" .. card.mapBtn._w
  .. "  title width " .. card.title._w)
-- AH buttons
fire("AUCTION_HOUSE_SHOW")
local b, o = GatherScoutAHButton, GatherScoutAHOpenButton
print("AH buttons: [" .. plain(o._text) .. "] w=" .. o._w .. "  [" .. plain(b._text) .. "] w=" .. b._w)
b._scripts.OnEnter(b); showTip("AH scan button")
-- unit + node tooltips
ns.AddUnitLines(GameTooltip, "mouseover", true); showTip("mob")
local nodeName = ns.GEN.nodeL and next(ns.GEN.nodeL) or "Silverleaf"
tt = {}
local okNode = ns.AddNodeLines(GameTooltip, nodeName)
print("node tooltip for " .. tostring(nodeName) .. ": " .. tostring(okNode)); showTip("node")
-- fishing schools: map and card show the name the game shows, and that name gets the tooltip lines
do
  local pools = {}
  for pool in pairs(ns.GEN.fishPools or {}) do pools[#pools + 1] = pool end
  table.sort(pools)
  for _, pool in ipairs(pools) do
    local label = ns.SchoolLabel(pool)
    tt = {}
    local ok = ns.AddNodeLines(GameTooltip, label)
    print(string.format("school %s: %s -> tooltip %s (%d lines)", pool, plain(label), tostring(ok), #tt))
    if not ok then error("no tooltip for the school " .. pool .. " shown as " .. label) end
    if LOC ~= "enUS" and label == pool then error("no " .. LOC .. " name for the school " .. pool) end
  end
end
-- slash help + list row tooltip
SlashCmdList.GATHERSCOUT("help")
SlashCmdList.GATHERSCOUT("demand")
print("money: " .. plain(ns.Money(123456789)) .. "   chance: " .. plain(ns.ChanceText(1.5, "db")) .. "   npc 3: " .. ns.NpcName(3))
MAP_TEST(ns, plain, showTip)
local missing = {}
for k in pairs(unknownGlobals) do missing[#missing + 1] = k end
table.sort(missing)
print("globals read but not mocked: " .. table.concat(missing, ", "))
