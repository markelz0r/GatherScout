"""World map: herb points off by default, mob points on, toggle button (LMB all / RMB nodes)."""
import sys
from lupa import LuaRuntime
sys.stdout.reconfigure(encoding='utf-8')
ADDON, HARNESS = sys.argv[1], sys.argv[2]
L = LuaRuntime(unpack_returned_tuples=True)
L.execute(open(HARNESS, encoding='utf-8').read())
ns = L.eval('{}')
files = [l.strip() for l in open(ADDON + '/GatherScout.toc', encoding='utf-8') if l.strip() and not l.startswith('#')]
loader = L.eval('function(src, name, ns) local f = assert(load(src, "@" .. name)); f("GatherScout", ns) end')
for f in files:
    if not f.endswith('.xml'):
        loader(open(ADDON + '/' + f.replace(chr(92), '/'), encoding='utf-8').read(), f, ns)
fire, tick = L.eval('FireEvent'), L.eval('Tick')
fire('ADDON_LOADED', 'GatherScout'); fire('PLAYER_LOGIN'); tick(2)
L.execute('PLAYER_LEVEL = 45')
ns.db.pins[2447] = True    # Peacebloom: herb points only
ns.db.pins[12207] = True   # Giant Egg: mob points
ns.Invalidate(); tick(2)
L.execute('ToggleWorldMap()')
prov = L.eval('WorldMapFrame._provider')
btn = L.eval('GatherScoutMapToggle')
print('button exists:', btn is not None, 'defaults mapShow/mapNodes:', ns.S.mapShow, ns.S.mapNodes)


def pins_on(mapID):
    L.execute('CUR_MAP = %d' % mapID)
    prov.RefreshAllData(prov)
    pins = L.eval('PINS')
    kinds = {'npc': 0, 'node': 0, 'agg': 0}
    for i in range(1, len(pins) + 1):
        info = pins[i].info
        kinds['agg' if info.agg else ('npc' if info.npc else 'node')] += 1
    return kinds


print('Barrens 1413 (Peacebloom zone):', pins_on(1413))
print('Tanaris 1446 (Giant Egg zone): ', pins_on(1446))
print('Kalimdor 1414 (continent):     ', pins_on(1414))
btn._scripts.OnClick(btn, 'RightButton')
print('after RMB -> mapNodes', ns.S.mapNodes, '| Barrens:', pins_on(1413))
btn._scripts.OnClick(btn, 'LeftButton')
print('after LMB -> mapShow', ns.S.mapShow, '| Barrens:', pins_on(1413), '| Kalimdor:', pins_on(1414))
btn._scripts.OnClick(btn, 'LeftButton')
print('after LMB again -> mapShow', ns.S.mapShow, '| Tanaris:', pins_on(1446))
L.eval('SlashCmdList.GATHERSCOUT')('nodes')
print('/gs nodes -> mapNodes', ns.S.mapNodes)
print('OK')
