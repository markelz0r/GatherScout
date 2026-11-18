"""Check the nameplate icon offset and the /gs icon command."""
import sys, re
from lupa import LuaRuntime
sys.stdout.reconfigure(encoding='utf-8')
ADDON, HARNESS = sys.argv[1], sys.argv[2]
L = LuaRuntime(unpack_returned_tuples=True)
L.execute(open(HARNESS, encoding='utf-8').read())
# record SetPoint calls on frames
L.execute('''
local mt = getmetatable(CreateFrame("Frame"))
local idx = mt.__index
mt.__index = function(self, k)
  if k == "SetPoint" then return function(s, ...) s._point = { ... } end end
  return idx(self, k)
end
''')
ns = L.eval('{}')
files = [l.strip() for l in open(ADDON + '/GatherScout.toc', encoding='utf-8') if l.strip() and not l.startswith('#')]
loader = L.eval('function(src, name, ns) local f = assert(load(src, "@" .. name)); f("GatherScout", ns) end')
for f in files:
    if not f.endswith('.xml'):
        loader(open(ADDON + '/' + f.replace(chr(92), '/'), encoding='utf-8').read(), f, ns)
fire, tick = L.eval('FireEvent'), L.eval('Tick')
fire('ADDON_LOADED', 'GatherScout'); fire('PLAYER_LOGIN'); tick(2)
L.execute('SKIN_RANK = 300; PLAYER_LEVEL = 56'); fire('SKILL_LINES_CHANGED'); tick(1)
ns.db.pins[15417] = True; ns.Invalidate(); tick(2)
fire('NAME_PLATE_UNIT_ADDED', 'nameplate1')
pt = L.eval('TEST_PLATE.GatherScoutIcon._point')
print('default anchor:', [pt[i] if not hasattr(pt[i], 'keys') else 'frame' for i in range(1, 6)], 'shown', L.eval('TEST_PLATE.GatherScoutIcon._shown'))
L.eval('SlashCmdList.GATHERSCOUT')('icon 6 -2 22'); tick(1)
pt = L.eval('TEST_PLATE.GatherScoutIcon._point')
print('after /gs icon 6 -2 22:', [pt[i] if not hasattr(pt[i], 'keys') else 'frame' for i in range(1, 6)], 'size', L.eval('TEST_PLATE.GatherScoutIcon._w'))
L.eval('SlashCmdList.GATHERSCOUT')('icon reset'); tick(1)
pt = L.eval('TEST_PLATE.GatherScoutIcon._point')
print('after reset:', [pt[i] if not hasattr(pt[i], 'keys') else 'frame' for i in range(1, 6)])
for line in L.eval('LOGS()').values():
    print('  [chat]', re.sub(r'\|c[0-9a-fA-F]{8}|\|r', '', str(line)))
print('OK')
