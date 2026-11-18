-- GatherScout UI: the "what to farm" list, the item card (21-day chart, sources, chances), the minimap button.
local _, ns = ...

local floor, max, min = math.floor, math.max, math.min
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
local IS_RU = GetLocale() == "ruRU"

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
  { key = "name",   title = "Предмет",     w = 190, justify = "LEFT" },
  { key = "price",  title = "Цена",        w = 96,  justify = "RIGHT" },
  { key = "qty",    title = "На аук.",     w = 60,  justify = "RIGHT" },
  { key = "F",      title = "Спрос",       w = 100, justify = "CENTER" },
  { key = "diff",   title = "Сложность",   w = 70,  justify = "CENTER" },
  { key = "where",  title = "Где лучше всего (для тебя)", w = 222, justify = "LEFT" },
  { key = "chance", title = "Шанс",        w = 54,  justify = "CENTER" },
  { key = "score",  title = "~доход/ч",    w = 96,  justify = "RIGHT" },
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
function ns.NpcName(npcID)
  local n = ns.GEN.npcs[npcID]
  if not n then return "?" end
  if IS_RU and n[7] then return n[7] end
  return n[6] or "?"
end

local function rangeText(lo, hi, eff)
  if not lo then return "" end
  local col = ns.LevelColor(eff or lo)
  if hi and hi ~= lo then return string.format("%s%d–%d|r", col, lo, hi) end
  return string.format("%s%d|r", col, lo)
end

-- One-line description of a source, no glyphs the game font lacks
function ns.WhereText(src, itemID)
  if not src then return "|cff808080нет подходящих мест|r" end
  local zone = ns.MapName(src.map)
  local lv = rangeText(src.lo, src.hi, src.eff)
  local text
  if src.kind == "npc" then
    text = string.format("%s %s |cffa0a0a0(%s)|r", ns.NpcName(src.npcs[1]), lv, zone)
  elseif src.kind == "rule" then
    text = string.format("%s %s |cffa0a0a0(%s)|r", src.ct == "beast" and "Звери" or "Гуманоиды", lv, zone)
  elseif src.kind == "world" then
    text = string.format("Мобы %s |cffa0a0a0(%s)|r", lv, zone)
  else
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
  if m < 60 then return m .. " мин назад" end
  if m < 48 * 60 then return floor(m / 60) .. " ч назад" end
  return floor(m / 1440) .. " дн назад"
end

-- "market price" plus the lowest price when someone is clearly undercutting below the market
local function priceText(row, size)
  if not row.price then return nil end
  local txt = ns.Money(row.price, size)
  if row.minP and row.minP < row.price * 0.9 then
    txt = txt .. "  |cff909090мин. " .. ns.Money(row.minP, size) .. "|r"
  end
  return txt
end

local function chanceOf(row)
  if not row.chance or row.chanceGuess then return nil end
  return ns.ChanceText(row.chance, row.best and row.best.chanceSrc, row.best and row.best.corpses)
    .. (row.chanceGuess and " |cff909090(оценка)|r" or "")
end

---------------------------------------------------------------- compact hover tooltip (left of the window)
function ns.ShowItemDetails(owner, data)
  local tt = GameTooltip
  tt:SetOwner(owner, "ANCHOR_NONE")
  tt:ClearAllPoints()
  tt:SetPoint("TOPRIGHT", frame, "TOPLEFT", -6, -40)
  tt:SetItemByID(data.id)
  tt:AddLine(" ")
  tt:AddDoubleLine("Цена (рынок)", priceText(data) or "|cff909090нет данных|r", 1, 0.82, 0)
  tt:AddDoubleLine("Спрос", data.dem.label, 1, 0.82, 0)
  if data.best then
    tt:AddDoubleLine("Сложность", (ns.DiffLabel(data.best.mult)), 1, 0.82, 0)
    tt:AddDoubleLine("Где", ns.WhereText(data.best, data.id), 1, 0.82, 0)
  end
  local ch = chanceOf(data)
  if ch then tt:AddDoubleLine("Шанс", ch, 1, 0.82, 0) end
  if data.gph then tt:AddDoubleLine("~Доход", ns.Money(data.gph) .. " /ч", 1, 0.82, 0) end
  tt:AddLine(" ")
  tt:AddLine("ЛКМ — карточка: график, где добывать, карта", 0.6, 0.6, 0.6)
  tt:AddLine("ПКМ — закрепить    Shift+ЛКМ — ссылка в чат", 0.6, 0.6, 0.6)
  tt:Show()
end

---------------------------------------------------------------- list data
local function sortValue(row, key)
  if key == "name" then return ns.ItemName(row.id) or "" end
  if key == "price" then return row.price or -1 end
  if key == "qty" then return row.qty or -1 end
  if key == "F" then return row.F or 0 end
  if key == "diff" then return row.best and -row.best.mult or -999 end
  if key == "where" then return row.best and ns.MapName(row.best.map) or "яяя" end
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
      local name = ns.ItemName(id) or ("item " .. id)
      local q = ns.ItemQuality(id)
      local color = (q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] and ITEM_QUALITY_COLORS[q].hex) or "|cffffffff"
      r.icon:SetTexture(ns.ItemIcon(id))
      r.cols.name:SetText(color .. name .. "|r" .. (data.m.guess and " |cff909090*|r" or ""))
      local ptxt = data.price and ns.Money(data.price) or "|cff808080—|r"
      r.cols.price:SetText(ptxt)
      if data.qty == nil then
        r.cols.qty:SetText("|cff808080—|r")
      elseif data.qty == 0 then
        r.cols.qty:SetText("|cffff40400|r")
      else
        r.cols.qty:SetText(tostring(data.qty))
      end
      local dl = data.dem.none and data.dem.label or (ns.DemandIcon(data.dem, 12) .. " " .. data.dem.label)
      if data.dem.refP and data.dem.trend and (data.dem.trend >= 1.1 or data.dem.trend <= 0.9) then
        dl = dl .. " " .. pct(data.dem.trend)
      end
      r.cols.F:SetText(dl)
      r.cols.diff:SetText((ns.DiffLabel(data.best and data.best.mult)))
      r.cols.where:SetText(ns.WhereText(data.best, id))
      if data.chance and not data.chanceGuess and data.best then
        r.cols.chance:SetText(ns.ChanceText(data.chance, data.best.chanceSrc))
      else
        r.cols.chance:SetText("|cff808080-|r")
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
  frame.count:SetText(#view > 0 and (#view .. " поз.") or "")
end

local function refreshInfo()
  local ctx = ns.Context()
  local parts = { "Уровень |cffffffff" .. ctx.level .. "|r" }
  for _, k in ipairs({ "herb", "mine", "skin" }) do
    local v = ctx.profs[k]
    parts[#parts + 1] = ns.PROF_LABEL[k] .. " " .. (v and ("|cffffffff" .. v .. "|r") or "|cff808080—|r")
  end
  local m = ns.Market()
  local a = ago(m.lastScan)
  if a then
    local stale = (time() - m.lastScan) > 86400
    parts[#parts + 1] = (stale and "|cffff8040" or "|cff40ff40") .. "аукцион: " .. a .. "|r"
  else
    parts[#parts + 1] = "|cffff8040нет данных аукциона, открой аукцион|r"
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

local function makeButton(parent, text, w, onClick, tipTitle, tip)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
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
local NP_POS = { right = "справа", top = "сверху", left = "слева" }
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
  title:SetText("GatherScout |cffa0a0a0— что сейчас выгодно добывать|r")

  -- search
  searchBox = CreateFrame("EditBox", "GatherScoutSearch", frame, "InputBoxTemplate")
  searchBox:SetSize(190, 20)
  searchBox:SetPoint("TOPRIGHT", -40, -12)
  searchBox:SetAutoFocus(false)
  local hint = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("LEFT", 4, 0)
  hint:SetText("Поиск по названию…")
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
    makeCheck(frame, "Только мои профессии",
      "Показывать только то, что можно добыть твоими профессиями (ткань и дроп — всегда).",
      function() return ns.S.onlyMyProfs end, function(v) ns.S.onlyMyProfs = v end),
    makeCheck(frame, "Показать опасное и недоступное",
      "Показывать зоны сильно выше твоего уровня и то, на что пока не хватает навыка.",
      function() return ns.S.showDangerous end, function(v) ns.S.showDangerous = v end),
    makeCheck(frame, "Помечать всех мобов с дропом",
      "Иконка на любом мобе, с которого падает что-то отслеживаемое, а не только из топа списка.",
      function() return ns.S.markAll end, function(v) ns.S.markAll = v end),
    makeCheck(frame, "Закреплённое на карте",
      "Показывать закреплённые предметы на карте мира: точки в зоне и значки зон на карте континента.",
      function() return ns.S.mapPinned end, function(v) ns.S.mapPinned = v; ns.Map_Refresh() end),
  }
  local optsEnd = layoutRow(frame, opts, 12, -78)
  local DEM_MODE = { icon = "иконка", text = "текст", off = "не показывать" }
  local DEM_NEXT = { icon = "text", text = "off", off = "icon" }
  local demBtn = makeButton(frame, "", 200, function()
    ns.S.tipDemand = DEM_NEXT[ns.S.tipDemand] or "icon"
    frame.demBtn.update()
  end, "Спрос в подсказках", "Как показывать спрос в подсказке на мобе и на траве/жиле: цветной точкой, "
    .. "словом или не показывать.")
  demBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", optsEnd, -79)
  demBtn.update = function() demBtn:SetText("Спрос в подсказках: " .. (DEM_MODE[ns.S.tipDemand] or "иконка")) end
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
    fs:SetText(col.title)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    if col.key == "F" then
      tooltipFor(b, "Спрос на аукционе",
        ns.DemandIcon({ level = "high" }) .. " высокий: товара меньше обычного или он быстро уходит\n"
        .. ns.DemandIcon({ level = "mid" }) .. " средний: обычная ситуация\n"
        .. ns.DemandIcon({ level = "low" }) .. " низкий: на аукционе завал, продаётся медленно\n"
        .. ns.DemandIcon({ level = "empty" }) .. "|cff40ff40!|r нет ни одного лота\n\n"
        .. "Считается по количеству лотов против обычного (7 дней), тренду цены и тому, "
        .. "как быстро лоты уходят между твоими сканами. Клик — сортировка.")
    end
    if col.key == "price" then
      tooltipFor(b, "Рыночная цена",
        "Цена, по которой реально лежит основная масса дешёвых лотов: берётся дешёвая часть рынка "
        .. "(15–30% всех штук), из неё выкидываются выбросы — например, пара десятков штук, выставленных "
        .. "демпингом перед тысячами по нормальной цене. Минимальная цена видна в подсказке строки и в "
        .. "карточке, если она заметно ниже. Клик — сортировка.")
    elseif col.key == "diff" then
      tooltipFor(b, "Сложность для тебя",
        "Насколько тяжело добывать именно тебе: уровень мобов в лучшем месте против твоего "
        .. "(легко — ты там всех убиваешь, средне — зона твоего уровня, опасно — мобы выше), "
        .. "элитные мобы, чужая фракция, нехватка навыка, мало точек. Клик — сортировка.")
    elseif col.key == "where" then
      tooltipFor(b, "Где лучше всего (для тебя)",
        "Лучшее место с учётом твоего уровня: зона с уровнями, конкретный моб или «звери/гуманоиды N–M». "
        .. "Клик — сортировка по зоне.")
    elseif col.key == "chance" then
      tooltipFor(b, "Шанс выпадения",
        "Шанс получить предмет с одного моба в лучшем месте. Цвет показывает источник:\n"
        .. ns.CHANCE_COLOR.db .. "белый|r — данные wowhead (из Questie)\n"
        .. ns.CHANCE_COLOR.classic .. "голубой|r — данные классики (CMaNGOS, 1.12)\n"
        .. ns.CHANCE_COLOR.learned .. "зелёный|r — по твоим убийствам (20+ трупов этого моба)\n"
        .. "Прочерк — шанс неизвестен или это сбор (травы, руда). Клик — сортировка.")
    elseif col.key == "score" then
      tooltipFor(b, "Примерный доход в час",
        "Цена x сколько добудешь за час x спрос / сложность. Грубая оценка: она нужна, чтобы сравнивать "
        .. "строки между собой, а не как точная сумма. Список по умолчанию отсортирован по ней. Клик — сортировка.")
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
        tooltipFor(pin, "Закрепить", "Закреплённое всегда помечается на мобах и показывается на карте.")
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
  emptyText:SetText("Ничего не найдено. Проверь поиск, категории и «Только мои профессии», "
    .. "или включи «Показать опасное и недоступное». Дроп с мобов появится после скана аукциона.")

  -- bottom: mob marking switches
  local sep = frame:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(1, 1, 1, 0.12)
  sep:SetPoint("BOTTOMLEFT", 12, 66)
  sep:SetPoint("BOTTOMRIGHT", -12, 66)

  local mob = {
    makeCheck(frame, "Пометки на мобах",
      "Главный выключатель: иконки на неймплейтах, у портрета цели и строки в подсказке. Также /gs on и /gs off.",
      function() return ns.S.enabled end, function(v) ns.S.enabled = v end),
    makeCheck(frame, "Неймплейты", "Иконка предмета у полоски здоровья над мобом.",
      function() return ns.S.nameplates end, function(v) ns.S.nameplates = v end),
    makeCheck(frame, "У портрета цели", "Иконка у рамки цели; наведи на неё, чтобы увидеть, что падает.",
      function() return ns.S.targetIcon end, function(v) ns.S.targetIcon = v end),
    makeCheck(frame, "Подсказка на мобе", "Строки с дропом, шансом, ценой и спросом при наведении на моба.",
      function() return ns.S.tooltips end, function(v) ns.S.tooltips = v end),
    makeCheck(frame, "Автоскан на аукционе",
      "Сканировать аукцион при открытии (не чаще раза в 30 минут).",
      function() return ns.S.autoScan end, function(v) ns.S.autoScan = v end),
    makeCheck(frame, "Кнопка у миникарты", nil,
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
  end, "Иконка на неймплейте", "Где рисовать иконку у полоски здоровья. Слева свою иконку ставит Questie.")
  npBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", bx, 38)
  npBtn.update = function() npBtn:SetText("Иконка: " .. (NP_POS[ns.S.npPos] or "справа")) end
  frame.npPosBtn = npBtn

  frame.spinners = {
    makeSpinner(frame, "Уровней выше меня",
      "Насколько выше твоего уровня могут быть зоны и мобы в подсказках. Меньше — безопаснее.",
      function() return ns.S.maxAbove end, function(v) ns.S.maxAbove = v end, 0, 15),
    makeSpinner(frame, "Помечать топ",
      "Сколько лучших позиций списка считаются «горячими»: мобы с них получают иконку.",
      function() return ns.S.topN end, function(v) ns.S.topN = v end, 1, 60),
  }
  frame.spinners[3] = makeNumberBox(frame, "Мин. на аукционе",
    "Скрывать предметы, которых на аукционе меньше этого количества (неликвид): их не будет в списке и на мобах. "
    .. "0 — показывать всё. Число можно вписать, кнопки меняют на 100, с Shift — на 1000. "
    .. "Закреплённое и предметы без данных скана не скрываются.",
    function() return ns.S.minQty or 0 end, function(v) ns.S.minQty = v end, 0, 999999, 100)
  frame.spinners[1]:SetPoint("BOTTOMLEFT", 14, 12)
  frame.spinners[2]:SetPoint("BOTTOMLEFT", 220, 12)
  frame.spinners[3]:SetPoint("BOTTOMLEFT", 420, 12)

  local quick = makeButton(frame, "Быстрый скан сырья", 150, function() ns.Scan_Start(true) end,
    "Быстрый скан сырья", "Только ~120 материалов собирательных профессий, 1–2 минуты. Нужен открытый аукцион.")
  quick:SetPoint("BOTTOMRIGHT", -14, 12)
  local fullBtn = makeButton(frame, "Полный скан", 120, function() ns.Scan_Full(true) end,
    "Полный скан", "Весь аукцион за раз, включая дроп с мобов. Сервер разрешает раз в 15 минут. Нужен открытый аукцион.")
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
  card.title:SetWidth(280)
  card.title:SetJustifyH("LEFT")
  card.title:SetWordWrap(false)
  card.sub = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  card.sub:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -4)

  card.mapBtn = makeButton(card, "На карте", 90, function()
    if card.itemID then ns.Map_Toggle(card.itemID, true); ns.Card_Refresh(); drawRows() end
  end, "На карте", "Показать точки сбора и мобов на карте мира и открыть её на лучшей для тебя зоне. Повторный клик — убрать.")
  card.mapBtn:SetPoint("TOPRIGHT", -34, -14)
  card.pinBtn = makeButton(card, "Закрепить", 90, function()
    if not card.itemID then return end
    ns.db.pins[card.itemID] = (not ns.db.pins[card.itemID]) or nil
    ns.Invalidate()
    ns.Map_Refresh()
  end, "Закрепить", "Закреплённое всегда помечается на мобах и (по настройке) показывается на карте.")
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
  legend:SetText(swatch(14, 3, 255, 209, 0) .. " мин. цена за день      " .. swatch(5, 5, 102, 255, 102)
    .. " твоя рыночная цена      " .. swatch(8, 10, 89, 153, 255) .. " сколько было на аукционе")

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
      GameTooltip:AddLine(date("%d.%m.%Y", s.t))
      if s.minP then
        GameTooltip:AddDoubleLine("мин. цена", ns.Money(s.minP), 1, 1, 1, 1, 1, 1)
        if s.maxP and s.maxP ~= s.minP then GameTooltip:AddDoubleLine("макс. из мин. цен", ns.Money(s.maxP), 1, 1, 1, 1, 1, 1) end
      end
      if s.avgP then GameTooltip:AddDoubleLine("рыночная (твои сканы)", ns.Money(s.avgP), 1, 1, 1, 1, 1, 1) end
      if s.qty then GameTooltip:AddDoubleLine("на аукционе (макс.)", s.qty .. " шт", 1, 1, 1, 1, 1, 1) end
      if s.scans then GameTooltip:AddLine("твоих сканов: " .. s.scans, 0.6, 0.6, 0.6) end
      if s.ext then GameTooltip:AddLine("данные Auctionator", 0.6, 0.6, 0.6) end
      if not (s.minP or s.qty) then GameTooltip:AddLine("нет данных за этот день", 0.6, 0.6, 0.6) end
      GameTooltip:Show()
    end)
    hit:SetScript("OnLeave", function() hl:Hide(); GameTooltip:Hide() end)
    card.hits[i] = hit
  end
  card.empty = plot:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  card.empty:SetPoint("CENTER")
  card.empty:SetWidth(PW - 40)
  card.empty:SetText("Истории пока нет. Сканируй аукцион в разные дни, и график заполнится. "
    .. "Если стоит Auctionator, его история подтянется сама.")

  card.summary = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  card.summary:SetPoint("TOPLEFT", 14, -(124 + PH + 22))
  card.summary:SetWidth(500)
  card.summary:SetJustifyH("LEFT")
  card.summary:SetSpacing(4)

  card.whereTitle = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  card.whereTitle:SetText("Где добывать (лучшее для тебя сверху)")
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
    q:SetText(hasQ and tostring(floor(qHi * frac + 0.5)) or "")
  end
  local xi = { 1, floor(DAYS / 2) + 1, DAYS }
  for k = 1, 3 do
    local s = series[xi[k]]
    local lbl = card.xLabels[k]
    lbl:ClearAllPoints()
    lbl:SetPoint("TOP", card.plot, "BOTTOMLEFT", (xi[k] - 0.5) * bw, -3)
    lbl:SetText(k == 3 and "сегодня" or date("%d.%m", s.t))
  end
  return ownDays, extDays
end

local function sourceLines(row)
  local lines = {}
  local id = row.id
  for i = 1, min(6, #row.sources) do
    local s = row.sources[i]
    local head = string.format("%s  %s", (ns.DiffLabel(s.mult)), ns.WhereText(s, id))
    if s.note and s.note ~= "" then head = head .. "  |cffff9a50" .. s.note .. "|r" end
    lines[#lines + 1] = head
    if s.kind == "npc" then
      local names = {}
      for j = 1, min(4, #s.npcs) do
        local npcID = s.npcs[j]
        local n = ns.GEN.npcs[npcID]
        local c, csrc, corpses = ns.DropChance(id, npcID)
        names[#names + 1] = string.format("%s %s%s%s", ns.NpcName(npcID), rangeText(n[1], n[2]),
          (n[3] == 1 or n[3] == 2) and " |cffff8080элита|r" or "",
          c and (" " .. ns.ChanceText(c, csrc, corpses)) or "")
      end
      if #s.npcs > 4 then names[#names + 1] = "и ещё " .. (#s.npcs - 4) end
      lines[#lines + 1] = "      |cffc8c8c8" .. table.concat(names, ", ") .. "|r"
    elseif s.kind == "rule" then
      lines[#lines + 1] = string.format("      |cffc8c8c8любые %s этих уровней в зоне|r",
        s.ct == "beast" and "звери" or "гуманоиды")
    elseif s.kind == "world" then
      lines[#lines + 1] = "      |cffc8c8c8мировой дроп: любые мобы этих уровней|r"
    end
  end
  if #row.sources == 0 then
    lines[#lines + 1] = "|cffff6060Сейчас добыть не выйдет: уровень, навык или профессия. "
      .. "Включи «Показать опасное и недоступное», чтобы увидеть всё.|r"
  end
  return table.concat(lines, "\n")
end

local function drawCard(id)
  ns.Compute()
  local row = ns.rowById and ns.rowById[id]
  card.itemID = id
  card.icon:SetTexture(ns.ItemIcon(id))
  local name = ns.ItemName(id) or ("item " .. id)
  local q = ns.ItemQuality(id)
  local color = (q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] and ITEM_QUALITY_COLORS[q].hex) or "|cffffffff"
  card.title:SetText(color .. name .. "|r")
  local meta = ns.Meta(id)
  card.sub:SetText("|cffa0a0a0" .. (ns.CATS[meta.c] and ns.CATS[meta.c].label or "") ..
    (ns.db.pins[id] and "   закреплено" or "") .. (ns.mapSel[id] and "   на карте" or "") .. "|r")
  card.mapBtn:SetText(ns.mapSel[id] and "Убрать с карты" or "На карте")
  card.mapBtn:SetWidth(ns.mapSel[id] and 120 or 90)
  card.pinBtn:SetText(ns.db.pins[id] and "Открепить" or "Закрепить")

  local stats = {}
  if row then
    stats[#stats + 1] = string.format("Цена: %s      На аукционе: %s      Спрос: %s",
      priceText(row, 14) or "—", row.qty and tostring(row.qty) or "—", row.dem.label)
    local second = string.format("Сложность: %s", (ns.DiffLabel(row.best and row.best.mult)))
    local ch = chanceOf(row)
    if ch then second = second .. "      Шанс: " .. ch end
    if row.gph then second = second .. "      ~Доход: " .. ns.Money(row.gph, 14) .. " /ч" end
    stats[#stats + 1] = second
  end
  card.stats:SetText(table.concat(stats, "\n"))

  local ownDays, extDays = drawChart(id)
  local _, dem = ns.Demand(id)
  local lines = {}
  if dem.none then
    lines[#lines + 1] = "Данных о цене пока нет."
  else
    lines[#lines + 1] = string.format("Мин. цена: сейчас %s, обычно %s (медиана 7 дн.), %s",
      ns.Money(dem.pMin), dem.refP and ns.Money(dem.refP) or "—",
      dem.refP and (dem.pMin and pct(dem.trend) or "—") or "нужно 2+ дня истории")
    if dem.q then
      lines[#lines + 1] = string.format("На аукционе: сейчас %d шт, обычно %s, %s", dem.q,
        dem.refQ and (floor(dem.refQ + 0.5) .. " шт") or "—",
        (dem.refQ and dem.refQ > 0) and pct(dem.q / dem.refQ) or "нужно 2+ дня истории")
    end
    if dem.perDay then
      lines[#lines + 1] = string.format("Уходит с аукциона: ~%d шт/день |cff909090(по твоим сканам: продажи и снятые лоты)|r",
        floor(dem.perDay + 0.5))
    else
      lines[#lines + 1] = "|cff909090Скорость продаж: нужно несколько твоих сканов с разницей в пару часов.|r"
    end
  end
  lines[#lines + 1] = string.format("|cff909090Источник истории: твои сканы %d дн.%s|r", ownDays,
    extDays > 0 and (", Auctionator " .. extDays .. " дн.") or "")
  card.summary:SetText(table.concat(lines, "\n"))

  card.whereTitle:ClearAllPoints()
  card.whereTitle:SetPoint("TOPLEFT", card.summary, "BOTTOMLEFT", 0, -14)
  card.where:ClearAllPoints()
  card.where:SetPoint("TOPLEFT", card.whereTitle, "BOTTOMLEFT", 0, -6)
  card.where:SetText(row and sourceLines(row) or "")
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
      ns.Print("пометки на мобах %s", ns.S.enabled and "|cff00ff00включены|r" or "|cffff4040выключены|r")
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
    GameTooltip:AddLine("ЛКМ — список «что фармить»", 1, 1, 1)
    GameTooltip:AddLine("ПКМ — пометки на мобах: " .. (ns.S.enabled and "|cff00ff00вкл|r" or "|cffff4040выкл|r"), 1, 1, 1)
    GameTooltip:AddLine("Перетащи, чтобы подвинуть", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  mmb:SetScript("OnLeave", GameTooltip_Hide)
  ns.Minimap_Update()
end

function ns.UI_Init()
  createMinimapButton()
end
