"""Generate GatherScout/Data/Fishing.lua: what you catch where (CMaNGOS classic-db fishing loot per zone, zone fishing
skill, catches of fishing schools) and where the schools are (QuestieDB object spawns).
Usage: python -I gen_fishing.py <cm_fish.json> <QuestieDB dir> <qdb objects.json> <GatherScout dir>"""
import sys, os, re, json

CMJ, QDIR, OBJ, ADDON = sys.argv[1:5]
cm = json.load(open(CMJ, encoding='utf-8'))
gen = open(os.path.join(ADDON, 'Data', 'Generated.lua'), encoding='utf-8').read()
zone_block = gen.split('ns.GEN.zones = {', 1)[1].split('\n}', 1)[0]
OUTDOOR = {int(u): name for u, name in re.findall(r'^\s*\[(\d+)\] = \{-?\d+, -?\d+, "((?:[^"\\]|\\.)*)"', zone_block, re.M)}
mat = open(os.path.join(ADDON, 'Data', 'Materials.lua'), encoding='utf-8').read()
MAT_IDS = set(int(x) for line in re.findall(r'^set\("(\w+)",[^{]*\{([^}]*)\}', mat, re.M) for x in re.findall(r'\d+', line[1]))
MAT_CAT = {}
for cat, ids in re.findall(r'^set\("(\w+)",[^{]*\{([^}]*)\}', mat, re.M):
    for x in re.findall(r'\d+', ids):
        MAT_CAT[int(x)] = cat

area2map, area_name = {}, {}
zf = open(os.path.join(QDIR, 'support', 'Forever', 'Zones', 'areaIdToUiMapId.lua'), encoding='utf-8').read()
for m in re.finditer(r'\[(\d+)\]\s*=\s*(\d+),\s*(?:--\s*([^\n]*))?', zf):
    area2map.setdefault(int(m.group(1)), int(m.group(2)))
    area_name[int(m.group(1))] = (m.group(3) or '').strip()

items = {int(k): v for k, v in cm['items'].items() if v}
KEEP_CONTAINERS = {7973}  # Big-mouth Clam: sold for the pearls inside
SKIP = {3857}             # Coal (lava fishing): vendor goods
ELEM = {7079}             # Globe of Water: elemental reagent
def tradeable(i):
    it = items.get(i)
    if it is None or i in SKIP or (it['q'] or 0) < 1 or it.get('bond') in (1, 4):
        return False
    return it['class'] != 15 or i in KEEP_CONTAINERS

# ---------------------------------------------------------------- open water: every area of a zone (coast and lakes differ)
zone_area = {}                      # uiMap -> the zone's own area id (its name equals the zone name)
areas_of = {}                       # uiMap -> [area ids with fishing loot]
for a in sorted(int(x) for x in cm['area']):
    u = area2map.get(a)
    if u not in OUTDOOR:
        continue
    areas_of.setdefault(u, []).append(a)
    if area_name.get(a, '').lower() == OUTDOOR[u].lower():
        zone_area[u] = a
skill_of = {int(a): s for a, s in cm['skill'].items()}
zone_skill = {}
for u, alist in areas_of.items():
    za = zone_area.get(u, alist[0])
    zs = skill_of.get(za)
    if zs is None:
        zs = min((skill_of[a] for a in alist if a in skill_of), default=None)
    if zs is not None:
        zone_skill[u] = zs
    if u not in zone_area:
        print('  no zone-level area for %s, using %s' % (OUTDOOR[u], [(a, area_name.get(a)) for a in alist]))
zone_loot = {u: True for u in areas_of}

# ---------------------------------------------------------------- schools with known places (QuestieDB spawns)
objs = json.load(open(OBJ, encoding='utf-8'))
def oname(r):
    n = r['S'].get('1') if isinstance(r['S'], dict) else None
    try:
        return bytes.fromhex(n).decode('utf-8')
    except Exception:
        return n
PACK = [chr(c) for c in range(35, 127) if c != 92]
def enc(v):
    v = max(0, min(1000, v))
    return PACK[v // 91] + PACK[v % 91]
pool_loot = {}      # map -> pool name -> item -> %
pool_coords = {}    # pool name -> map -> packed
for oid, h in cm['holes'].items():
    r = objs.get(oid)
    if not r or not h['loot']:
        continue
    sp = r.get('spawns') or {}
    name = oname(r) or h['name']
    for a, pts in sp.items():
        u = area2map.get(int(a))
        if u not in OUTDOOR or not pts:
            continue
        for i, p in h['loot'].items():
            d = pool_loot.setdefault(u, {}).setdefault(name, {})
            d[int(i)] = max(d.get(int(i), 0), p)
        coords = sorted(set((round(x * 10), round(y * 10)) for x, y in pts if x is not None and y is not None))
        prev = pool_coords.setdefault(name, {}).get(u, '')
        pool_coords[name][u] = prev + ''.join(enc(x) + enc(y) for x, y in coords)

# ---------------------------------------------------------------- items: real catches that trade
# per item and zone: the area (zone or a sub-zone such as a coast) where it is caught most, with that area's skill
FISH = {}
for u, alist in areas_of.items():
    za = zone_area.get(u)
    best = {}
    for a in alist:
        sk = skill_of.get(a, zone_skill.get(u))
        for i, p in cm['area'][str(a)].items():
            i = int(i)
            if p < 0.01 or not tradeable(i) or MAT_CAT.get(i, 'fish') not in ('fish', 'elem'):
                continue
            cur = best.get(i)
            if cur is None or p > cur[0] + 1e-9 or (abs(p - cur[0]) < 1e-9 and (sk or 0) < (cur[1] or 0)):
                best[i] = (p, sk, a)
    for i, (p, sk, a) in best.items():
        FISH.setdefault(i, {'z': {}, 'p': {}})['z'][u] = (round(p * 100, 1), sk if sk is not None else zone_skill.get(u, 0),
                                                       0 if a == za else a)
for u, per in pool_loot.items():
    for name, loot in per.items():
        for i, p in loot.items():
            if p >= 0.25 and tradeable(i) and MAT_CAT.get(i, 'fish') in ('fish', 'elem'):
                FISH.setdefault(i, {'z': {}, 'p': {}})['p'].setdefault(u, {})[name] = round(p * 100, 1)
used_pools = set(n for f in FISH.values() for per in f['p'].values() for n in per)

def lstr(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
L = ['-- GENERATED by tools/gen_fishing.py. Do not edit by hand.',
     '-- Fishing: CMaNGOS classic-db (GPL-3.0) fishing loot per zone, zone fishing skill and catches of fishing schools;',
     '-- school positions from QuestieDB (GPL-3.0). Only schools with known positions are listed.',
     'local _, ns = ...', 'local G = ns.GEN', '',
     '-- [uiMapID] = zone fishing skill: a cast catches something with chance (your skill - this + 5)%,',
     '-- so there are no getaways from this + 95',
     'G.fishSkill = {']
for u in sorted(zone_skill):
    L.append('  [%d] = %d, -- %s' % (u, zone_skill[u], OUTDOOR[u]))
L += ['}', '',
      '-- [itemID] = { z = { [uiMapID] = {% of catches in open water, fishing skill there, sub-zone area ID or 0} },',
      '--              p = { [uiMapID] = { [school] = % of catches } }, e = true for elemental reagents }',
      'G.fish = {']
for i in sorted(FISH):
    f = FISH[i]
    z = ', '.join('[%d]={%s,%d,%d}' % ((u,) + f['z'][u]) for u in sorted(f['z']))
    p = ', '.join('[%d]={%s}' % (u, ', '.join('[%s]=%s' % (lstr(n), f['p'][u][n]) for n in sorted(f['p'][u]))) for u in sorted(f['p']))
    L.append('  [%d] = {z={%s}%s%s}, -- %s' % (i, z, (', p={%s}' % p) if p else '', ', e=true' if (i in ELEM or MAT_CAT.get(i) == 'elem') else '', items[i]['name']))
L += ['}', '', '-- [school name] = { [uiMapID] = packed coordinates (see ns.UnpackCoords) }', 'G.fishPools = {']
for n in sorted(used_pools):
    L.append('  [%s] = {%s},' % (lstr(n), ', '.join('[%d]=%s' % (u, lstr(pool_coords[n][u])) for u in sorted(pool_coords[n]))))
L.append('}')
open(os.path.join(ADDON, 'Data', 'Fishing.lua'), 'w', encoding='utf-8', newline='\n').write('\n'.join(L) + '\n')
print('zones with catches', len(areas_of), 'zones with skill', len(zone_skill), 'items', len(FISH), 'schools', sorted(used_pools))
for i in sorted(FISH, key=lambda i: -max([v[0] for v in FISH[i]['z'].values()] + [0])):
    f = FISH[i]
    print('  %6d %-28s %-5s zones %2d  best %5s%%  schools %s' % (i, items[i]['name'], MAT_CAT.get(i, 'new'), len(f['z']),
          max([v[0] for v in f['z'].values()] + [0]), sorted(set(n for per in f['p'].values() for n in per))))
missing = sorted(set(OUTDOOR) - set(areas_of))
print('outdoor zones without fishing data:', [OUTDOOR[u] for u in missing])
