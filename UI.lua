-- GatherScout UI: the "what to farm" list, the item card (21-day chart, sources, chances), the minimap button.
local _, ns = ...

local floor, max, min = math.floor, math.max, math.min
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
local L, LP = ns.L, ns.LP

local W, H = 990, 590
local ROWS, ROWH = 16, 22
local frame, rows, infoText, statusText, scrollThumb, emptyText, searchBox
local checks = {}
local offset = 0
local view = {}
local selectedId
local search = ""

local COLS = {
  { key = "pin",    title = "",            w = 20,  justify = "CENTER" },
  { key = "name",   title = L["Item"],       w = 190, justify = "LEFT" },
  { key = "price",  title = L["Price"],      w = 106, justify = "RIGHT" },
  { key = "qty",    title = L["On AH"],      w = 60,  justify = "RIGHT" },
  { key = "F",      title = L["Demand"],     w = 90,  justify = "CENTER" },
  { key = "diff",   title = L["Difficulty"], w = 70,  justify = "CENTER" },
  { key = "where",  title = L["Best place (for you)"], w = 222, justify = "LEFT" },
  { key = "chance", title = L["Chance"],     w = 54,  justify = "CENTER" },
  { key = "score",  title = L["~income/h"],  w = 96,  justify = "RIGHT" },
}

local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8X8",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = false, edgeSize = 14,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function styleWindow(f)
  if f.SetBackdrop then
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0.06, 0.06, 0.08, 0.97)
    f:SetBackdropBorderColor(0.5, 0.5, 0.55, 1)
  end
end

---------------------------------------------------------------- helpers
-- Mob name in the client's language (Data/Names/<locale>.lua, from QuestieDB by NPC ID), else English
function ns.NpcName(npcID)
  local n = ns.GEN.npcs[npcID]
  if not n then return "?" end
  local loc = ns.GEN.npcL and ns.GEN.npcL[npcID]
  return loc or n[6] or "?"
end

-- guess = the mob has no level in the data and you have not seen it yet: the zone's levels, marked "~"
local function rangeText(lo, hi, eff, guess)
  if not lo then return "" end
  local col = ns.LevelColor(eff or lo)
  local pre = guess and "|cff909090~|r" or ""
  if hi and hi ~= lo then return string.format("%s%s%d–%d|r", pre, col, lo, hi) end
  return string.format("%s%s%d|r", pre, col, lo)
end

ns.ENEMY_COLOR = "|cffff9a50" -- same orange as the warnings

-- Fishing school by the name the game shows (Data/Names/<locale>.lua; the English key on English clients).
-- A school without a translated name is shown by its main catch, whose name the client gives in its own language.
local schoolItem
function ns.SchoolLabel(pool)
  local name = ns.GEN.poolL and ns.GEN.poolL[pool]
  if name then return name end
  if ns.LOCALE == "enUS" then return pool end
  if not schoolItem then
    schoolItem = {}
    local best = {}
    for id, f in pairs(ns.GEN.fish or {}) do
      for _, per in pairs(f.p or {}) do
        for name, p in pairs(per) do
          if not best[name] or p > best[name] then best[name], schoolItem[name] = p, id end
        end
      end
    end
  end
  local id = schoolItem[pool]
  local item = id and (ns.ItemName(id) or string.format(L["item %d"], id))
  return string.format(L["School: %s"], item or pool)
end

-- Where on the water: a school, a sub-zone (coast, lake) or the whole zone
function ns.FishSpot(src)
  if src.pool then return ns.SchoolLabel(src.pool) end
  return string.format(L["Fishing: %s"], src.area and ns.AreaName(src.area) or L["open water"])
end

-- One-line description of a source, no glyphs the game font lacks
function ns.WhereText(src, itemID)
  if not src then return "|cff808080" .. L["no suitable places"] .. "|r" end
  local zone = ns.MapName(src.map)
  local lv = rangeText(src.lo, src.hi, src.eff, src.lvGuess)
  local zc = src.enemy and ns.ENEMY_COLOR or "|cffa0a0a0" -- enemy faction territory: zone in orange
  local text
  if src.kind == "fish" then
    text = string.format("%s %s %s(%s)|r", ns.FishSpot(src), lv, zc, zone)
  elseif src.kind == "npc" then
    text = string.format("%s %s %s(%s)|r", ns.NpcName(src.npcs[1]), lv, zc, zone)
  elseif src.kind == "rule" then
    text = string.format("%s %s %s(%s)|r", src.ct == "beast" and L["Beasts"] or L["Humanoids"], lv, zc, zone)
  elseif src.kind == "world" then
    text = string.format("%s %s %s(%s)|r", L["Mobs"], lv, zc, zone)
  else
    if src.enemy then zone = zc .. zone .. "|r" end
    text = string.format("%s %s%s", zone, lv, (src.learned or src.guess) and " |cff909090?|r" or "")
  end
  return text
end

local function pct(x)
  if not x then return "—" end
  local v = floor((x - 1) * 100 + 0.5)
  if v > 0 then return "|cff40ff40+" .. v .. "%|r" elseif v < 0 then return "|cffff6060" .. v .. "%|r" end
  return "0%"
end

local function ago(t)
  if not t or t == 0 then return nil end
  local m = floor((time() - t) / 60)
  if m < 60 then return string.format(L["%d min ago"], m) end
  if m < 48 * 60 then return string.format(L["%d h ago"], floor(m / 60)) end
  return string.format(L["%d d ago"], floor(m / 1440))
end

-- Price trend next to a price: the cheapest auction now vs. its usual price (7 days), when it moved 10%+
local function trendText(dem)
  if dem and dem.refP and dem.trend and (dem.trend >= 1.1 or dem.trend <= 0.9) then return " " .. pct(dem.trend) end
  return ""
end

-- "market price" (with its trend) plus the lowest price when someone is clearly undercutting below the market
local function priceText(row, size)
  if not row.price then return nil end
  local txt = ns.Money(row.price, size) .. trendText(row.dem)
  if row.minP and row.minP < row.price * 0.9 then
    txt = txt .. "  |cff909090" .. string.format(L["min. %s"], ns.Money(row.minP, size)) .. "|r"
  end
  return txt
end

-- gathering places (herbs, ore) have no drop chance; everything else that has none shows "??"
local function chanceOf(row)
  if not row.chance or row.chanceGuess then
    return (row.best and row.best.kind ~= "zone") and ns.UNKNOWN_CHANCE or nil
  end
  return ns.ChanceText(row.chance, row.best and row.best.chanceSrc, row.best and row.best.corpses)
    .. (row.chanceGuess and (" |cff909090(" .. L["estimate"] .. ")|r") or "")
end

---------------------------------------------------------------- compact hover tooltip (left of the window)
function ns.ShowItemDetails(owner, data)
  local tt = GameTooltip
  tt:SetOwner(owner, "ANCHOR_NONE")
  tt:ClearAllPoints()
  tt:SetPoint("TOPRIGHT", frame, "TOPLEFT", -6, -40)
  tt:SetItemByID(data.id)
  tt:AddLine(" ")
  tt:AddDoubleLine(L["Price (market)"], priceText(data) or ("|cff909090" .. L["no data"] .. "|r"), 1, 0.82, 0)
  tt:AddDoubleLine(L["Demand"], data.dem.label, 1, 0.82, 0)
  if data.best then
    tt:AddDoubleLine(L["Difficulty"], (ns.DiffLabel(data.best.mult)), 1, 0.82, 0)
    tt:AddDoubleLine(L["Where"], ns.WhereText(data.best, data.id), 1, 0.82, 0)
  end
  local ch = chanceOf(data)
  if ch then tt:AddDoubleLine(L["Chance"], ch, 1, 0.82, 0) end
  if data.gph then tt:AddDoubleLine(L["~Income"], string.format(L["%s /h"], ns.Money(data.gph)), 1, 0.82, 0) end
  tt:AddLine(" ")
  tt:AddLine(L["Left-click: item card with chart, where to farm, map"], 0.6, 0.6, 0.6)
  tt:AddLine(L["Right-click: pin    Shift+left-click: link in chat"], 0.6, 0.6, 0.6)
  tt:Show()
end

---------------------------------------------------------------- list data
local function sortValue(row, key)
  if key == "name" then return ns.ItemName(row.id) or "" end
  if key == "price" then return row.price or -1 end
  if key == "qty" then return row.qty or -1 end
  if key == "F" then return row.F or 0 end
  if key == "diff" then return row.best and -row.best.mult or -999 end
  if key == "where" then return row.best and ns.MapName(row.best.map) or "\255" end -- no place: sorts last
  if key == "chance" then return (row.chance and not row.chanceGuess) and row.chance or -1 end
  return row.score or (row.best and -1 or -2)
end

local function buildView()
  local res = ns.Compute()
  local S = ns.S
  wipe(view)
  local q = search ~= "" and ns.Lower(search) or nil
  for _, row in ipairs(res) do
    if (row.best or S.showDangerous) and (ns.Liquid(row) or ns.db.pins[row.id]) then
      if not q or ns.Lower(ns.ItemName(row.id) or ""):find(q, 1, true) then view[#view + 1] = row end
    end
  end
  local key, desc = S.sortKey, S.sortDesc
  table.sort(view, function(a, b)
    local va, vb = sortValue(a, key), sortValue(b, key)
    if va == vb then return a.id < b.id end
    if desc then return va > vb end
    return va < vb
  end)
end

---------------------------------------------------------------- list drawing
local function drawRows()
  if not frame or not frame:IsShown() then return end
  local maxOffset = max(0, #view - ROWS)
  if offset > maxOffset then offset = maxOffset end
  local pins = ns.db.pins
  for i = 1, ROWS do
    local r = rows[i]
    local data = view[i + offset]
    r.data = data
    if not data then
      r:Hide()
    else
      r:Show()
      local id = data.id
      local name = ns.ItemName(id) or string.format(L["item %d"], id)
      local q = ns.ItemQuality(id)
      local color = (q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] and ITEM_QUALITY_COLORS[q].hex) or "|cffffffff"
      r.icon:SetTexture(ns.ItemIcon(id))
      r.cols.name:SetText(color .. name .. "|r" .. (data.m.guess and " |cff909090*|r" or ""))
      local ptxt = data.price and (ns.Money(data.price) .. trendText(data.dem)) or "|cff808080—|r"
      r.cols.price:SetText(ptxt)
      if data.qty == nil then
        r.cols.qty:SetText("|cff808080—|r")
      elseif data.qty == 0 then
        r.cols.qty:SetText("|cffff40400|r")
      else
        r.cols.qty:SetText(ns.Num(data.qty))
      end
      local icon = ns.DemandIcon(data.dem, 12)
      r.cols.F:SetText(icon ~= "" and (icon .. " " .. data.dem.label) or data.dem.label)
      r.cols.diff:SetText((ns.DiffLabel(data.best and data.best.mult)))
      r.cols.where:SetText(ns.WhereText(data.best, id))
      if data.chance and not data.chanceGuess and data.best then
        r.cols.chance:SetText(ns.ChanceText(data.chance, data.best.chanceSrc))
      elseif data.best and data.best.kind ~= "zone" then
        r.cols.chance:SetText(ns.UNKNOWN_CHANCE) -- a drop with no known chance
      else
        r.cols.chance:SetText("|cff808080-|r") -- gathered, or nowhere to get it
      end
      r.cols.score:SetText(data.gph and ns.Money(data.gph) or "|cff808080—|r")
      r.pin.tex:SetDesaturated(not pins[id])
      r.pin.tex:SetAlpha(pins[id] and 1 or 0.3)
      r.sel:SetShown(selectedId == id)
      r.mapMark:SetShown(ns.mapSel[id] == true)
      r:SetAlpha(data.best and 1 or 0.55)
    end
  end
  local track = scrollThumb:GetParent()
  if #view > ROWS then
    local th = max(20, track:GetHeight() * ROWS / #view)
    scrollThumb:SetHeight(th)
    local pos = (track:GetHeight() - th) * (offset / max(1, #view - ROWS))
    scrollThumb:ClearAllPoints()
    scrollThumb:SetPoint("TOP", track, "TOP", 0, -pos)
    scrollThumb:Show()
  else
    scrollThumb:Hide()
  end
  emptyText:SetShown(#view == 0)
  frame.count:SetText(#view > 0 and LP("%d items", #view) or "")
end

local function refreshInfo()
  local ctx = ns.Context()
  local parts = { string.format(L["Level %s"], "|cffffffff" .. ctx.level .. "|r") }
  for _, k in ipairs({ "herb", "mine", "skin", "fish" }) do
    local v = ctx.profs[k]
    parts[#parts + 1] = ns.PROF_LABEL[k] .. " " .. (v and ("|cffffffff" .. v .. "|r") or "|cff808080—|r")
  end
  local m = ns.Market()
  local a = ago(m.lastScan)
  if a then
    local stale = (time() - m.lastScan) > 86400
    parts[#parts + 1] = (stale and "|cffff8040" or "|cff40ff40") .. string.format(L["auction house: %s"], a) .. "|r"
  else
    parts[#parts + 1] = "|cffff8040" .. L["no auction data, open the auction house"] .. "|r"
  end
  infoText:SetText(table.concat(parts, "      "))
  for _, cb in ipairs(checks) do cb:SetChecked(cb.get()) end
  for _, sp in ipairs(frame.spinners) do sp.update() end
  frame.npPosBtn.update()
  frame.demBtn.update()
end

function ns.UI_Refresh()
  if not frame or not frame:IsShown() then return end
  buildView()
  refreshInfo()
  drawRows()
  if ns.Card_Refresh then ns.Card_Refresh() end
end

function ns.UI_Status(text)
  if statusText then statusText:SetText(text or "") end
end

---------------------------------------------------------------- widgets
local function tooltipFor(widget, title, text)
  widget:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(title)
    if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  widget:SetScript("OnLeave", GameTooltip_Hide)
end

local function makeCheck(parent, label, tip, get, set)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(22, 22)
  local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", cb, "RIGHT", 0, 1)
  fs:SetText(label)
  cb.get = get
  cb:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    ns.Invalidate()
  end)
  if tip then tooltipFor(cb, label, tip) end
  cb.width = 26 + fs:GetStringWidth()
  checks[#checks + 1] = cb
  return cb
end

local function layoutRow(parent, items, x, y)
  for _, cb in ipairs(items) do
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    x = x + cb.width + 10
  end
  return x
end

-- Widen a button to its label (never below its design width): longer languages are not cut off
local function fitButton(b)
  local fs = b:GetFontString()
  local tw = fs and fs:GetStringWidth() or 0
  b:SetWidth(max(b.minW or 0, math.ceil(tw) + 24))
end

local function makeButton(parent, text, w, onClick, tipTitle, tip)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  b.minW = w
  if w >= 60 then fitButton(b) end
  b:SetScript("OnClick", onClick)
  if tipTitle then tooltipFor(b, tipTitle, tip) end
  return b
end

local function makeSpinner(parent, label, tip, get, set, lo, hi)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(180, 22)
  local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT")
  local minus = makeButton(f, "-", 22, function() set(max(lo, get() - 1)); f.update(); ns.Invalidate() end)
  local plus = makeButton(f, "+", 22, function() set(min(hi, get() + 1)); f.update(); ns.Invalidate() end)
  minus:SetHeight(20)
  plus:SetHeight(20)
  f.update = function()
    fs:SetText(label .. ": |cffffffff" .. get() .. "|r")
    minus:ClearAllPoints()
    minus:SetPoint("LEFT", fs, "RIGHT", 6, 0)
    plus:ClearAllPoints()
    plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
  end
  f:EnableMouse(true)
  tooltipFor(f, label, tip)
  f.update()
  return f
end

-- Number field with -/+ buttons; typing works too. Shift+click steps x10.
local function makeNumberBox(parent, label, tip, get, set, lo, hi, step)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(250, 22)
  local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT")
  fs:SetText(label .. ":")
  local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  eb:SetSize(54, 20)
  eb:SetAutoFocus(false)
  eb:SetNumeric(true)
  eb:SetMaxLetters(6)
  eb:SetJustifyH("CENTER")
  eb:SetPoint("LEFT", fs, "RIGHT", 10, 0)
  local function apply(v)
    v = math.floor(max(lo, min(hi, tonumber(v) or get())))
    if v ~= get() then
      set(v)
      ns.Invalidate()
    end
    eb:SetText(tostring(v))
  end
  eb:SetScript("OnEnterPressed", function(self) apply(self:GetText()); self:ClearFocus() end)
  eb:SetScript("OnEditFocusLost", function(self) apply(self:GetText()) end)
  eb:SetScript("OnEscapePressed", function(self) self:SetText(tostring(get())); self:ClearFocus() end)
  local function stepBy(dir)
    local s = IsShiftKeyDown() and step * 10 or step
    apply(get() + dir * s)
  end
  local minus = makeButton(f, "-", 22, function() stepBy(-1) end)
  local plus = makeButton(f, "+", 22, function() stepBy(1) end)
  minus:SetHeight(20)
  plus:SetHeight(20)
  minus:SetPoint("LEFT", eb, "RIGHT", 4, 0)
  plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
  f.update = function()
    if not (eb.HasFocus and eb:HasFocus()) then eb:SetText(tostring(get())) end
  end
  f:EnableMouse(true)
  tooltipFor(f, label, tip)
  f.update()
  return f
end

---------------------------------------------------------------- main frame
local NP_POS = { right = L["right"], top = L["top"], left = L["left"] }
local NP_NEXT = { right = "top", top = "left", left = "right" }

local function createFrame()
  frame = CreateFrame("Frame", "GatherScoutFrame", UIParent, BACKDROP_TEMPLATE)
  frame:SetSize(W, H)
  frame:SetPoint("CENTER", -120, 0)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  styleWindow(frame)
  frame:Hide()
  tinsert(UISpecialFrames, "GatherScoutFrame")
  frame:SetScript("OnShow", function() ns.Invalidate(); ns.UI_Refresh() end)
  frame:SetScript("OnHide", function() if ns.card then ns.card:Hide() end end)

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("GatherScout |cffa0a0a0— " .. L["what is worth farming now"] .. "|r")

  -- search
  searchBox = CreateFrame("EditBox", "GatherScoutSearch", frame, "InputBoxTemplate")
  searchBox:SetSize(190, 20)
  searchBox:SetPoint("TOPRIGHT", -40, -12)
  searchBox:SetAutoFocus(false)
  local hint = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("LEFT", 4, 0)
  hint:SetText(L["Search by name…"])
  searchBox:SetScript("OnTextChanged", function(self)
    search = self:GetText() or ""
    hint:SetShown(search == "")
    offset = 0
    ns.UI_Refresh()
  end)
  searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
  searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

  infoText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  infoText:SetPoint("TOPLEFT", 14, -36)
  infoText:SetJustifyH("LEFT")

  -- category filters
  local order = {}
  for key in pairs(ns.CATS) do order[#order + 1] = key end
  table.sort(order, function(a, b) return ns.CATS[a].order < ns.CATS[b].order end)
  local cats = {}
  for _, key in ipairs(order) do
    local c = ns.CATS[key]
    cats[#cats + 1] = makeCheck(frame, c.label, c.tip, function() return ns.S.cats[key] end,
      function(v) ns.S.cats[key] = v end)
  end
  layoutRow(frame, cats, 12, -54)

  local opts = {
    makeCheck(frame, L["Only my professions"],
      L["Show only what your professions can gather (cloth and drops always)."],
      function() return ns.S.onlyMyProfs end, function(v) ns.S.onlyMyProfs = v end),
    makeCheck(frame, L["Show dangerous and unavailable"],
      L["Show zones far above your level and things your skill is not high enough for yet."],
      function() return ns.S.showDangerous end, function(v) ns.S.showDangerous = v end),
    makeCheck(frame, L["Mark all mobs with drops"],
      L["An icon on every mob that drops something tracked, not only items from the top of the list."],
      function() return ns.S.markAll end, function(v) ns.S.markAll = v end),
    makeCheck(frame, L["Pinned on the map"],
      L["Show pinned items on the world map: points in the zone and zone markers on the continent map."],
      function() return ns.S.mapPinned end, function(v) ns.S.mapPinned = v; ns.Map_Refresh() end),
  }
  local optsEnd = layoutRow(frame, opts, 12, -78)
  local DEM_MODE = { icon = L["icon"], text = L["text"], off = L["hidden"] }
  local DEM_NEXT = { icon = "text", text = "off", off = "icon" }
  local demBtn = makeButton(frame, "", 200, function()
    ns.S.tipDemand = DEM_NEXT[ns.S.tipDemand] or "icon"
    frame.demBtn.update()
  end, L["Demand in tooltips"],
    L["How to show demand in the tooltip of a mob and of an herb or ore node: a colored dot, a word, or not at all."])
  demBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", optsEnd, -79)
  demBtn.update = function()
    demBtn:SetText(string.format(L["Demand in tooltips: %s"], DEM_MODE[ns.S.tipDemand] or DEM_MODE.icon))
    fitButton(demBtn)
  end
  frame.demBtn = demBtn

  -- header
  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT", 12, -104)
  header:SetSize(W - 40, 20)
  local x = 0
  for _, col in ipairs(COLS) do
    local b = CreateFrame("Button", nil, header)
    b:SetPoint("LEFT", x, 0)
    b:SetSize(col.w, 20)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints()
    fs:SetJustifyH(col.justify)
    fs:SetWordWrap(false)
    fs:SetText(col.title)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    if col.key == "F" then
      tooltipFor(b, L["Auction house demand"],
        ns.DemandIcon({ level = "high" }) .. " " .. L["high: what is on the AH sells out within about a day"] .. "\n"
        .. ns.DemandIcon({ level = "mid" }) .. " " .. L["average: it lasts 1–3 days"] .. "\n"
        .. ns.DemandIcon({ level = "low" }) .. " " .. L["low: enough for more than 3 days, it sells slowly"] .. "\n"
        .. ns.DemandIcon({ level = "empty" }) .. "|cff40ff40!|r " .. L["not a single auction"] .. "\n"
        .. "|cff909090" .. L["few scans"] .. "|r — " .. L["the sales speed is not measured yet, scan again in a few hours"] .. "\n\n"
        .. L["How many days the units on the AH last at the speed they leave between your scans (sales, but also cancelled and expired auctions, so it is an upper estimate), adjusted for the supply vs. usual (7 days) and the price trend. Click to sort."])
    end
    if col.key == "price" then
      tooltipFor(b, L["Market price"],
        L["The price at which most of the cheap auctions really sit: the cheap part of the market (15–30% of all units) is taken and outliers are dropped from it, e.g. a few dozen units dumped in front of thousands at the normal price. The lowest price is shown in the row tooltip and in the card if it is noticeably lower. Click to sort."]
        .. "\n\n" .. L["+N% / -N%: the cheapest auction now vs. its usual price over 7 days."])
    elseif col.key == "diff" then
      tooltipFor(b, L["Difficulty for you"],
        L["How hard it is for you in particular: the mob level at the best place vs. yours (trivial: you kill everything there, medium: a zone of your level, dangerous: the mobs are higher), elite mobs, enemy faction, missing skill, few nodes. Click to sort."])
    elseif col.key == "where" then
      tooltipFor(b, L["Best place (for you)"],
        L["The best place for your level: a zone with its levels, a specific mob or “beasts/humanoids N–M”. Click to sort by zone."])
    elseif col.key == "chance" then
      tooltipFor(b, L["Drop chance"],
        L["Chance to get the item from one mob at the best place. The color shows the source:"] .. "\n"
        .. ns.CHANCE_COLOR.db .. L["white"] .. "|r — " .. L["player statistics"] .. "\n"
        .. ns.CHANCE_COLOR.classic .. L["light blue"] .. "|r — " .. L["patch 1.12 loot tables"] .. "\n"
        .. ns.CHANCE_COLOR.learned .. L["green"] .. "|r — " .. L["from your kills (20+ corpses of this mob)"] .. "\n"
        .. L["?? means the drop chance is unknown; a dash means it is gathered (herbs, ore). Click to sort."])
    elseif col.key == "score" then
      tooltipFor(b, L["Approximate income per hour"],
        L["Price x how much you get per hour x demand / difficulty. A rough estimate to compare rows with each other, not an exact sum. The list is sorted by it by default. Click to sort."])
    end
    if col.key ~= "pin" then
      b:SetScript("OnClick", function()
        if ns.S.sortKey == col.key then
          ns.S.sortDesc = not ns.S.sortDesc
        else
          ns.S.sortKey = col.key
          ns.S.sortDesc = (col.key ~= "name" and col.key ~= "where")
        end
        ns.UI_Refresh()
      end)
    end
    x = x + col.w + 4
  end
  local line = header:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 1, 1, 0.15)
  line:SetPoint("BOTTOMLEFT", 0, -2)
  line:SetPoint("BOTTOMRIGHT", 0, -2)

  -- rows
  local list = CreateFrame("Frame", nil, frame)
  list:SetPoint("TOPLEFT", 12, -128)
  list:SetSize(W - 40, ROWS * ROWH)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    offset = max(0, min(max(0, #view - ROWS), offset - delta * 3))
    drawRows()
  end)
  rows = {}
  for i = 1, ROWS do
    local r = CreateFrame("Button", nil, list)
    r:SetSize(W - 40, ROWH)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROWH)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    if i % 2 == 0 then
      local bg = r:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints()
      bg:SetColorTexture(1, 1, 1, 0.035)
    end
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints()
    r.sel:SetColorTexture(0.3, 0.6, 1, 0.2)
    r.sel:Hide()
    r.cols = {}
    local cx = 0
    for _, col in ipairs(COLS) do
      if col.key == "pin" then
        local pin = CreateFrame("Button", nil, r)
        pin:SetSize(16, 16)
        pin:SetPoint("LEFT", cx + 2, 0)
        pin.tex = pin:CreateTexture(nil, "ARTWORK")
        pin.tex:SetAllPoints()
        pin.tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
        pin:SetScript("OnClick", function()
          local d = r.data
          if not d then return end
          ns.db.pins[d.id] = (not ns.db.pins[d.id]) or nil
          ns.Invalidate()
          ns.Map_Refresh()
        end)
        tooltipFor(pin, L["Pin"], L["Pinned items are always marked on mobs and shown on the map."])
        r.pin = pin
      elseif col.key == "name" then
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(18, 18)
        r.icon:SetPoint("LEFT", cx, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.mapMark = r:CreateTexture(nil, "OVERLAY")
        r.mapMark:SetSize(12, 12)
        r.mapMark:SetPoint("BOTTOMRIGHT", r.icon, "BOTTOMRIGHT", 4, -3)
        r.mapMark:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
        r.mapMark:Hide()
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", cx + 22, 0)
        fs:SetSize(col.w - 22, ROWH)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        r.cols.name = fs
      else
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", cx, 0)
        fs:SetSize(col.w, ROWH)
        fs:SetJustifyH(col.justify)
        fs:SetWordWrap(false)
        r.cols[col.key] = fs
      end
      cx = cx + col.w + 4
    end
    r:SetScript("OnEnter", function(self) if self.data then ns.ShowItemDetails(self, self.data) end end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    r:SetScript("OnClick", function(self, mouse)
      local d = self.data
      if not d then return end
      if IsModifiedClick("CHATLINK") then
        local link = ns.ItemLink(d.id)
        if link then ChatEdit_InsertLink(link) end
        return
      end
      if mouse == "RightButton" then
        ns.db.pins[d.id] = (not ns.db.pins[d.id]) or nil
        ns.Invalidate()
        ns.Map_Refresh()
        return
      end
      if selectedId == d.id and ns.card and ns.card:IsShown() then
        selectedId = nil
        ns.card:Hide()
      else
        selectedId = d.id
        ns.Card_Show(d.id)
      end
      drawRows()
    end)
    rows[i] = r
  end

  -- scroll indicator (click the track to jump)
  local track = CreateFrame("Button", nil, frame)
  track:SetPoint("TOPRIGHT", -10, -128)
  track:SetSize(8, ROWS * ROWH)
  local tbg = track:CreateTexture(nil, "BACKGROUND")
  tbg:SetAllPoints()
  tbg:SetColorTexture(1, 1, 1, 0.06)
  scrollThumb = track:CreateTexture(nil, "ARTWORK")
  scrollThumb:SetWidth(8)
  scrollThumb:SetColorTexture(0.5, 0.8, 1, 0.55)
  track:SetScript("OnClick", function(self)
    local _, cy = GetCursorPosition()
    local scale = self:GetEffectiveScale()
    local top = self:GetTop() or 0
    local frac = max(0, min(1, (top - cy / scale) / max(1, self:GetHeight())))
    offset = floor(frac * max(0, #view - ROWS) + 0.5)
    drawRows()
  end)

  frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.count:SetPoint("TOPRIGHT", track, "BOTTOMRIGHT", 0, -2)

  emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
  emptyText:SetPoint("TOP", list, "TOP", 0, -80)
  emptyText:SetWidth(W - 160)
  emptyText:SetText(string.format(L["Nothing found. Check the search, the categories and “%s”, or turn on “%s”. Mob drops appear after an auction scan."],
    L["Only my professions"], L["Show dangerous and unavailable"]))

  -- bottom: mob marking switches
  local sep = frame:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(1, 1, 1, 0.12)
  sep:SetPoint("BOTTOMLEFT", 12, 66)
  sep:SetPoint("BOTTOMRIGHT", -12, 66)

  local mob = {
    makeCheck(frame, L["Mob markers"],
      L["Main switch: icons on nameplates, next to the target portrait and lines in the tooltip. Also /gs on and /gs off."],
      function() return ns.S.enabled end, function(v) ns.S.enabled = v end),
    makeCheck(frame, L["Nameplates"], L["Item icon next to the health bar above the mob."],
      function() return ns.S.nameplates end, function(v) ns.S.nameplates = v end),
    makeCheck(frame, L["At target portrait"], L["Icon next to the target frame; hover it to see what drops."],
      function() return ns.S.targetIcon end, function(v) ns.S.targetIcon = v end),
    makeCheck(frame, L["Mob tooltip"], L["Lines with drops, chance, price and demand when you hover a mob."],
      function() return ns.S.tooltips end, function(v) ns.S.tooltips = v end),
    makeCheck(frame, L["Auto-scan at the AH"],
      L["Scan the auction house when it opens (at most every 30 minutes)."],
      function() return ns.S.autoScan end, function(v) ns.S.autoScan = v end),
    makeCheck(frame, L["Minimap button"], nil,
      function() return not ns.S.minimap.hide end,
      function(v) ns.S.minimap.hide = not v; if ns.Minimap_Update then ns.Minimap_Update() end end),
  }
  local bx = 12
  for _, cb in ipairs(mob) do
    cb:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", bx, 38)
    bx = bx + cb.width + 10
  end
  local npBtn = makeButton(frame, "", 150, function()
    ns.S.npPos = NP_NEXT[ns.S.npPos] or "right"
    frame.npPosBtn.update()
    ns.Mobs_RefreshAll()
  end, L["Nameplate icon"], L["Where to draw the icon by the health bar. Quest addons often put their own icon on the left."])
  npBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", bx, 38)
  npBtn.update = function()
    npBtn:SetText(string.format(L["Icon: %s"], NP_POS[ns.S.npPos] or NP_POS.right))
    fitButton(npBtn)
  end
  frame.npPosBtn = npBtn

  frame.spinners = {
    makeSpinner(frame, L["Levels above me"],
      L["How far above your level zones and mobs in the hints may be. Less is safer."],
      function() return ns.S.maxAbove end, function(v) ns.S.maxAbove = v end, 0, 15),
    makeSpinner(frame, L["Mark top"],
      L["How many of the best list entries count as “hot”: their mobs get an icon."],
      function() return ns.S.topN end, function(v) ns.S.topN = v end, 1, 60),
  }
  frame.spinners[3] = makeNumberBox(frame, L["Min. on AH"],
    L["Hide items with fewer units than this on the auction house (illiquid): they will not be in the list or on mobs. 0 shows everything. You can type a number; the buttons change it by 100, with Shift by 1000. Pinned items and items without scan data are never hidden."],
    function() return ns.S.minQty or 0 end, function(v) ns.S.minQty = v end, 0, 999999, 100)
  frame.spinners[1]:SetPoint("BOTTOMLEFT", 14, 12)
  frame.spinners[2]:SetPoint("BOTTOMLEFT", 220, 12)
  frame.spinners[3]:SetPoint("BOTTOMLEFT", 420, 12)

  local nMat = 0
  for _ in pairs(ns.MAT) do nMat = nMat + 1 end
  local quick = makeButton(frame, L["Quick scan of materials"], 150, function() ns.Scan_Start(true) end,
    L["Quick scan of materials"],
    string.format(L["Only the %d gathering materials, 1–2 minutes. The auction house must be open."], nMat))
  quick:SetPoint("BOTTOMRIGHT", -14, 12)
  local fullBtn = makeButton(frame, L["Full scan"], 120, function() ns.Scan_Full(true) end,
    L["Full scan"], L["The whole auction house at once, including mob drops. The server allows it every 15 minutes. The auction house must be open."])
  fullBtn:SetPoint("RIGHT", quick, "LEFT", -6, 0)

  statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -42, -38)
  statusText:SetJustifyH("RIGHT")
  statusText:SetText(ns.scan and ns.scan.status or "")
end

function ns.UI_Toggle()
  if not frame then createFrame() end
  frame:SetShown(not frame:IsShown())
end

---------------------------------------------------------------- item card: header, 21-day chart, sources
local DAYS = 21
local PW, PH = 400, 130
local card

local function createCard()
  card = CreateFrame("Frame", "GatherScoutCard", frame, BACKDROP_TEMPLATE)
  ns.card = card
  ns.chart = card
  card:SetSize(530, H)
  card:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
  card:SetFrameStrata("HIGH")
  card:EnableMouse(true)
  styleWindow(card)

  local close = CreateFrame("Button", nil, card, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() card:Hide(); selectedId = nil; drawRows() end)

  card.icon = card:CreateTexture(nil, "ARTWORK")
  card.icon:SetSize(36, 36)
  card.icon:SetPoint("TOPLEFT", 14, -14)
  card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  card.title:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 8, -1)
  card.title:SetWidth(280) -- narrowed in drawCard to end before the buttons
  card.title:SetJustifyH("LEFT")
  card.title:SetWordWrap(false)
  card.sub = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  card.sub:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -4)

  card.mapBtn = makeButton(card, L["Show on map"], 90, function()
    if card.itemID then ns.Map_Show(card.itemID); ns.Card_Refresh(); drawRows() end
  end, L["Show on map"], L["Open the world map on the best zone for you and show this item there."])
  card.mapBtn:SetPoint("TOPRIGHT", -34, -14)
  card.pinBtn = makeButton(card, L["Pin"], 90, function()
    if not card.itemID then return end
    ns.db.pins[card.itemID] = (not ns.db.pins[card.itemID]) or nil
    ns.Invalidate()
    ns.Map_Refresh()
  end, L["Pin"], L["Pinned items are always marked on mobs and (if enabled) shown on the map."])
  card.pinBtn:SetPoint("RIGHT", card.mapBtn, "LEFT", -4, 0)

  card.stats = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  card.stats:SetPoint("TOPLEFT", 14, -60)
  card.stats:SetWidth(500)
  card.stats:SetJustifyH("LEFT")
  card.stats:SetSpacing(3)

  local function swatch(w, h, r, g, b)
    return string.format("|TInterface\\Buttons\\WHITE8X8:%d:%d:0:0:8:8:0:8:0:8:%d:%d:%d|t", h, w, r, g, b)
  end
  local legend = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  legend:SetPoint("TOPLEFT", 14, -104)
  legend:SetText(swatch(14, 3, 255, 209, 0) .. " " .. L["cheapest lot of the day"] .. "      " .. swatch(5, 5, 102, 255, 102)
    .. " " .. L["market price"] .. "      " .. swatch(8, 10, 89, 153, 255) .. " " .. L["units on the AH"])

  local plot = CreateFrame("Frame", nil, card)
  plot:SetPoint("TOPLEFT", 66, -124)
  plot:SetSize(PW, PH)
  card.plot = plot
  local pbg = plot:CreateTexture(nil, "BACKGROUND")
  pbg:SetAllPoints()
  pbg:SetColorTexture(1, 1, 1, 0.04)
  for i = 1, 3 do
    local g = plot:CreateTexture(nil, "BORDER")
    g:SetColorTexture(1, 1, 1, 0.07)
    g:SetHeight(1)
    g:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, i * PH / 4)
    g:SetPoint("RIGHT", plot, "BOTTOMRIGHT", 0, i * PH / 4)
  end
  card.pLabels, card.qLabels, card.xLabels = {}, {}, {}
  for i = 1, 3 do
    local p = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p:SetJustifyH("RIGHT")
    p:SetWidth(60)
    card.pLabels[i] = p
    local q = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    q:SetJustifyH("LEFT")
    q:SetWidth(50)
    card.qLabels[i] = q
    card.xLabels[i] = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  end

  card.bars, card.dots, card.mdots, card.lines, card.hits = {}, {}, {}, {}, {}
  local bw = PW / DAYS
  for i = 1, DAYS do
    local b = plot:CreateTexture(nil, "ARTWORK")
    b:SetWidth(bw - 3)
    card.bars[i] = b
    local d = plot:CreateTexture(nil, "OVERLAY")
    d:SetColorTexture(1, 0.82, 0, 1)
    d:SetSize(5, 5)
    card.dots[i] = d
    local md = plot:CreateTexture(nil, "OVERLAY")
    md:SetColorTexture(0.4, 1, 0.4, 0.9)
    md:SetSize(4, 4)
    card.mdots[i] = md
    if i > 1 then
      local l = plot:CreateLine(nil, "OVERLAY")
      l:SetThickness(2)
      l:SetColorTexture(1, 0.82, 0, 0.9)
      card.lines[i] = l
    end
    local hit = CreateFrame("Frame", nil, plot)
    hit:SetPoint("BOTTOMLEFT", (i - 1) * bw, 0)
    hit:SetSize(bw, PH)
    hit:EnableMouse(true)
    local hl = hit:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    hl:Hide()
    hit:SetScript("OnEnter", function(self)
      hl:Show()
      local s = card.series and card.series[i]
      if not s then return end
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(date(L["%m/%d/%Y"], s.t))
      if s.minP then
        -- the price of the cheapest lot moved between these two during the day
        local cheapest = ns.Money(s.minP)
        if s.maxP and s.maxP ~= s.minP then cheapest = cheapest .. " – " .. ns.Money(s.maxP) end
        GameTooltip:AddDoubleLine(L["Cheapest lot"], cheapest, 1, 1, 1, 1, 1, 1)
      end
      if s.avgP then GameTooltip:AddDoubleLine(L["Market price"], ns.Money(s.avgP), 1, 1, 1, 1, 1, 1) end
      if s.qty then GameTooltip:AddDoubleLine(L["On the AH"], string.format(L["up to %s pcs"], ns.Num(s.qty)), 1, 1, 1, 1, 1, 1) end
      if s.scans then GameTooltip:AddLine(string.format(L["Scans that day: %d"], s.scans), 0.6, 0.6, 0.6) end
      if s.ext then GameTooltip:AddLine(L["data from another addon"], 0.6, 0.6, 0.6) end
      if not (s.minP or s.qty) then GameTooltip:AddLine(L["no data for this day"], 0.6, 0.6, 0.6) end
      GameTooltip:Show()
    end)
    hit:SetScript("OnLeave", function() hl:Hide(); GameTooltip:Hide() end)
    card.hits[i] = hit
  end
  card.empty = plot:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  card.empty:SetPoint("CENTER")
  card.empty:SetWidth(PW - 40)
  card.empty:SetText(L["No history yet. Scan the auction house on different days and the chart fills up. Price history from another auction addon is picked up automatically."])

  card.summary = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  card.summary:SetPoint("TOPLEFT", 14, -(124 + PH + 22))
  card.summary:SetWidth(500)
  card.summary:SetJustifyH("LEFT")
  card.summary:SetSpacing(4)

  card.whereTitle = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  card.whereTitle:SetText(L["Where to farm (best for you on top)"])
  card.whereHint = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  card.whereHint:SetPoint("BOTTOMLEFT", card.whereTitle, "BOTTOMRIGHT", 10, 1)
  card.whereHint:SetText(L["hover: details, click: expand"])
  card.srcRows = {} -- source rows, created on demand (see drawWhere)
  -- message when there is nothing to show
  card.where = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  card.where:SetWidth(500)
  card.where:SetJustifyH("LEFT")
  card.where:SetJustifyV("TOP")
  card.where:SetSpacing(4)
end

local function drawChart(id)
  local series, ownDays, extDays = ns.DailyHistory(id, DAYS)
  card.series = series
  local pLo, pHi, qHi = math.huge, 0, 0
  for _, s in ipairs(series) do
    if s.minP then pLo = min(pLo, s.minP); pHi = max(pHi, s.minP) end
    if s.avgP then pLo = min(pLo, s.avgP); pHi = max(pHi, s.avgP) end
    if s.qty then qHi = max(qHi, s.qty) end
  end
  local hasP, hasQ = pHi > 0, qHi > 0
  card.empty:SetShown(not hasP and not hasQ)
  if hasP then
    local pad = max((pHi - pLo) * 0.15, pHi * 0.05)
    pLo, pHi = max(0, pLo - pad), pHi + pad
  end
  qHi = qHi * 1.1
  local bw = PW / DAYS
  local function py(v) return (v - pLo) / max(1, pHi - pLo) * PH end
  local prevX, prevY
  for i, s in ipairs(series) do
    local cx = (i - 0.5) * bw
    local bar = card.bars[i]
    if s.qty and s.qty > 0 and hasQ then
      bar:ClearAllPoints()
      bar:SetPoint("BOTTOMLEFT", card.plot, "BOTTOMLEFT", (i - 1) * bw + 1.5, 0)
      bar:SetHeight(max(1, s.qty / qHi * PH))
      bar:SetColorTexture(0.35, 0.6, 1, s.ext and 0.25 or 0.45)
      bar:Show()
    else
      bar:Hide()
    end
    local dot = card.dots[i]
    if s.minP and hasP then
      local y = py(s.minP)
      dot:ClearAllPoints()
      dot:SetPoint("CENTER", card.plot, "BOTTOMLEFT", cx, y)
      dot:Show()
      local l = card.lines[i]
      if l then
        if prevX then
          l:SetStartPoint("BOTTOMLEFT", card.plot, prevX, prevY)
          l:SetEndPoint("BOTTOMLEFT", card.plot, cx, y)
          l:Show()
        else
          l:Hide()
        end
      end
      prevX, prevY = cx, y
    else
      dot:Hide()
      if card.lines[i] then card.lines[i]:Hide() end
    end
    local md = card.mdots[i]
    if s.avgP and hasP then
      md:ClearAllPoints()
      md:SetPoint("CENTER", card.plot, "BOTTOMLEFT", cx, py(s.avgP))
      md:Show()
    else
      md:Hide()
    end
  end
  for k = 1, 3 do
    local frac = (k - 1) / 2
    local p, q = card.pLabels[k], card.qLabels[k]
    p:ClearAllPoints()
    p:SetPoint("RIGHT", card.plot, "BOTTOMLEFT", -4, frac * PH)
    p:SetText(hasP and ns.Money(pLo + (pHi - pLo) * frac, 10) or "")
    q:ClearAllPoints()
    q:SetPoint("LEFT", card.plot, "BOTTOMRIGHT", 4, frac * PH)
    q:SetText(hasQ and ns.Num(qHi * frac) or "")
  end
  local xi = { 1, floor(DAYS / 2) + 1, DAYS }
  for k = 1, 3 do
    local s = series[xi[k]]
    local lbl = card.xLabels[k]
    lbl:ClearAllPoints()
    lbl:SetPoint("TOP", card.plot, "BOTTOMLEFT", (xi[k] - 0.5) * bw, -3)
    lbl:SetText(k == 3 and L["today"] or date(L["%m/%d"], s.t))
  end
  return ownDays, extDays
end

---------------------------------------------------------------- item card: "Where to farm"
-- One row per source, in columns that line up across rows:
--   [+] difficulty | best mob (or zone) | levels | chance | zone + short warnings
-- The opened source (the best one by default; a click on another row switches) lists its next mobs
-- underneath, up to SUB_MAX. Every row has a tooltip with the full mob list and the full warnings, and
-- sources past SRC_MAX sit behind a "N more places" row, so nothing is dropped.
local SRC_MAX, SUB_MAX = 6, 3
local BW = 500                                          -- block width
-- column x offsets; level / chance / zone widths are measured (layoutColumns, drawWhere)
local C_DIFF, C_NAME, C_LV, C_CH, C_ZONE = 18, 64, 262, 298, 346
local LV_W, CH_W = 34, 38
local ROW_H, SUB_H = 18, 16
local PLUS, MINUS = "Interface\\Buttons\\UI-PlusButton-Up", "Interface\\Buttons\\UI-MinusButton-Up"
local CHANCE_LEGEND = string.format(L["Chance: %swhite|r is player statistics, %slight blue|r is the patch 1.12 loot tables, %sgreen|r is from your kills"],
  "|cffffffff", "|cff8cc8ff", "|cff66ff66") .. L[", ?? is unknown"]
local LEVEL_LEGEND = L["Levels are colored like quests: yellow is your level, orange and red are above"]
local drawWhere

local function srcKey(s) return s.kind .. ":" .. tostring(s.map) end
local function expandable(s) return s.kind == "npc" and #s.npcs > 1 end

local function tagText(s)
  if not s.tags or #s.tags == 0 then return "" end
  return "|cffff9a50" .. table.concat(s.tags, ", ") .. "|r"
end

local function zoneLabel(s)
  return ns.MapName(s.map) .. ((s.learned or s.guess) and " |cff909090?|r" or "")
end

-- name, levels (colored relative to you), chance (colored by data source), elite
local function mobCells(id, npcID)
  local n = ns.GEN.npcs[npcID]
  local c, csrc = ns.DropChance(id, npcID)
  return ns.NpcName(npcID), n and rangeText(n[1], n[2], nil, n.guess) or "", ns.ChanceText(c, csrc, true),
    n and (n[3] == 1 or n[3] == 2)
end

-- Cells of a source's own row: name, levels, chance, place (zone + short warnings)
local function srcCells(s, id)
  local lv = rangeText(s.lo, s.hi, s.eff, s.lvGuess)
  local tags = tagText(s)
  local zc = s.enemy and ns.ENEMY_COLOR or "|cffa0a0a0" -- enemy faction territory: zone in orange
  local place = zc .. zoneLabel(s) .. "|r" .. (tags ~= "" and ("  " .. tags) or "")
  if s.kind == "npc" then
    local c, csrc = ns.DropChance(id, s.npcs[1])
    local ch = ns.UNKNOWN_CHANCE
    if c then
      ch = ns.ChanceText(c, csrc)
    elseif s.chance then
      ch = "|cff909090~|r" .. ns.ChanceText(s.chance, s.chanceSrc)
    end
    return ns.NpcName(s.npcs[1]), lv, ch, place
  elseif s.kind == "rule" then
    return s.ct == "beast" and L["Any beasts"] or L["Any humanoids"], lv, ns.UNKNOWN_CHANCE, place
  elseif s.kind == "world" then
    return L["Any mobs"] .. " |cff909090(" .. L["world drop"] .. ")|r", lv,
      ns.ChanceText(s.chance, s.chanceSrc, true), place
  elseif s.kind == "fish" then
    return ns.FishSpot(s), lv, s.chance and ns.ChanceText(s.chance, s.chanceSrc) or "", place
  end
  -- gathering nodes: the zone itself is the source, the last column keeps only the warnings
  return s.enemy and (zc .. zoneLabel(s) .. "|r") or zoneLabel(s), lv, "", tags
end

local function addMobLine(tt, id, npcID, indent, first)
  local name, lv, ch, elite = mobCells(id, npcID)
  tt:AddDoubleLine(indent .. (first and "|cffffffff" or "|cffc8c8c8") .. name .. "|r"
    .. (elite and (" |cffff8080" .. L["elite"] .. "|r") or ""), lv .. (ch ~= "" and ("   " .. ch) or ""))
end

-- Everything about one source: all its mobs with levels and chances, full warnings, what the marks mean
local function sourceTooltip(owner, s, id)
  local tt = GameTooltip
  tt:SetOwner(owner, "ANCHOR_TOP")
  tt:AddDoubleLine(zoneLabel(s), (ns.DiffLabel(s.mult)), 1, 0.82, 0)
  if s.note and s.note ~= "" then tt:AddLine(s.note, 1, 0.6, 0.3, true) end
  local lv = rangeText(s.lo, s.hi, s.eff, s.lvGuess)
  local chances = false
  if s.kind == "npc" then
    local total = #s.npcs
    tt:AddLine(LP("%d mobs in the zone, best for you on top:", total), 0.6, 0.6, 0.6)
    local shown = min(total, 15)
    for j = 1, shown do addMobLine(tt, id, s.npcs[j], "", j == 1) end
    if total > shown then tt:AddLine(string.format(L["…and %d more"], total - shown), 0.6, 0.6, 0.6) end
    if s.chance and not ns.DropChance(id, s.npcs[1]) then
      tt:AddLine(L["~ means the first mob's chance is unknown; the median of the zone's mobs is shown"], 0.6, 0.6, 0.6, true)
    end
    for j = 1, shown do
      local n = ns.GEN.npcs[s.npcs[j]]
      if n and n.guess then
        tt:AddLine(L["~ before levels: the mob's level is unknown yet, the zone's levels are shown until you see it"],
          0.6, 0.6, 0.6, true)
        break
      end
    end
    chances = true
  elseif s.kind == "rule" then
    tt:AddLine(string.format(s.ct == "beast" and L["Any beasts of level %s in this zone"] or L["Any humanoids of level %s in this zone"], lv),
      1, 1, 1)
  elseif s.kind == "world" then
    tt:AddLine(string.format(L["World drop: any mobs of level %s in this zone"], lv), 1, 1, 1)
    tt:AddDoubleLine(L["chance per mob"], ns.ChanceText(s.chance, s.chanceSrc, true), 0.8, 0.8, 0.8)
    chances = true
  elseif s.kind == "fish" then
    tt:AddLine(ns.FishSpot(s), 1, 1, 1)
    tt:AddLine(string.format(L["This item is %s of the catch here"], ns.ChanceText(s.chance, s.chanceSrc)), 1, 1, 1)
    tt:AddLine(string.format(L["Zone fishing skill: %d, no getaways from %d"], s.zs, s.zs + 95), 0.8, 0.8, 0.8)
    local have = ns.Context().profs.fish
    if have then
      tt:AddLine(string.format(L["Your fishing skill %d: %d%% of casts catch something"], have,
        floor((s.success or 0) * 100 + 0.5)), 0.8, 0.8, 0.8)
    end
    chances = true
  else
    tt:AddLine(string.format(L["Gathering nodes in the zone, zone levels %s"], lv), 1, 1, 1)
    if s.learned then
      tt:AddLine(L["? means the zone is known only from your own loot"], 0.6, 0.6, 0.6)
    elseif s.guess then
      tt:AddLine(L["? means the place is approximate: the database has no nodes"], 0.6, 0.6, 0.6)
    end
  end
  tt:AddLine(" ")
  if chances then tt:AddLine(CHANCE_LEGEND, 0.6, 0.6, 0.6, true) end
  tt:AddLine(LEVEL_LEGEND, 0.6, 0.6, 0.6, true)
  if owner.head and expandable(s) then
    tt:AddLine(owner.isOpen and L["Click: collapse"] or L["Click: show the mobs under the row"], 0.6, 0.6, 0.6)
  end
  tt:Show()
end

-- Sources that did not fit into the card, with their first mobs
local function moreSourcesTooltip(owner, row, from)
  local tt = GameTooltip
  local id = row.id
  tt:SetOwner(owner, "ANCHOR_TOP")
  local rest = #row.sources - from + 1
  tt:AddLine(LP("%d more places, less convenient for you", rest))
  local last = min(#row.sources, from + 9)
  for i = from, last do
    local s = row.sources[i]
    local name, lv, ch, place = srcCells(s, id)
    tt:AddDoubleLine((ns.DiffLabel(s.mult)) .. "  " .. name .. " " .. lv .. (ch ~= "" and ("  " .. ch) or ""), place)
    if s.kind == "npc" then
      local upto = min(#s.npcs, 4)
      for j = 2, upto do addMobLine(tt, id, s.npcs[j], "      ", false) end
      if #s.npcs > upto then tt:AddLine("      |cff909090" .. string.format(L["…and %d more"], #s.npcs - upto) .. "|r") end
    end
  end
  if #row.sources > last then tt:AddLine(string.format(L["…and %d more"], #row.sources - last), 0.6, 0.6, 0.6) end
  tt:Show()
end

-- Column widths from the real text in the client's font (digits are not equally wide): the difficulty
-- column fits the longest difficulty word, levels fit "88–88", chance fits "~0.25%". Once per session;
-- the zone column is sized per item in drawWhere.
local columnsMeasured
local function textWidth(s)
  card.measure:SetText(s)
  return card.measure:GetStringWidth() or 0
end
local function layoutColumns()
  columnsMeasured = true
  card.measure = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  card.measure:SetAlpha(0)
  local w = 0
  for _, mult in ipairs({ 1, 1.5, 2, 3, 5 }) do w = max(w, textWidth((ns.DiffLabel(mult)))) end
  C_NAME = C_DIFF + max(42, math.ceil(w)) + 6
  local lw = 0
  for _, s in ipairs({ "~88–88", "88–88", "00–00", "58–59" }) do lw = max(lw, textWidth(s)) end
  LV_W = math.ceil(lw) + 4
  local cw = 0
  for _, s in ipairs({ "~" .. ns.Dec("%.2f%%", 0.25), "100%", "48%" }) do cw = max(cw, textWidth(s)) end
  CH_W = math.ceil(cw) + 2
  card.measure:SetText("")
end

-- Zone column as wide as the longest zone (+ short tags) among the rows shown; the rest goes to the names
local function layoutZone(places)
  local zw = 0
  for _, p in ipairs(places) do zw = max(zw, textWidth(p)) end
  card.measure:SetText("")
  zw = math.ceil(min(190, max(70, zw + 2)))
  C_ZONE = BW - zw
  C_CH = C_ZONE - 8 - CH_W
  C_LV = C_CH - 6 - LV_W
end

local function srcRow(i)
  if not columnsMeasured then layoutColumns() end
  local r = card.srcRows[i]
  if r then return r end
  r = CreateFrame("Button", nil, card)
  r:SetWidth(BW)
  r.bg = r:CreateTexture(nil, "BACKGROUND") -- groups the opened source with its mobs
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(1, 1, 1, 0.04)
  r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD") -- same as the list rows
  r.tog = r:CreateTexture(nil, "ARTWORK")
  r.tog:SetSize(14, 14)
  r.tog:SetPoint("LEFT", 0, 0)
  local function cell(x, w, justify)
    local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", x, 0)
    fs:SetSize(w, ROW_H)
    fs:SetJustifyH(justify)
    fs:SetWordWrap(false)
    return fs
  end
  r.diff = cell(C_DIFF, C_NAME - C_DIFF - 4, "LEFT")
  r.name = cell(C_NAME, C_LV - C_NAME - 6, "LEFT")
  r.lv = cell(C_LV, C_CH - C_LV - 2, "LEFT")
  r.ch = cell(C_CH, C_ZONE - C_CH - 10, "RIGHT")
  r.zone = cell(C_ZONE, BW - C_ZONE, "LEFT")
  r:SetScript("OnEnter", function(self)
    local row = ns.rowById and ns.rowById[card.itemID]
    if self.from then
      if row then moreSourcesTooltip(self, row, self.from) end
    elseif self.src then
      sourceTooltip(self, self.src, card.itemID)
    end
  end)
  r:SetScript("OnLeave", GameTooltip_Hide)
  r:SetScript("OnClick", function(self)
    local s = self.src
    if not (self.head and s and expandable(s)) then return end
    card.openKey = (not self.isOpen) and srcKey(s) or false
    ns.Compute()
    drawWhere(ns.rowById and ns.rowById[card.itemID])
    -- rows below moved: refresh the tooltip of whatever is under the cursor now
    if self:IsShown() and self:IsMouseOver() then self:GetScript("OnEnter")(self) else GameTooltip:Hide() end
  end)
  card.srcRows[i] = r
  return r
end

drawWhere = function(row)
  local id = card.itemID
  local sources = row and row.sources or {}
  -- one extra source costs the same height as the "1 more place" row, so just show it
  local nSrc = (#sources == SRC_MAX + 1) and #sources or min(SRC_MAX, #sources)

  -- opened source: the one the user clicked (false = user closed all), else the best one
  local open
  for i = 1, nSrc do
    local s = sources[i]
    if expandable(s) and (card.openKey == srcKey(s) or (card.openKey == nil and i == 1)) then open = i end
  end
  local others = open and (#sources[open].npcs - 1) or 0
  local nSub = (others == SUB_MAX + 1) and others or min(SUB_MAX, others)

  -- keep inside the card: fewer mobs under the opened source first, then fewer sources
  local avail = H - 12 - (124 + PH + 22) - card.summary:GetStringHeight() - 14
    - card.whereTitle:GetStringHeight() - 6
  local function height()
    local h = nSrc * ROW_H + nSub * SUB_H
    if others > nSub then h = h + SUB_H end
    if #sources > nSrc then h = h + ROW_H end
    return h
  end
  while height() > avail and nSub > 1 do nSub = nSub - 1 end
  while height() > avail and nSrc > 1 do
    nSrc = nSrc - 1
    if open and open > nSrc then open, others, nSub = nil, 0, 0 end
  end

  if not columnsMeasured then layoutColumns() end
  local rowCells, places = {}, {}
  for i = 1, nSrc do
    rowCells[i] = { srcCells(sources[i], id) }
    places[i] = rowCells[i][4]
  end
  layoutZone(places)

  local n, y = 0, 0
  local function place(h, s, head)
    n = n + 1
    local r = srcRow(n)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", card.whereTitle, "BOTTOMLEFT", 0, -(6 + y))
    r:SetHeight(h)
    r.src, r.head, r.isOpen, r.from = s, head, false, nil
    r.tog:Hide()
    r.bg:Hide()
    r:Show()
    y = y + h
    return r
  end
  -- wide = the name runs to the end of the row (for the "N more" rows)
  local function cells(r, x, wide, diff, name, lv, ch, zone)
    r.diff:SetText(diff or "")
    r.name:ClearAllPoints()
    r.name:SetPoint("LEFT", x, 0)
    r.name:SetWidth((wide and BW or (C_LV - 6)) - x)
    r.name:SetText(name or "")
    r.lv:ClearAllPoints()
    r.lv:SetPoint("LEFT", C_LV, 0)
    r.lv:SetWidth(LV_W)
    r.lv:SetText(lv or "")
    r.ch:ClearAllPoints()
    r.ch:SetPoint("LEFT", C_CH, 0)
    r.ch:SetWidth(CH_W)
    r.ch:SetText(ch or "")
    r.zone:ClearAllPoints()
    r.zone:SetPoint("LEFT", C_ZONE, 0)
    r.zone:SetWidth(BW - C_ZONE)
    r.zone:SetText(zone or "")
  end

  for i = 1, nSrc do
    local s = sources[i]
    local r = place(ROW_H, s, true)
    local name, lv, ch, where = unpack(rowCells[i])
    cells(r, C_NAME, false, (ns.DiffLabel(s.mult)), name, lv, ch, where)
    if expandable(s) then
      r.isOpen = (i == open)
      r.tog:SetTexture(r.isOpen and MINUS or PLUS)
      r.tog:Show()
    end
    if i == open then
      r.bg:Show()
      for j = 2, 1 + nSub do
        local sr = place(SUB_H, s, false)
        sr.isOpen = true
        sr.bg:Show()
        local mname, mlv, mch, elite = mobCells(id, s.npcs[j])
        cells(sr, C_NAME + 12, false, "", "|cffc8c8c8" .. mname .. "|r", mlv, mch,
          elite and ("|cffff8080" .. L["elite"] .. "|r") or "")
      end
      if others > nSub then
        local rest = others - nSub
        local mr = place(SUB_H, s, false)
        mr.isOpen = true
        mr.bg:Show()
        cells(mr, C_NAME + 12, true, "", "|cff909090" .. LP("%d more mobs — hover to see all", rest) .. "|r")
      end
    end
  end
  if #sources > nSrc then
    local rest = #sources - nSrc
    local r = place(ROW_H, nil, false)
    r.from = nSrc + 1
    cells(r, C_DIFF, true, "", "|cff909090" .. LP("%d more places — hover", rest) .. "|r")
  end
  for k = n + 1, #card.srcRows do card.srcRows[k]:Hide() end

  card.whereHint:SetShown(#sources > 0)
  if row and #sources == 0 then
    card.where:SetText("|cffff6060" .. string.format(L["You can't get it right now: level, skill or profession. Turn on “%s” to see everything."],
      L["Show dangerous and unavailable"]) .. "|r")
  else
    card.where:SetText("")
  end
end

local function drawCard(id)
  ns.Compute()
  local row = ns.rowById and ns.rowById[id]
  if card.itemID ~= id then card.openKey = nil end -- another item: open its best source again
  card.itemID = id
  card.icon:SetTexture(ns.ItemIcon(id))
  local name = ns.ItemName(id) or string.format(L["item %d"], id)
  local q = ns.ItemQuality(id)
  local color = (q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] and ITEM_QUALITY_COLORS[q].hex) or "|cffffffff"
  card.title:SetText(color .. name .. "|r")
  local meta = ns.Meta(id)
  card.sub:SetText("|cffa0a0a0" .. (ns.CATS[meta.c] and ns.CATS[meta.c].label or "") ..
    (ns.db.pins[id] and ("   " .. L["pinned"]) or "") .. (ns.mapSel[id] and ("   " .. L["on the map"]) or "") .. "|r")
  card.mapBtn:SetText(L["Show on map"])
  fitButton(card.mapBtn)
  card.pinBtn:SetText(ns.db.pins[id] and L["Unpin"] or L["Pin"])
  fitButton(card.pinBtn)
  -- the title ends where the buttons start (530 card, 14 icon inset + 36 icon + 8 gap, map button 34 from the right)
  card.title:SetWidth(max(80, 530 - 34 - card.mapBtn:GetWidth() - 4 - card.pinBtn:GetWidth() - 8 - 58))

  local stats = {}
  if row then
    stats[#stats + 1] = string.format(L["Price: %s      On AH: %s      Demand: %s"],
      priceText(row, 14) or "—", row.qty and ns.Num(row.qty) or "—", row.dem.label)
    local second = string.format(L["Difficulty: %s"], (ns.DiffLabel(row.best and row.best.mult)))
    local ch = chanceOf(row)
    if ch then second = second .. "      " .. string.format(L["Chance: %s"], ch) end
    if row.gph then second = second .. "      " .. string.format(L["~Income: %s /h"], ns.Money(row.gph, 14)) end
    stats[#stats + 1] = second
  end
  card.stats:SetText(table.concat(stats, "\n"))

  local ownDays, extDays = drawChart(id)
  local _, dem = ns.Demand(id)
  local lines = {}
  if dem.none then
    lines[#lines + 1] = L["No price data yet."]
  else
    lines[#lines + 1] = string.format(L["Cheapest lot: now %s, usually %s (over 7 days), %s"],
      ns.Money(dem.pMin), dem.refP and ns.Money(dem.refP) or "—",
      dem.refP and (dem.pMin and pct(dem.trend) or "—") or L["needs 2+ days of history"])
    if dem.q then
      lines[#lines + 1] = string.format(L["On AH: now %s pcs, usually %s, %s"], ns.Num(dem.q),
        dem.refQ and string.format(L["%s pcs"], ns.Num(dem.refQ)) or "—",
        (dem.refQ and dem.refQ > 0) and pct(dem.q / dem.refQ) or L["needs 2+ days of history"])
    end
    if dem.perDay then
      local stock = ""
      if dem.stockDays then
        local d = dem.stockDays
        stock = ", " .. string.format(L["the stock lasts ~%s days"],
          d < 10 and ns.Dec("%.1f", d) or d < 100 and ns.Num(d) or "99+")
      end
      lines[#lines + 1] = string.format(L["Leaves the AH: ~%s pcs/day"], ns.Num(dem.perDay)) .. stock
        .. " |cff909090(" .. L["from your scans: sales and cancelled auctions"] .. ")|r"
    else
      lines[#lines + 1] = "|cff909090" .. L["Sales speed: needs a few of your scans a couple of hours apart."] .. "|r"
    end
  end
  lines[#lines + 1] = "|cff909090" .. LP("History source: your scans, %d days", ownDays)
    .. (extDays > 0 and (", " .. LP("another addon, %d days", extDays)) or "") .. "|r"
  card.summary:SetText(table.concat(lines, "\n"))

  card.whereTitle:ClearAllPoints()
  card.whereTitle:SetPoint("TOPLEFT", card.summary, "BOTTOMLEFT", 0, -14)
  card.where:ClearAllPoints()
  card.where:SetPoint("TOPLEFT", card.whereTitle, "BOTTOMLEFT", 0, -6)
  drawWhere(row)
end

function ns.Card_Show(id)
  if not frame then return end
  if not card then createCard() end
  drawCard(id)
  card:Show()
end

function ns.Card_Refresh()
  if card and card:IsShown() and card.itemID then drawCard(card.itemID) end
end
ns.Chart_Show = ns.Card_Show

---------------------------------------------------------------- minimap button
local mmb

local function mmPosition()
  local a = math.rad(ns.S.minimap.angle or 205)
  local r = (Minimap:GetWidth() / 2) + 8
  mmb:ClearAllPoints()
  mmb:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

function ns.Minimap_Update()
  if not mmb then return end
  if ns.S.minimap.hide then mmb:Hide() else mmb:Show(); mmPosition() end
end

local function createMinimapButton()
  mmb = CreateFrame("Button", "GatherScoutMinimapButton", Minimap)
  mmb:SetSize(31, 31)
  mmb:SetFrameStrata("MEDIUM")
  mmb:SetFrameLevel(8)
  mmb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  mmb:RegisterForDrag("LeftButton")
  local icon = mmb:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Herb_07")
  icon:SetSize(20, 20)
  icon:SetPoint("TOPLEFT", 7, -5)
  local border = mmb:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  mmb:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  mmb:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then
      ns.S.enabled = not ns.S.enabled
      ns.Print(L["mob markers %s"], ns.S.enabled and ("|cff00ff00" .. L["enabled"] .. "|r") or ("|cffff4040" .. L["disabled"] .. "|r"))
      ns.Invalidate()
    else
      ns.UI_Toggle()
    end
  end)
  mmb:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      ns.S.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      mmPosition()
    end)
  end)
  mmb:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  mmb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("GatherScout")
    GameTooltip:AddLine(L["Left-click: the “what to farm” list"], 1, 1, 1)
    GameTooltip:AddLine(string.format(L["Right-click: mob markers: %s"], ns.OnOff(ns.S.enabled)), 1, 1, 1)
    GameTooltip:AddLine(L["Drag to move"], 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  mmb:SetScript("OnLeave", GameTooltip_Hide)
  ns.Minimap_Update()
end

function ns.UI_Init()
  createMinimapButton()
end
