-- GatherScout mob marking: an icon next to the nameplate health bar and on the target frame for mobs that
-- drop (or can be skinned for) items that are in demand, plus lines in the mob tooltip.
-- Everything is off inside instances (WoW Forever restricts unit data there).
local _, ns = ...
local L = ns.L

---------------------------------------------------------------- shared helpers
local function shouldShow(list)
  return list and list[1] and list[1].hot and not list[1].low
end

local function healthBar(plate)
  local uf = plate.UnitFrame
  if not uf then return nil end
  return uf.healthBar or (uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar) or uf.HealthBar
end

-- Chance colored by source: white = wowhead (Questie), light blue = classic data (CMaNGOS), green = your kills
ns.CHANCE_COLOR = { db = "|cffffffff", classic = "|cff8cc8ff", learned = "|cff66ff66" }
ns.UNKNOWN_CHANCE = "|cff909090??|r" -- a drop whose chance nobody knows yet

-- Chance text; `unknown` = show "??" instead of nothing when the chance is not known
function ns.ChanceText(pct, src, unknown)
  if not pct then return unknown == true and ns.UNKNOWN_CHANCE or "" end
  local txt
  if pct >= 10 then txt = string.format("%d%%", math.floor(pct + 0.5))
  elseif pct >= 1 then txt = ns.Dec("%.1f%%", pct)
  elseif pct >= 0.1 then txt = ns.Dec("%.2f%%", pct)
  else txt = ns.Dec("%.3f%%", pct) end
  return (ns.CHANCE_COLOR[src] or "|cffffffff") .. txt .. "|r"
end

---------------------------------------------------------------- nameplates
-- right: past the level badge at the end of the bar (Questie draws on the left)
local POSITIONS = {
  right = function(f, bar, x, y) f:SetPoint("LEFT", bar, "RIGHT", 31 + x, y) end,
  top   = function(f, bar, x, y) f:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", x, 16 + y) end,
  left  = function(f, bar, x, y) f:SetPoint("RIGHT", bar, "LEFT", -4 + x, y) end,
}

local function plateIcon(plate)
  local f = plate.GatherScoutIcon
  if not f then
    f = CreateFrame("Frame", nil, plate)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(10)
    f:EnableMouse(false)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    plate.GatherScoutIcon = f
  end
  local S = ns.S
  f:SetSize(S.npSize, S.npSize)
  f:ClearAllPoints()
  local ok, bar = pcall(healthBar, plate)
  local place = POSITIONS[S.npPos] or POSITIONS.right
  if ok and bar then
    place(f, bar, S.npX, S.npY)
  else
    place(f, plate, S.npX, S.npY)
  end
  return f
end

local function updatePlate(unit)
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if not plate then return end
  local S = ns.S
  local f = plate.GatherScoutIcon
  if not (S and S.enabled and S.nameplates) or IsInInstance() then
    if f then f:Hide() end
    return
  end
  local ok, list = pcall(ns.UnitMaterials, unit)
  if ok and shouldShow(list) then
    f = plateIcon(plate)
    f.tex:SetTexture(ns.ItemIcon(list[1].id))
    f:Show()
  elseif f then
    f:Hide()
  end
end

ns.On("NAME_PLATE_UNIT_ADDED", updatePlate)
ns.On("NAME_PLATE_UNIT_REMOVED", function(unit)
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if plate and plate.GatherScoutIcon then plate.GatherScoutIcon:Hide() end
end)

---------------------------------------------------------------- target frame
local tIcon

local function targetParent()
  return _G.ElvUF_Target or _G.SUFUnittarget or _G.PitBull4_Frames_Target or _G.XPerl_Target or TargetFrame
end

local function updateTarget()
  local S = ns.S
  if not (S and S.enabled and S.targetIcon) or IsInInstance() or not UnitExists("target") then
    if tIcon then tIcon:Hide() end
    return
  end
  local ok, list = pcall(ns.UnitMaterials, "target")
  if not (ok and shouldShow(list)) then
    if tIcon then tIcon:Hide() end
    return
  end
  local parent = targetParent()
  if not tIcon then
    tIcon = CreateFrame("Frame", "GatherScoutTargetIcon", parent)
    tIcon:SetFrameStrata("MEDIUM")
    tIcon:SetFrameLevel(12)
    tIcon.tex = tIcon:CreateTexture(nil, "ARTWORK")
    tIcon.tex:SetAllPoints()
    tIcon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    tIcon:EnableMouse(true)
    tIcon:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("GatherScout")
      ns.AddUnitLines(GameTooltip, "target", true)
      GameTooltip:Show()
    end)
    tIcon:SetScript("OnLeave", GameTooltip_Hide)
  end
  if tIcon:GetParent() ~= parent then tIcon:SetParent(parent) end
  tIcon:SetSize(S.tfSize, S.tfSize)
  tIcon:ClearAllPoints()
  tIcon:SetPoint("RIGHT", parent, "RIGHT", S.tfX, S.tfY)
  tIcon.tex:SetTexture(ns.ItemIcon(list[1].id))
  tIcon:Show()
end

ns.On("PLAYER_TARGET_CHANGED", updateTarget)

---------------------------------------------------------------- tooltip lines
-- Column alignment: names are padded with spaces to the widest one so chances line up; the right side
-- (hot star, price, demand dot) is right-justified by the tooltip itself.
local HOT_STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t "
local measureFS

local function measureWith(tt)
  if not measureFS then
    measureFS = UIParent:CreateFontString(nil, "BACKGROUND")
    measureFS:SetAlpha(0)
  end
  local ref = _G[((tt.GetName and tt:GetName()) or "GameTooltip") .. "TextLeft2"]
  local font, size, flags
  if ref and ref.GetFont then font, size, flags = ref:GetFont() end
  if font then measureFS:SetFont(font, size, flags) elseif GameTooltipText then measureFS:SetFontObject(GameTooltipText) end
end

local function textWidth(str)
  measureFS:SetText(str)
  return measureFS:GetStringWidth() or 0
end

-- rows: { name = "icon + name", extra = "chance or note" or "", right = "right column" }
local function addAligned(tt, rows)
  measureWith(tt)
  local maxw = 0
  for _, r in ipairs(rows) do
    r.w = textWidth(r.name)
    if r.extra ~= "" and r.w > maxw then maxw = r.w end
  end
  local space = textWidth("a a") - textWidth("aa")
  if space <= 0.5 then space = 3 end
  for _, r in ipairs(rows) do
    local left = r.name
    if r.extra ~= "" then
      left = left .. string.rep(" ", math.max(1, math.floor((maxw - r.w) / space + 0.5)) + 2) .. r.extra
    end
    tt:AddDoubleLine(left, r.right)
  end
end

-- force = show even when tooltips are switched off (used by the target icon's own tooltip)
function ns.AddUnitLines(tt, unit, force)
  local S = ns.S
  if not S or IsInInstance() then return end
  if not force and not (S.enabled and S.tooltips) then return end
  local ok, list, _, _, others = pcall(ns.UnitMaterials, unit)
  if not ok or not list then return end
  -- the tooltip lists the most likely drops first ("??" last; what your skill can't skin yet at the bottom);
  -- the nameplate / target icon keeps the most valuable one (UnitMaterials' own order)
  local sorted = {}
  for i, e in ipairs(list) do sorted[i] = e end
  table.sort(sorted, function(a, b)
    if (a.low and 1 or 0) ~= (b.low and 1 or 0) then return not a.low end
    local ca, cb = a.chance or -1, b.chance or -1
    if ca ~= cb then return ca > cb end
    local ah, bh = a.hot or 1000, b.hot or 1000
    if ah ~= bh then return ah < bh end
    return (ns.Price(a.id) or 0) > (ns.Price(b.id) or 0)
  end)
  local rows = {}
  for _, e in ipairs(sorted) do
    if #rows >= 6 then break end
    local row = ns.rowById and ns.rowById[e.id]
    local name = ns.ItemName(e.id) or string.format(L["item %d"], e.id)
    local extra = ""
    if e.low then
      extra = "|cffff6060" .. string.format(L["needs %d skill"], e.req or 0) .. "|r"
    else
      extra = ns.ChanceText(e.chance, e.chanceSrc, true)
    end
    local price = ns.Price(e.id)
    local right = (e.hot and HOT_STAR or "") .. (price and ns.Money(price) or "")
    if row and row.dem then right = right .. ns.DemandTip(row.dem) end
    rows[#rows + 1] = { name = string.format("|T%d:0|t %s%s|r", ns.ItemIcon(e.id),
      e.hot and "|cff7fd4ff" or "|cffd8d8d8", name), extra = extra, right = right }
  end
  addAligned(tt, rows)
  local shown = #rows
  if #list > shown then tt:AddLine("|cff909090" .. string.format(L["…and %d more"], #list - shown) .. "|r") end
  if others and #others > 0 then
    local names = {}
    for i = 1, math.min(6, #others) do names[#names + 1] = ns.ItemName(others[i]) or string.format(L["item %d"], others[i]) end
    if #others > 6 then names[#names + 1] = "…" end
    tt:AddLine("|cff909090" .. string.format(L["Also drops (not seen on the AH): %s"], table.concat(names, ", ")) .. "|r",
      1, 1, 1, true)
  end
end

local function onUnitTooltip(tt, data)
  if tt ~= GameTooltip or IsInInstance() then return end
  local unit = "mouseover"
  if data and data.guid ~= nil then
    local dg = ns.Pub(data.guid)
    if not dg then return end
    local mg = ns.Pub(UnitGUID("mouseover"))
    if mg ~= dg then
      local tg = ns.Pub(UnitGUID("target"))
      if tg == dg then unit = "target" else return end
    end
  elseif not ns.Pub(UnitGUID("mouseover")) then
    return
  end
  ns.AddUnitLines(tt, unit)
end

---------------------------------------------------------------- gathering node tooltips (herbs / veins)
local nodeByName, itemsByNode

local function nodeIndex()
  if nodeByName then return end
  nodeByName, itemsByNode = {}, {}
  for en in pairs(ns.GEN.nodeInfo or {}) do nodeByName[en] = en end
  -- node names in the client's language (Data/Names/<locale>.lua, generated from QuestieDB by object ID)
  for name, en in pairs(ns.GEN.nodeL or {}) do nodeByName[name] = en end
  for itemID, ni in pairs(ns.GEN.nodeItems) do
    for _, n in ipairs(ni.nodes or {}) do
      local t = itemsByNode[n]
      if not t then t = {}; itemsByNode[n] = t end
      t[#t + 1] = itemID
    end
  end
  -- fishing schools: what they give (Data/Fishing.lua)
  for itemID, f in pairs(ns.GEN.fish or {}) do
    local seen = {}
    for _, per in pairs(f.p or {}) do
      for pool in pairs(per) do
        if not seen[pool] then
          seen[pool] = true
          nodeByName[pool] = pool
          local t = itemsByNode[pool]
          if not t then t = {}; itemsByNode[pool] = t end
          t[#t + 1] = itemID
        end
      end
    end
  end
end

-- Lines for a node tooltip: what it gives (main product first, then by-products), price, demand, skill.
function ns.AddNodeLines(tt, name)
  nodeIndex()
  local en = nodeByName[name]
  if not en then return false end
  ns.Compute()
  local info = ns.GEN.nodeInfo[en]
  local list = {}
  for _, id in ipairs(itemsByNode[en] or {}) do
    if ns.MAT[id] then list[#list + 1] = id end
  end
  if #list == 0 then return false end
  table.sort(list, function(a, b)
    local ra, rb = ns.MAT[a].r, ns.MAT[b].r
    if ra ~= rb then return ra > rb end
    return (ns.Price(a) or 0) > (ns.Price(b) or 0)
  end)
  local profKey = ns.CATS[ns.MAT[list[1]].c].prof
  local ctx = ns.ctx or ns.Context()
  local have = profKey and ctx.profs[profKey]
  if info and info.skill and info.skill > 1 and (not have or have < info.skill) then
    tt:AddLine(have and string.format(L["Needs %d skill (you have %d)"], info.skill, have)
      or string.format(L["Needs %d skill"], info.skill), 1, 0.4, 0.4)
  end
  local rows = {}
  for i = 1, math.min(6, #list) do
    local id = list[i]
    local row = ns.rowById and ns.rowById[id]
    local hot = ns.hot and ns.hot[id]
    local price = ns.Price(id)
    local right = (hot and HOT_STAR or "") .. (price and ns.Money(price) or "")
    if row and row.dem then right = right .. ns.DemandTip(row.dem) end
    rows[#rows + 1] = {
      name = string.format("|T%d:0|t %s%s|r", ns.ItemIcon(id), hot and "|cff7fd4ff" or "|cffd8d8d8",
        ns.ItemName(id) or string.format(L["item %d"], id)),
      extra = (ns.MAT[id].r <= 0.15 and i > 1) and ("|cff909090" .. L["sometimes"] .. "|r") or "",
      right = right,
    }
  end
  addAligned(tt, rows)
  return true
end

local function pubTable(v)
  if ns.Pub(v) == nil then return false end
  return type(v) == "table" and not (_G.issecrettable and _G.issecrettable(v))
end

local objAugmented = false
local function onObjectTooltip(tt, data)
  if tt ~= GameTooltip or objAugmented or IsInInstance() then return end
  local S = ns.S
  if not (S and S.enabled and S.tooltips) then return end
  if not pubTable(data) then return end
  if tt.GetPrimaryTooltipData then
    local primary = tt:GetPrimaryTooltipData()
    if not pubTable(primary) or primary ~= data then return end
  end
  if not pubTable(data.lines) or not pubTable(data.lines[1]) then return end
  local name = ns.Pub(data.lines[1].leftText)
  if type(name) ~= "string" or name == "" then return end
  if ns.AddNodeLines(tt, name) then objAugmented = true end
end

---------------------------------------------------------------- init / refresh
function ns.Mobs_RefreshAll()
  if C_NamePlate and C_NamePlate.GetNamePlates then
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
      local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
      if unit then pcall(updatePlate, unit) end
    end
  end
  pcall(updateTarget)
end

function ns.Mobs_Init()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt, data)
      pcall(onUnitTooltip, tt, data)
    end)
    if Enum.TooltipDataType.Object then
      GameTooltip:HookScript("OnTooltipCleared", function() objAugmented = false end)
      TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Object, function(tt, data)
        pcall(onObjectTooltip, tt, data)
      end)
    end
  else
    if GameTooltip:HasScript("OnTooltipSetUnit") then
      GameTooltip:HookScript("OnTooltipSetUnit", function(tt) pcall(onUnitTooltip, tt, nil) end)
    end
    -- older clients: world object tooltips have no data type, read the first line
    GameTooltip:HookScript("OnShow", function(tt)
      if tt:GetUnit() or tt:GetItem() or IsInInstance() then return end
      local S = ns.S
      if not (S and S.enabled and S.tooltips) then return end
      local first = _G.GameTooltipTextLeft1 and _G.GameTooltipTextLeft1:GetText()
      if not first then return end
      local ok, added = pcall(ns.AddNodeLines, tt, first)
      if ok and added then tt:Show() end
    end)
  end
end

ns.On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1, ns.Mobs_RefreshAll) end)
