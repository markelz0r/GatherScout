-- Curated material metadata. Item IDs verified against the WoW Forever item database.
--   c     = category (see ns.CATS)
--   r     = relative yield: 1.0 = main product of a common source, 0.1 = rare by-product
--   band  = {minMobLevel, maxMobLevel} for rule-based sources (any beast / any humanoid of that level)
--   ct    = creature type for rule-based sources ("beast" | "humanoid")
--   zones/skill/guess = hand-placed sources for Forever items the database has no spawns for yet
local _, ns = ...
local L = ns.L

-- uph = base amount per hour at difficulty 1.0 (for d* categories: kills): only a weight between categories
-- for ScoutScore, not a forecast
ns.CATS = {
  herb    = { label = L["Herbs"],     prof = "herb", uph = 60, order = 1 },
  ore     = { label = L["Ore"],       prof = "mine", uph = 40, order = 2 },
  gem     = { label = L["Gems"],      prof = "mine", uph = 30, order = 3, tip = L["Stones and gems from veins"] },
  skin    = { label = L["Leather"],   prof = "skin", uph = 55, order = 4, tip = L["Leather, hides and scales (skinning)"] },
  cloth   = { label = L["Cloth"],     prof = nil,    uph = 40, order = 5 },
  drop    = { label = L["Scales"],    prof = nil,    uph = 30, order = 6, tip = L["Murloc scales"] },
  elem    = { label = L["Elemental"], prof = nil,    uph = 12, order = 7,
              tip = L["Elemental materials and essences from elementals and undead"] },
  -- fishing skill is checked per place (Analysis.lua), mobs that drop fish need no profession; uph = casts
  fish    = { label = L["Fish"],      prof = nil,    uph = 150, order = 8,
              tip = L["Fish and other catches from fishing: open water and schools"] },
  dgoods  = { label = L["Drops"],     prof = nil,    uph = 40, order = 9, drop = true,
              tip = L["Everything else that drops from mobs and sells: meat, fangs, silk, pouches, feathers, potions…"] },
  drecipe = { label = L["Recipes"],   prof = nil,    uph = 40, order = 10, drop = true,
              tip = L["Recipes, patterns and schematics from mobs"] },
  dgear   = { label = L["Gear"],      prof = nil,    uph = 40, order = 11, drop = true,
              tip = L["Weapons and armor that drop from mobs (BoE)"] },
}
ns.DROP_CAT = { goods = "dgoods", recipe = "drecipe", gear = "dgear" }

ns.PROF_LABEL = { herb = L["Herbalism"], mine = L["Mining"], skin = L["Skinning"], fish = L["Fishing"] }

local M = {}
ns.MAT = M
local function set(c, r, ids, extra)
  for _, id in ipairs(ids) do
    local e = { c = c, r = r }
    if extra then for k, v in pairs(extra) do e[k] = v end end
    M[id] = e
  end
end

---------------------------------------------------------------- Herbalism
set("herb", 1.0,  { 2447, 765 })                       -- Peacebloom, Silverleaf
set("herb", 0.9,  { 2449, 785, 2450, 2453 })           -- Earthroot, Mageroyal, Briarthorn, Bruiseweed
set("herb", 0.8,  { 3355, 3356, 3821, 8838 })          -- Wild Steelbloom, Kingsblood, Goldthorn, Sungrass
set("herb", 0.7,  { 3818, 3358, 13464, 13463 })        -- Fadeleaf, Khadgar's Whisker, Golden Sansam, Dreamfoil
set("herb", 0.6,  { 3820, 3357, 4625, 8831, 13465, 13466 }) -- Stranglekelp, Liferoot, Firebloom, Purple Lotus, Silversage, Plaguebloom
set("herb", 0.5,  { 3819, 8836, 8839, 8846, 13467 })   -- Wintersbite, Arthas' Tears, Blindweed, Gromsblood, Icecap
set("herb", 0.4,  { 3369 })                            -- Grave Moss
set("herb", 0.3,  { 8845 })                            -- Ghost Mushroom
set("herb", 0.2,  { 2452 })                            -- Swiftthistle (by-product)
set("herb", 0.12, { 249399, 249424, 249274 })          -- Frilled Lichen, Rosecap, Stranglevine (Forever by-products)
set("herb", 0.1,  { 8153 })                            -- Wildvine (by-product + troll drop)
set("herb", 0.03, { 13468 })                           -- Black Lotus
-- Forever: Mount Hyjal herbs. The database has no node spawns for them yet; zone/skill are a best guess
-- and get corrected by what you actually gather (see "learned" in Core.lua).
set("herb", 0.7,  { 248821, 248823 }, { zones = { [2482] = 1 }, skill = 285, guess = true }) -- Demonsage, Marefoil
set("herb", 0.08, { 248822 },         { zones = { [2482] = 1 }, skill = 300, guess = true }) -- Death Lotus

---------------------------------------------------------------- Mining
set("ore", 1.0,  { 2770 })                    -- Copper
set("ore", 0.8,  { 2771, 2772, 3858, 10620 }) -- Tin, Iron, Mithril, Thorium
set("ore", 0.4,  { 11370 })                   -- Dark Iron
set("ore", 0.2,  { 3340, 4278 })              -- Incendicite, Lesser Bloodstone
set("ore", 0.12, { 2775, 2776, 7911 })        -- Silver, Gold, Truesilver (rare veins)
set("ore", 0.6,  { 248815 }, { zones = { [2482] = 1 }, skill = 285, guess = true }) -- Heavy Thorium Ore (Hyjal)

set("gem", 0.6,  { 2835, 2836, 2838, 7912, 12365 })  -- stones
set("gem", 0.1,  { 249391, 249425, 249426 })          -- Pyrite, Bauxite, Pitchblende (Forever)
set("gem", 0.08, { 774, 818 })                        -- Malachite, Tigerseye
set("gem", 0.05, { 1210, 1206, 1705, 3864, 7910 })    -- Shadowgem, Moss Agate, Lesser Moonstone, Citrine, Star Ruby
set("gem", 0.04, { 1529, 7909 })                      -- Jade, Aquamarine
set("gem", 0.03, { 12799, 12361, 9262 })              -- Large Opal, Blue Sapphire, Black Vitriol
set("gem", 0.02, { 12364, 12800, 12363 })             -- Huge Emerald, Azerothian Diamond, Arcane Crystal
set("gem", 0.01, { 11382 })                           -- Blood of the Mountain

---------------------------------------------------------------- Skinning (rule-based: any beast of the level band)
set("skin", 0.6, { 2934 }, { band = { 1, 22 },  ct = "beast" }) -- Ruined Leather Scraps
set("skin", 1.0, { 2318 }, { band = { 1, 24 },  ct = "beast" }) -- Light Leather
set("skin", 0.1, { 783 },  { band = { 8, 24 },  ct = "beast" }) -- Light Hide
set("skin", 1.0, { 2319 }, { band = { 18, 33 }, ct = "beast" }) -- Medium Leather
set("skin", 0.1, { 4232 }, { band = { 18, 33 }, ct = "beast" }) -- Medium Hide
set("skin", 1.0, { 4234 }, { band = { 27, 42 }, ct = "beast" }) -- Heavy Leather
set("skin", 0.1, { 4235 }, { band = { 27, 42 }, ct = "beast" }) -- Heavy Hide
set("skin", 1.0, { 4304 }, { band = { 37, 50 }, ct = "beast" }) -- Thick Leather
set("skin", 0.1, { 8169 }, { band = { 37, 50 }, ct = "beast" }) -- Thick Hide
set("skin", 1.0, { 8170 }, { band = { 46, 63 }, ct = "beast" }) -- Rugged Leather
set("skin", 0.1, { 8171 }, { band = { 46, 63 }, ct = "beast" }) -- Rugged Hide
-- Skinning from specific mobs (mob lists come from the database)
set("skin", 0.9,  { 248825 })                  -- Fel Leather (Hyjal)
set("skin", 0.6,  { 15417 })                   -- Devilsaur Leather
set("skin", 0.5,  { 8154, 15408 })             -- Scorpid Scale, Heavy Scorpid Scale
set("skin", 0.4,  { 8167, 15422, 15423, 15419, 7286, 7287, 7392, 6470 }) -- Turtle, Frostsaber, Chimera, Warbear, whelp scales, Deviate
set("skin", 0.3,  { 4461, 15416 })             -- Raptor Hide, Black Dragonscale
set("skin", 0.2,  { 8165, 15420 })             -- Worn Dragonscale, Ironfeather
set("skin", 0.1,  { 248824 })                  -- Fel Hide
set("skin", 0.05, { 6471 })                    -- Perfect Deviate Scale
set("skin", 0.03, { 249427, 249429 })          -- Pristine Leather, Pristine Scale (Forever)
set("skin", 0.02, { 249428 })                  -- Pristine Hide (Forever)

---------------------------------------------------------------- Cloth (rule-based: any humanoid of the level band)
set("cloth", 1.0,  { 2589 },  { band = { 5, 20 },  ct = "humanoid" }) -- Linen
set("cloth", 1.0,  { 2592 },  { band = { 15, 32 }, ct = "humanoid" }) -- Wool
set("cloth", 1.0,  { 4306 },  { band = { 26, 45 }, ct = "humanoid" }) -- Silk
set("cloth", 1.0,  { 4338 },  { band = { 38, 55 }, ct = "humanoid" }) -- Mageweave
set("cloth", 1.0,  { 14047 }, { band = { 47, 63 }, ct = "humanoid" }) -- Runecloth
set("cloth", 0.25, { 14256 })                                         -- Felcloth (demons/satyrs)

---------------------------------------------------------------- Other mob drops
set("drop", 0.3, { 5784, 5785 })               -- Slimy / Thick Murloc Scale
set("elem", 0.3, { 7067, 7068, 7069, 7070, 12808 }) -- Elemental Earth/Fire/Air/Water, Essence of Undeath
set("elem", 0.2, { 7076, 7078, 7080, 7082, 12803, 10286 }) -- Essences, Living Essence, Heart of the Wild

---------------------------------------------------------------- Fishing (catches and places: Data/Fishing.lua)
-- Items already tracked (Elemental Water…) keep their category and gain fishing places; fish that mobs drop
-- too (murlocs and Slitherskin Mackerel) keep those mobs through `drop`.
for id, f in pairs(ns.GEN.fish or {}) do
  local e = M[id]
  if not e then
    e = { c = f.e and "elem" or "fish", r = 1 }
    M[id] = e
  end
  e.fish = true
  if not e.drop and ns.GEN.drops[id] and e.c == "fish" then e.drop = ns.GEN.drops[id] end
end

---------------------------------------------------------------- Zone level ranges
-- Classic zones use the well-known ranges; Forever zones fall back to levels measured from the database.
ns.ZONE_LEVELS = {
  [1429] = { 1, 10 },  [1426] = { 1, 10 },  [1438] = { 1, 10 },  [1411] = { 1, 10 },  [1412] = { 1, 10 },
  [1420] = { 1, 10 },  [1436] = { 10, 20 }, [1432] = { 10, 20 }, [1439] = { 10, 20 }, [1413] = { 10, 25 },
  [1421] = { 10, 20 }, [1433] = { 15, 25 }, [1442] = { 15, 27 }, [1440] = { 18, 30 }, [1431] = { 18, 30 },
  [1424] = { 20, 30 }, [1437] = { 20, 30 }, [1441] = { 25, 35 }, [1416] = { 30, 40 }, [1417] = { 30, 40 },
  [1443] = { 30, 40 }, [1434] = { 30, 45 }, [1445] = { 35, 45 }, [1418] = { 35, 45 }, [1435] = { 35, 45 },
  [1425] = { 40, 50 }, [1444] = { 40, 50 }, [1446] = { 40, 50 }, [1427] = { 43, 50 }, [1447] = { 45, 55 },
  [1419] = { 45, 55 }, [1449] = { 48, 55 }, [1448] = { 48, 55 }, [1428] = { 50, 58 }, [1422] = { 51, 58 },
  [1423] = { 53, 60 }, [1452] = { 53, 60 }, [1430] = { 55, 60 }, [1450] = { 55, 60 }, [1451] = { 55, 60 },
  [2482] = { 55, 60 }, -- Mount Hyjal
}
