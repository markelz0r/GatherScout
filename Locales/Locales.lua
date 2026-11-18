-- GatherScout localization core.
-- Keys are the English (enUS) texts, so a missing translation simply shows English.
-- Each Locales/<locale>.lua fills ns.L only when the client runs in that language.
-- Game names never go through here: items and zones come from the client (GetItemInfo, C_Map),
-- mobs, gathering nodes and fishing schools from Data/Names/<locale>.lua (generated from QuestieDB by ID).
local _, ns = ...

local LOCALE = GetLocale and GetLocale() or "enUS"
if LOCALE == "enGB" then LOCALE = "enUS" end
ns.LOCALE = LOCALE

local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L

---------------------------------------------------------------- plurals
-- A phrase with a count is a list of forms; the rule picks one by the number.
local RULES = {
  ruRU = function(n)
    local n10, n100 = n % 10, n % 100
    if n10 == 1 and n100 ~= 11 then return 1 end
    if n10 >= 2 and n10 <= 4 and (n100 < 12 or n100 > 14) then return 2 end
    return 3
  end,
  frFR = function(n) return n <= 1 and 1 or 2 end,
  ptBR = function(n) return n <= 1 and 1 or 2 end,
  koKR = function() return 1 end,
  zhCN = function() return 1 end,
  zhTW = function() return 1 end,
}
local function defaultRule(n) return n == 1 and 1 or 2 end

-- English forms of the phrases with a count (other languages override them in L)
ns.L_PLURAL = {
  ["%d more mobs — hover to see all"] = { "%d more mob — hover to see all", "%d more mobs — hover to see all" },
  ["%d more places — hover"] = { "%d more place — hover", "%d more places — hover" },
  ["%d more places, less convenient for you"] = { "%d more place, less convenient for you",
    "%d more places, less convenient for you" },
  ["%d mobs in the zone, best for you on top:"] = { "%d mob in the zone:", "%d mobs in the zone, best for you on top:" },
  ["History source: your scans, %d days"] = { "History source: your scans, %d day", "History source: your scans, %d days" },
  ["another addon, %d days"] = { "another addon, %d day", "another addon, %d days" },
  ["%d items"] = { "%d item", "%d items" },
}

-- ns.LP(key, n, ...): the phrase for count n, formatted with n and the extra arguments
function ns.LP(key, n, ...)
  local v = rawget(L, key) or ns.L_PLURAL[key] or key
  if type(v) == "table" then
    local i = (RULES[LOCALE] or defaultRule)(math.abs(math.floor(n)))
    v = v[i] or v[#v]
  end
  return string.format(v, n, ...)
end

-- Colored on / off word for settings
function ns.OnOff(v)
  return v and ("|cff00ff00" .. L["on"] .. "|r") or ("|cffff4040" .. L["off"] .. "|r")
end

---------------------------------------------------------------- numbers
local DEC = (type(DECIMAL_SEPERATOR) == "string" and DECIMAL_SEPERATOR ~= "") and DECIMAL_SEPERATOR or "."

-- Whole number with the client's thousands separator (1,234 / 1.234 / 1 234)
function ns.Num(n)
  if not n then return "—" end
  n = math.floor(n + 0.5)
  if BreakUpLargeNumbers then
    local ok, s = pcall(BreakUpLargeNumbers, n)
    if ok and s then return s end
  end
  return tostring(n)
end

-- Number with a fixed number of decimals and the client's decimal separator
function ns.Dec(fmt, x)
  local s = string.format(fmt, x)
  if DEC ~= "." then s = s:gsub("%.", DEC) end
  return s
end
