-- Corrections to the generated data, applied at load.
-- Mob levels: a few entries have impossible level ranges (Rabid Longtooth 8–48, Echeyakee 16–60), which made a
-- level 47 mob look grey and "easy". Known ones get their real levels; any other range wider than 6 levels is
-- narrowed to its top, so a mob can only ever look more dangerous than it is, never less.
local _, ns = ...
local npcs = ns.GEN.npcs

local LEVELS = {
  [3475] = { 16, 16 }, -- Echeyakee
  [5288] = { 47, 48 }, -- Rabid Longtooth
}
for id, lv in pairs(LEVELS) do
  local n = npcs[id]
  if n then n[1], n[2] = lv[1], lv[2] end
end
for _, n in pairs(npcs) do
  if n[2] - n[1] > 6 then n[1] = n[2] - 1 end
end
