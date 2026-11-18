-- GatherScout analysis: where each material comes from, how hard it is for *you*, and how well it sells.
--
--   score (~gold/hour) = price * 0.95 * unitsPerHour(category) * yield / difficulty * demandFactor
--
-- difficulty grows with how far the mobs you must face are above your level (a zone where you kill everything
-- is ~1.0, a zone at your level ~2.0, a few levels above ~3-5), elite mobs, enemy-faction zones,
-- a profession skill that is a bit short, and sparse nodes.
local _, ns = ...
local L = ns.L

local MAT, CATS = ns.MAT, ns.CATS
local EMPTY = {}
local floor, max, min, log = math.floor, math.max, math.min, math.log

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

---------------------------------------------------------------- mob levels
-- Some new mobs have no level in the data (0). Until you see one in game they get the zone's level range,
-- marked as a guess (shown with "~"); the level you see (mouseover, target) is remembered and used from then on.
local function applyLevel(n, lo, hi, guess)
  n[1], n[2], n.guess = lo, hi, guess or nil
end

function ns.FixMobLevels()
  local seen = (ns.db and ns.db.learned and ns.db.learned.levels) or EMPTY
  for id, n in pairs(ns.GEN.npcs) do
    if n.unknown == nil then n.unknown = (n[1] == 0 or n[2] == 0) end
    if n.unknown then
      local s = seen[id]
      if s then
        applyLevel(n, s[1], s[2])
      else
        local lo, hi = ns.ZoneRange(n[4])
        if lo then applyLevel(n, lo, hi, true) end
      end
    end
  end
end

-- Remember the level of a mob without one in the data; true when it changed
function ns.LearnMobLevel(npcID, level)
  local n = ns.GEN.npcs[npcID]
  if not (n and n.unknown and type(level) == "number" and level > 0) then return false end
  local learned = ns.db.learned
  learned.levels = learned.levels or {}
  local s = learned.levels[npcID]
  if s and level >= s[1] and level <= s[2] then return false end
  s = s and { min(s[1], level), max(s[2], level) } or { level, level }
  learned.levels[npcID] = s
  applyLevel(n, s[1], s[2])
  return true
end

---------------------------------------------------------------- indexes
-- MAT = curated gathering materials; DROP = every other tradeable mob drop from the database.
function ns.BuildIndexes()
  ns.FixMobLevels()
  local npcItems, rules, drops = {}, {}, {}
  local function addList(itemID, npcs)
    for _, npcID in ipairs(npcs) do
      local t = npcItems[npcID]
      if not t then t = {}; npcItems[npcID] = t end
      t[#t + 1] = itemID
    end
  end
  for itemID, npcs in pairs(ns.GEN.itemNpcs) do
    if MAT[itemID] then addList(itemID, npcs) end
  end
  for itemID, d in pairs(ns.GEN.drops) do
    if not MAT[itemID] then
      drops[itemID] = { c = ns.DROP_CAT[d.c] or "dgoods", drop = d, r = 0 }
      if d.n then addList(itemID, d.n) end
    elseif MAT[itemID].drop == d and d.n then
      addList(itemID, d.n) -- fish that mobs drop too: those mobs stay marked
    end
  end
  for id, m in pairs(MAT) do
    if m.band then rules[id] = m end
  end
  ns.NPC_ITEMS, ns.RULE_ITEMS, ns.DROP = npcItems, rules, drops
end

function ns.Meta(id)
  return MAT[id] or (ns.DROP and ns.DROP[id])
end

function ns.IsTracked(id)
  return MAT[id] ~= nil or (ns.DROP ~= nil and ns.DROP[id] ~= nil)
end

-- Mob list for an item: gathering specials, general drops, and for leather / cloth the mobs that the loot
-- tables say really drop (or are skinned for) it; nil for node and world-drop items
local ruleLists = {}
function ns.NpcList(id)
  local l = ns.GEN.itemNpcs[id]
  if l then return l end
  local m = MAT[id] or (ns.DROP and ns.DROP[id])
  if m and m.drop and m.drop.n then return m.drop.n end
  local rc = ns.GEN.ruleChance and ns.GEN.ruleChance[id]
  if not rc then return nil end
  l = ruleLists[id]
  if not l then
    l = {}
    for npcID, pct in pairs(rc) do
      -- below 1% it is a rarity, not a place to farm (e.g. wool from murlocs at 0.02%)
      if pct >= 1 and ns.GEN.npcs[npcID] then l[#l + 1] = npcID end
    end
    table.sort(l)
    ruleLists[id] = l
  end
  return l
end

-- Drop chance in % for one mob. Sources, by trust:
--   "db"      wowhead data shipped with Questie
--   "classic" CMaNGOS classic-db (vanilla 1.12 loot tables; also skinning and cloth per mob)
--   "learned" your own kills: blended in gradually (each corpse counts, the database counts as 20 corpses),
--             and used alone once there is no database value and you have 5+ corpses.
-- Skinning items never use own kills (not every looted corpse gets skinned).
-- Returns pct, source, corpses
local BLEND = 20
function ns.DropChance(itemID, npcID)
  local G = ns.GEN
  local prior, src = G.chance[itemID] and G.chance[itemID][npcID], "db"
  if not prior then
    prior = (G.chanceC[itemID] and G.chanceC[itemID][npcID]) or (G.ruleChance[itemID] and G.ruleChance[itemID][npcID])
    src = "classic"
  end
  local m = MAT[itemID]
  if m and m.c == "skin" then return prior, prior and src or nil end
  local learned = ns.db and ns.db.learned
  local kills = learned and learned.kills and learned.kills[npcID]
  if kills and kills > 0 then
    local got = learned.npc[npcID] and learned.npc[npcID][itemID] or 0
    if prior then
      local p = (got + prior / 100 * BLEND) / (kills + BLEND) * 100
      return p, kills >= BLEND and "learned" or src, kills
    elseif kills >= 5 then
      return 100 * got / kills, "learned", kills
    end
  end
  return prior, prior and src or nil
end

-- Assumed chance when nothing is known (per kill, %), used only for ranking
ns.DEFAULT_CHANCE = { dgoods = 8, drecipe = 1, dgear = 3, fish = 8 }
ns.DEFAULT_WORLD_CHANCE = { dgoods = 1, drecipe = 0.03, dgear = 0.05, fish = 1 }

---------------------------------------------------------------- zones / levels
function ns.ZoneRange(mapID)
  if not mapID then return nil end
  local o = ns.ZONE_LEVELS[mapID]
  if o then return o[1], o[2] end
  local g = ns.GEN.zones[mapID]
  if g and g[1] then return g[1], g[2] end
  return nil
end

function ns.ZoneFaction(mapID)
  local g = ns.GEN.zones[mapID]
  return g and g[4] or "C"
end

local DANGER = { { -10, 1.0 }, { -6, 1.15 }, { -3, 1.45 }, { 0, 2.0 }, { 2, 2.6 }, { 4, 3.6 }, { 6, 5.0 }, { 10, 8.0 } }
function ns.DangerMult(d)
  if d <= DANGER[1][1] then return DANGER[1][2] end
  for i = 2, #DANGER do
    local a, b = DANGER[i - 1], DANGER[i]
    if d <= b[1] then return a[2] + (b[2] - a[2]) * (d - a[1]) / (b[1] - a[1]) end
  end
  return DANGER[#DANGER][2] + (d - DANGER[#DANGER][1]) * 0.8
end

-- Skinning skill needed for a mob of this level (classic formula)
function ns.SkinReq(level)
  if level <= 10 then return 1 elseif level <= 20 then return (level - 10) * 10 end
  return level * 5
end

function ns.DiffLabel(mult)
  if not mult then return "|cff808080—|r", 0 end
  if mult <= 1.15 then return "|cff40ff40" .. L["trivial"] .. "|r", 1 end
  if mult <= 1.6 then return "|cffa0ff40" .. L["easy"] .. "|r", 2 end
  if mult <= 2.4 then return "|cffffff40" .. L["medium"] .. "|r", 3 end
  if mult <= 3.6 then return "|cffff9020" .. L["hard"] .. "|r", 4 end
  return "|cffff3030" .. L["dangerous"] .. "|r", 5
end

-- The same five difficulty colors as DiffLabel, as r, g, b (map pin frames); grey when unknown
local DIFF_RGB = { { 0.25, 1, 0.25 }, { 0.63, 1, 0.25 }, { 1, 1, 0.25 }, { 1, 0.56, 0.13 }, { 1, 0.19, 0.19 } }
function ns.DiffColor(mult)
  local _, level = ns.DiffLabel(mult)
  local c = DIFF_RGB[level]
  if not c then return 0.5, 0.5, 0.5 end
  return c[1], c[2], c[3]
end

---------------------------------------------------------------- sources
local function skillCheck(cat, req, ctx, S)
  local prof = CATS[cat].prof
  if not prof then return 1.0 end
  local have = ctx.profs[prof]
  if not have then
    if S.onlyMyProfs then return nil end
    return 1.5, string.format(L["no profession: %s"], ns.PROF_LABEL[prof] or prof)
  end
  req = req or 1
  if have >= req then return 1.0 end
  local gap = req - have
  if gap <= 25 then return 1.4, string.format(L["needs %d skill (you have %d)"], req, have) end
  if S.showDangerous then return 3.0, string.format(L["needs %d skill (you have %d)"], req, have) end
  return nil
end

-- Fishing: a cast catches something with chance (your skill - zone skill + 5)% (the rest "got away"),
-- so there are no getaways from zone skill + 95. Sets src.success; a low catch rate makes the place worth less.
local function fishCheck(src, ctx, S)
  local have = ctx.profs.fish
  if not have then
    if S.onlyMyProfs then return nil end
    src.success = clamp((1 - src.zs + 5) / 100, 0, 1)
    local note = string.format(L["no profession: %s"], ns.PROF_LABEL.fish)
    return 1.5, note, note
  end
  local success = clamp((have - src.zs + 5) / 100, 0, 1)
  src.success = success
  if success <= 0 then
    if not S.showDangerous then return nil end
    local note = string.format(L["needs %d skill (you have %d)"], src.zs - 4, have)
    return 3.0, note, note
  end
  if success < 1 then return 1.0, nil, string.format(L["bite %d%%"], floor(success * 100 + 0.5)) end
  return 1.0
end

local function finalize(list, src, m, ctx, S)
  local d = src.eff - ctx.level
  if (src.minEff or src.eff) - ctx.level > S.maxAbove and not S.showDangerous then return end
  local mult = ns.DangerMult(d)
  -- notes = full wording (tooltips, map), tags = short form for the card's one-line source rows
  local notes, tags = {}, {}
  if src.elite then
    mult = mult * 3
    notes[#notes + 1] = L["elite mobs"]
    tags[#tags + 1] = L["elite"]
  end
  local fac = ns.ZoneFaction(src.map)
  if (fac == "A" and ctx.faction == "Horde") or (fac == "H" and ctx.faction == "Alliance") then
    mult = mult * 1.6
    notes[#notes + 1] = L["enemy faction territory"]
    src.enemy = true -- shown as the zone name in orange (card, list), the full note goes to tooltips
  end
  local sm, snote = skillCheck(m.c, src.req, ctx, S)
  if not sm then return end
  mult = mult * sm
  if snote then
    notes[#notes + 1] = snote
    tags[#tags + 1] = snote
  end
  if src.kind == "fish" then
    local fm, fnote, ftag = fishCheck(src, ctx, S)
    if not fm then return end
    mult = mult * fm
    if fnote then notes[#notes + 1] = fnote end
    if ftag then tags[#tags + 1] = ftag end
    src.density = (src.density or 1) * max(0.05, src.success or 0)
  end
  if src.density then mult = mult / (0.45 + 0.55 * src.density) end
  src.d = d
  src.mult = mult
  src.note = table.concat(notes, ", ")
  src.tags = tags
  list[#list + 1] = src
end

-- All the places/mobs you can get item `id` from, best (lowest difficulty) first.
function ns.Sources(id, ctx)
  local m = ns.Meta(id)
  local S = ns.S
  local list = {}
  local lvl = ctx.level
  local seenZone = {}

  -- 1) gathering nodes by zone
  local node = ns.GEN.nodeItems[id]
  local zones = (node and node.zones) or m.zones
  local req = (node and node.skill) or m.skill
  if zones then
    local maxc = 0
    for _, c in pairs(zones) do if c > maxc then maxc = c end end
    for map, c in pairs(zones) do
      local lo, hi = ns.ZoneRange(map)
      if lo then
        -- You gather in the parts of the zone up to ~your level; higher parts are skipped (fewer nodes).
        local reach = lvl + min(2, S.maxAbove)
        local access = clamp((reach - lo) / max(1, hi - lo), 0, 1)
        local eff = min((lo + hi) / 2, max(lo, reach))
        if access <= 0 then eff = (lo + hi) / 2 end
        local density = (maxc > 0 and c / maxc or 0.5) * (0.4 + 0.6 * access)
        seenZone[map] = true
        finalize(list, { kind = "zone", map = map, lo = lo, hi = hi, eff = eff, minEff = lo, req = req,
          density = density, guess = m.guess }, m, ctx, S)
      end
    end
  end

  -- 1b) fishing: per zone the spot where it bites best (the zone itself or a coast / lake inside it), and
  --     schools with known places; the share of the catch counts like node density
  local fish = ns.GEN.fish and ns.GEN.fish[id]
  if fish then
    local maxp = 0
    for _, z in pairs(fish.z) do if z[1] > maxp then maxp = z[1] end end
    for _, per in pairs(fish.p or EMPTY) do
      for _, p in pairs(per) do if p > maxp then maxp = p end end
    end
    local reach = lvl + min(2, S.maxAbove)
    local function addFish(map, pct, zs, area, pool, spread)
      local lo, hi = ns.ZoneRange(map)
      if not (lo and zs) then return end
      seenZone[map] = true
      finalize(list, { kind = "fish", map = map, lo = lo, hi = hi, eff = min((lo + hi) / 2, max(lo, reach)), minEff = lo,
        chance = pct, chanceSrc = "classic", zs = zs, area = (area and area > 0) and area or nil, pool = pool,
        density = (maxp > 0 and pct / maxp or 0.5) * spread }, m, ctx, S)
    end
    for map, z in pairs(fish.z) do addFish(map, z[1], z[2], z[3], nil, 1) end
    -- schools are few and move around: you travel between them
    for map, per in pairs(fish.p or EMPTY) do
      for pool, p in pairs(per) do addFish(map, p, ns.GEN.fishSkill[map], nil, pool, 0.6) end
    end
  end

  -- 2) specific mobs (drops / skinning), grouped by zone; the "focus" mob is the best one for you
  local npcs = ns.NpcList(id)
  if npcs then
    local byZone = {}
    local maxSp = 0
    for _, npcID in ipairs(npcs) do
      local n = ns.GEN.npcs[npcID]
      if n and n[3] ~= 3 then -- skip bosses
        local z = byZone[n[4]]
        if not z then z = { npcs = {}, sp = 0 }; byZone[n[4]] = z end
        z.npcs[#z.npcs + 1] = npcID
        z.sp = z.sp + n[5]
        if z.sp > maxSp then maxSp = z.sp end
      end
    end
    local function value(npcID)
      local n = ns.GEN.npcs[npcID]
      local elite = (n[3] == 1 or n[3] == 2) and 3 or 1
      return (n[5] + 1) / (ns.DangerMult(n[1] - lvl) * elite)
    end
    for map, z in pairs(byZone) do
      table.sort(z.npcs, function(a, b) return value(a) > value(b) end)
      local focus = ns.GEN.npcs[z.npcs[1]]
      local lo, hi = focus[1], focus[2]
      local elite = focus[3] == 1 or focus[3] == 2
      local sreq
      if m.c == "skin" then sreq = ns.SkinReq(lo) end
      -- drop chance: the focus mob's, else the median of the known ones in this zone
      local chance, csrc, corpses = ns.DropChance(id, z.npcs[1])
      if not chance then
        local known = {}
        for _, npcID in ipairs(z.npcs) do
          local c, s = ns.DropChance(id, npcID)
          if c then known[#known + 1] = { c, s } end
        end
        if #known > 0 then
          table.sort(known, function(a, b) return a[1] < b[1] end)
          local mid = known[floor((#known + 1) / 2)]
          chance, csrc = mid[1], mid[2]
        end
      end
      finalize(list, { kind = "npc", map = map, lo = lo, hi = hi, eff = lo, req = sreq, elite = elite, lvGuess = focus.guess,
        npcs = z.npcs, chance = chance, chanceSrc = csrc, corpses = corpses,
        density = maxSp > 0 and (0.3 + 0.7 * z.sp / maxSp) or 0.6 }, m, ctx, S)
      seenZone[map] = true
    end
  end

  -- 2b) world drops: any mob in a level band, in the zones where most droppers live
  local w = m.drop and m.drop.w
  if w then
    local maxc = 0
    for _, c in pairs(m.drop.z) do if c > maxc then maxc = c end end
    for map, c in pairs(m.drop.z) do
      local zlo, zhi = ns.ZoneRange(map)
      if zlo then
        local L, top = max(w[1], zlo), min(w[2], zhi)
        if L <= top then
          finalize(list, { kind = "world", map = map, lo = L, hi = top, eff = L,
            density = 0.35 + 0.65 * (maxc > 0 and c / maxc or 0.5), chance = m.drop.ch,
            chanceSrc = m.drop.ch and (m.drop.cs == "c" and "classic" or "db") }, m, ctx, S)
          seenZone[map] = true
        end
      end
    end
  end

  -- 3) rule-based: any beast / humanoid in the level band, only for zones where no mob of the loot tables is
  --    known (section 2 already lists the real mobs with their chances there)
  if m.band then
    local bLo, bHi = m.band[1], m.band[2]
    for map in pairs(ns.GEN.zones) do
      local zlo, zhi = ns.ZoneRange(map)
      if zlo then
        local L = max(bLo, zlo)
        local top = min(bHi, zhi)
        if L <= top and not seenZone[map] then
          local overlap = (top - L + 1) / (zhi - zlo + 1)
          local sreq
          if m.c == "skin" then sreq = ns.SkinReq(L) end
          finalize(list, { kind = "rule", map = map, lo = L, hi = top, eff = L, req = sreq, ct = m.ct,
            density = 0.35 + 0.65 * clamp(overlap, 0, 1) }, m, ctx, S)
          seenZone[map] = true
        end
      end
    end
  end

  -- 4) learned from your own loot (covers Forever zones the database does not know yet)
  for map, items in pairs(ns.db.learned.zone) do
    if items[id] and not seenZone[map] then
      local lo, hi = ns.ZoneRange(map)
      if lo then
        finalize(list, { kind = "zone", map = map, lo = lo, hi = hi, eff = (lo + hi) / 2, minEff = lo,
          req = req, density = 0.5, learned = true }, m, ctx, S)
      end
    end
  end

  table.sort(list, function(a, b) return a.mult < b.mult end)
  return list
end

---------------------------------------------------------------- prices & demand
function ns.MarketRec(id)
  return ns.Market().items[id]
end

-- price, quantity on AH, timestamp, source ("scan" | "last")
-- Price = lowest unit buyout from our own scans only (the same way Auctionator computes its AH price).
-- Other addons are never used as a price source; Auctionator is only read for optional daily history.
function ns.Price(id)
  local r = ns.MarketRec(id)
  if r and r.p then return r.p, r.q, r.t, "scan" end
  if r and r.lp then return r.lp, r.q, r.t, "last" end
  return nil, r and r.q, r and r.t, nil
end

local function median(t)
  if #t == 0 then return nil end
  local c = {}
  for i = 1, #t do c[i] = t[i] end
  table.sort(c)
  local k = #c
  if k % 2 == 1 then return c[(k + 1) / 2] end
  return (c[k / 2] + c[k / 2 + 1]) / 2
end

---------------------------------------------------------------- daily history
-- Day index shared with Auctionator (days since 2020-01-01), so both histories line up.
local DAY0 = time({ year = 2020, month = 1, day = 1, hour = 0 })
function ns.DayIndex(t)
  return floor(((t or time()) - DAY0) / 86400)
end

-- Optional: Auctionator's own daily history (up to ~21 days: lowest price + most units seen per day).
-- Internal table of another addon, so every access is guarded; without Auctionator this just returns nil.
local function auctionatorHistory(id)
  local db = Auctionator and Auctionator.Database
  if not (db and db.GetPriceHistory) then return nil end
  local ok, hist = pcall(db.GetPriceHistory, db, tostring(id))
  if ok and type(hist) == "table" and #hist > 0 then return hist end
  return nil
end

-- Returns `days` slots ending today: { day, t, minP, maxP, qty, avgP, scans, ext }
--   minP/maxP = lowest / highest "cheapest price" seen that day, qty = most units on the AH that day,
--   avgP = market price from your scans (cheapest ~10%), scans = your scans that day,
--   ext = true when the day came from Auctionator (you did not scan that day yourself).
-- Your own scans always win; Auctionator only fills days you have no data for.
function ns.DailyHistory(id, days)
  days = days or 21
  local today = ns.DayIndex()
  local series = {}
  for i = 1, days do
    local d = today - days + i
    series[i] = { day = d, t = DAY0 + d * 86400 + 43200 }
  end
  local function slot(d)
    local i = d and (d - (today - days)) or 0
    if i >= 1 and i <= days then return series[i] end
  end
  local own, ext = 0, 0

  local r = ns.MarketRec(id)
  if r and r.d then
    for d, v in pairs(r.d) do
      local s = slot(tonumber(d))
      if s then
        s.minP, s.maxP, s.qty, s.avgP, s.scans = v[1], v[2], v[3], v[4], v[5]
        own = own + 1
      end
    end
  end

  local hist = auctionatorHistory(id)
  if hist then
    for _, e in ipairs(hist) do
      local s = slot(tonumber(e.rawDay))
      if s and not s.scans then
        s.minP, s.maxP, s.qty, s.ext = e.minSeen, e.maxSeen, e.available, true
        ext = ext + 1
      end
    end
  end
  return series, own, ext
end

---------------------------------------------------------------- demand
-- Demand factor ~0.4 .. 1.75 (1.0 = normal) plus details for tooltips and the chart.
--   * scarcity: units on the AH now vs. the usual daily amount over the last 7 days
--   * turnover: units that vanished between your own scans (sold OR cancelled/expired) — an estimate,
--     the game API has no sales history; needs a few scans some hours apart
--   * trend:    cheapest price now vs. the usual daily low over the last 7 days
function ns.Demand(id)
  local r = ns.MarketRec(id)
  local series, ownDays, extDays = ns.DailyHistory(id, 8)
  local todayS = series[#series]
  local hasOwn = r and r.t

  local q, pMin
  if hasOwn then
    q, pMin = r.q or 0, r.min
  elseif todayS.minP or todayS.qty then
    q, pMin = todayS.qty, todayS.minP
  else
    -- nothing today: use the most recent day we know about (if any)
    for i = #series - 1, 1, -1 do
      local s = series[i]
      if s.minP or s.qty then q, pMin = s.qty, s.minP break end
    end
  end
  if q == nil and pMin == nil then
    return 0.8, { label = "|cff808080" .. L["no data"] .. "|r", none = true }
  end

  local ps, qs = {}, {}
  for i = 1, #series - 1 do
    local s = series[i]
    if s.minP then ps[#ps + 1] = s.minP end
    if s.qty then qs[#qs + 1] = s.qty end
  end
  local refP = #ps >= 2 and median(ps) or nil
  local refQ = #qs >= 2 and median(qs) or nil
  local srcDays = #ps

  local scarcity
  if not q then
    scarcity = 0.4
  elseif refQ and refQ > 0 then
    scarcity = clamp(0.5 + 0.35 * (log(refQ / max(q, 1)) / log(2)), 0, 1)
  else
    -- no history yet: we cannot tell "a lot" from "usual", so stay neutral unless supply is tiny
    scarcity = (q == 0 and 1) or (q < 10 and 0.8) or (q < 30 and 0.65) or 0.5
  end

  local h = (hasOwn and r.h) or EMPTY
  local sold, hours = 0, 0
  for i = 2, #h do
    local a, b = h[i - 1], h[i]
    local dt = (b[1] - a[1]) / 3600
    if dt > 0.2 and dt < 72 and a[3] and b[3] then
      sold = sold + max(0, a[3] - b[3])
      hours = hours + dt
    end
  end
  local perDay = hours >= 6 and (sold / hours * 24) or nil
  local turnover = perDay and clamp(perDay / max(q or 0, 10), 0, 1) or nil

  local trend = 1
  if refP and refP > 0 and pMin then trend = clamp(pMin / refP, 0.5, 2) end

  -- neutral market (usual supply, no trend, typical turnover) = 1.0 -> "average"
  local F = 0.625 + 0.45 * scarcity + (turnover and 0.5 * turnover or 0.15) + 0.3 * clamp(trend - 1, -0.5, 0.5)
  if q == 0 then F = F + 0.1 end

  local label, level
  if q == 0 then label, level = "|cff40ff40" .. L["none on AH!"] .. "|r", "empty"
  elseif F >= 1.25 then label, level = "|cff40ff40" .. L["high"] .. "|r", "high"
  elseif F >= 0.95 then label, level = "|cffffff40" .. L["average"] .. "|r", "mid"
  else label, level = "|cffff7060" .. L["low"] .. "|r", "low" end

  return F, { label = label, level = level, scarcity = scarcity, refQ = refQ, refP = refP, perDay = perDay, trend = trend,
    q = q, pMin = pMin, days = srcDays, ownDays = ownDays, extDays = extDays }
end

-- Traffic-light dot for demand: green = high (or nothing on the AH), yellow = normal, red = low
local DEMAND_ICON = {
  high = "Interface\\COMMON\\Indicator-Green",
  empty = "Interface\\COMMON\\Indicator-Green",
  mid = "Interface\\COMMON\\Indicator-Yellow",
  low = "Interface\\COMMON\\Indicator-Red",
}
function ns.DemandIcon(dem, size)
  if not dem or dem.none or not dem.level then return "" end
  size = size or 14
  return string.format("|T%s:%d:%d|t", DEMAND_ICON[dem.level], size, size)
end

-- Demand as shown in mob / node tooltips, per setting: "icon" (default), "text" or "off"
function ns.DemandTip(dem)
  local mode = ns.S and ns.S.tipDemand or "icon"
  if mode == "off" or not dem or dem.none then return "" end
  if mode == "text" then return "  |cff909090" .. L["demand"] .. "|r " .. dem.label end
  return " " .. ns.DemandIcon(dem) .. (dem.level == "empty" and "|cff40ff40!|r" or "")
end

-- Enough units on the AH to be worth farming (setting "Min. on AH"); unknown quantity passes
function ns.Liquid(row)
  local minQty = ns.S and ns.S.minQty or 0
  return minQty <= 0 or row.qty == nil or row.qty >= minQty
end

---------------------------------------------------------------- ranking
function ns.Compute()
  if not ns.dirty and ns.results then return ns.results end
  local ctx = ns.Context()
  local S = ns.S
  local res, byId = {}, {}
  local market = ns.Market().items

  local function add(id, m)
    local srcs = ns.Sources(id, ctx)
    local best = srcs[1]
    local p, q, t, psrc = ns.Price(id)
    local F, dem = ns.Demand(id)
    local rec = ns.MarketRec(id)
    local row = { id = id, m = m, sources = srcs, best = best, price = p, qty = q, ptime = t, psrc = psrc,
      minP = rec and rec.min,
      F = F, dem = dem }
    if best then
      local yield
      local uph = CATS[m.c].uph
      if best.kind == "fish" then
        -- fishing: casts/hour x share of the catch x casts that catch something at your skill
        row.chance = best.chance
        yield = (best.chance or 5) / 100 * (best.success or 0.5)
        uph = CATS.fish.uph
      elseif m.drop then
        -- mob drops: kills/hour x drop chance; unknown chances use a cautious default and rank lower
        local pct = best.chance
        if not pct then
          pct = (best.kind == "world") and ns.DEFAULT_WORLD_CHANCE[m.c] or ns.DEFAULT_CHANCE[m.c]
          row.chanceGuess = true
        end
        row.chance = pct
        yield = pct / 100
        if m.fish then uph = CATS.dgoods.uph end -- fish that mobs drop: kills, not casts
      else
        yield = m.r
        row.chance = best.chance
      end
      row.uph = uph * yield / best.mult
      if p then
        row.gph = p * 0.95 * row.uph
        row.score = row.gph * F * (row.chanceGuess and 0.6 or 1)
      end
    end
    res[#res + 1] = row
    byId[id] = row
  end

  for id, m in pairs(MAT) do
    if S.cats[m.c] then add(id, m) end
  end
  -- other mob drops: only those that actually trade (seen on the AH at least once) or are pinned
  for id, m in pairs(ns.DROP) do
    if S.cats[m.c] then
      local r = market[id]
      if (r and (r.p or r.lp)) or ns.db.pins[id] then add(id, m) end
    end
  end

  -- "hot" items: the best few that actually sell; mobs dropping them get marked
  local ranked = {}
  for _, row in ipairs(res) do
    if row.best and row.score and row.F >= 0.85 and ns.Liquid(row) then ranked[#ranked + 1] = row end
  end
  table.sort(ranked, function(a, b) return a.score > b.score end)
  local hot = {}
  for i = 1, min(S.topN, #ranked) do hot[ranked[i].id] = i end
  for id in pairs(ns.db.pins) do
    if ns.IsTracked(id) then hot[id] = 0 end
  end

  ns.results, ns.rowById, ns.hot = res, byId, hot
  ns.dirty = false
  return res
end

---------------------------------------------------------------- mobs
local TYPE_LOOKUP = {
  Beast = "beast", [L["Beast"]] = "beast",
  Humanoid = "humanoid", [L["Humanoid"]] = "humanoid",
}
do
  local ci = C_CreatureInfo
  if ci and ci.GetCreatureTypeInfo then
    local b = ci.GetCreatureTypeInfo(1)
    local h = ci.GetCreatureTypeInfo(7)
    if b and b.name then TYPE_LOOKUP[b.name] = "beast" end
    if h and h.name then TYPE_LOOKUP[h.name] = "humanoid" end
  end
end

-- Everything tracked this unit can give you, best first.
-- Each entry: { id, why = "db"|"learned"|"rule", hot = rank|nil, low = true when your skill is too low, req }
function ns.UnitMaterials(unit)
  if not ns.S then return nil end
  local guid = ns.Pub(UnitGUID(unit))
  if not guid then return nil end
  local npcID, kind = ns.NpcIDFromGUID(guid)
  if kind ~= "npc" or not npcID then return nil end
  if ns.Pub(UnitIsPlayer(unit)) then return nil end
  local attackable = ns.Pub(UnitCanAttack("player", unit))
  if attackable == false then return nil end

  ns.Compute()
  local ctx = ns.ctx or ns.Context()
  local S = ns.S
  local level = ns.Pub(UnitLevel(unit))
  if type(level) ~= "number" then level = nil elseif level < 0 then level = ctx.level + 10 end
  if level and ns.LearnMobLevel(npcID, ns.Pub(UnitLevel(unit))) then ns.Invalidate() end
  local ctype = TYPE_LOOKUP[ns.Pub(UnitCreatureType(unit)) or ""]

  local found = {}
  for _, id in ipairs(ns.NPC_ITEMS[npcID] or EMPTY) do found[id] = "db" end
  local learned = ns.db.learned.npc[npcID]
  if learned then
    for id in pairs(learned) do
      if ns.IsTracked(id) and not found[id] then found[id] = "learned" end
    end
  end
  if level and ctype then
    for id, m in pairs(ns.RULE_ITEMS) do
      if m.ct == ctype and level >= m.band[1] and level <= m.band[2] and not found[id] then found[id] = "rule" end
    end
  end

  local list, others = {}, {}
  for id, why in pairs(found) do
    local m = ns.Meta(id)
    if m.drop and S.cats[m.c] and not ns.Price(id) then
      -- drops never seen on the AH: still listed (grey) so you know what the mob carries
      others[#others + 1] = id
    elseif S.cats[m.c] then
      local prof = CATS[m.c].prof
      local have = prof and ctx.profs[prof]
      local ok, low, req = true, false, nil
      if prof and not have and S.onlyMyProfs then ok = false end
      if ok and prof == "skin" and level then
        req = ns.SkinReq(level)
        if not have or have < req then low = true end
      end
      if ok then
        local hot = ns.hot[id]
        if S.markAll and not hot then hot = 500 end
        local chance, csrc, corpses = ns.DropChance(id, npcID)
        list[#list + 1] = { id = id, why = why, hot = hot, low = low, req = req,
          chance = chance, chanceSrc = csrc, corpses = corpses }
      end
    end
  end
  table.sort(list, function(a, b)
    local ah, bh = a.hot or 1000, b.hot or 1000
    if (a.low and 1 or 0) ~= (b.low and 1 or 0) then return not a.low end
    if ah ~= bh then return ah < bh end
    local pa, pb = ns.Price(a.id) or 0, ns.Price(b.id) or 0
    return pa > pb
  end)
  return list, level, npcID, others
end
