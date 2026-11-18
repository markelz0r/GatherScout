"""Generate Data/Generated.lua from QuestieDB (Forever flavor), optionally adding drop chances
from a CMaNGOS classic-db dump (GPL-3.0).
Usage: python -I gen.py <QuestieDB dir> <out lua> [ClassicDB_*.sql.gz]"""
import sys, os, re, base64, zlib, json, struct, math
from collections import defaultdict

QDIR, OUT = sys.argv[1], sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, 'qdb.py'), encoding='utf-8').read().split('def main')[0]
exec(src)  # cbor_decode, dec

# ---------------------------------------------------------------- TOC store
kv = {}
rx = re.compile(r'^## (X-[^:]+): ?(.*)$')
with open(os.path.join(QDIR, 'QuestieDB_Forever.toc'), encoding='utf-8') as f:
    for line in f:
        m = rx.match(line.rstrip('\n'))
        if m:
            kv[m.group(1)] = m.group(2)

def get(key):
    v = kv.get(key)
    if v is None:
        return None
    m = re.match(r'^~(\d+)~$', v)
    if m:
        v = ''.join(kv[key + '-' + str(p)] for p in range(1, int(m.group(1)) + 1))
    return v

def ids_of(ent):
    raw = base64.b64decode(get('X-%s-IDS' % ent))
    for wbits in (15, -15, 31):
        try:
            return cbor_decode(zlib.decompress(raw, wbits))[0]
        except Exception:
            pass
    raise RuntimeError('ids ' + ent)

def norm(S):
    if isinstance(S, list):
        return {i + 1: v for i, v in enumerate(S) if v is not None}
    out = {}
    for k, v in S.items():
        if isinstance(k, int):
            out[k] = v
        else:
            out[k] = v
    return out

def txt(v):
    if isinstance(v, bytes):
        return v.decode('utf-8', 'replace')
    return v

def row(ent, eid):
    s = get('X-%s-%d-S' % (ent, eid))
    return norm(dec(s)) if s else None

def field(ent, eid, fi):
    s = get('X-%s-%d-%d' % (ent, eid, fi))
    if s is None:
        return None
    v = dec(s)
    if isinstance(v, dict):
        v = {k: v2 for k, v2 in v.items()}
    return v

# ---------------------------------------------------------------- zones
area2map = {}
area_name = {}
zf = open(os.path.join(QDIR, 'support', 'Forever', 'Zones', 'areaIdToUiMapId.lua'), encoding='utf-8').read()
for m in re.finditer(r'\[(\d+)\]\s*=\s*(\d+),\s*--\s*([^\n]*)', zf):
    a, u, nm = int(m.group(1)), int(m.group(2)), m.group(3).strip()
    area2map.setdefault(a, u)
    area_name[a] = nm

# Outdoor zones we care about (uiMapID -> english name, faction A/H/C)
OUTDOOR = {
    1429: ('Elwynn Forest', 'A'), 1426: ('Dun Morogh', 'A'), 1438: ('Teldrassil', 'A'), 1436: ('Westfall', 'A'),
    1432: ('Loch Modan', 'A'), 1439: ('Darkshore', 'A'), 1433: ('Redridge Mountains', 'A'), 1431: ('Duskwood', 'A'),
    1437: ('Wetlands', 'A'),
    1411: ('Durotar', 'H'), 1412: ('Mulgore', 'H'), 1420: ('Tirisfal Glades', 'H'), 1413: ('The Barrens', 'H'),
    1421: ('Silverpine Forest', 'H'),
    1442: ('Stonetalon Mountains', 'C'), 1440: ('Ashenvale', 'C'), 1424: ('Hillsbrad Foothills', 'C'),
    1441: ('Thousand Needles', 'C'), 1416: ('Alterac Mountains', 'C'), 1417: ('Arathi Highlands', 'C'),
    1443: ('Desolace', 'C'), 1445: ('Dustwallow Marsh', 'C'), 1434: ('Stranglethorn Vale', 'C'),
    1418: ('Badlands', 'C'), 1435: ('Swamp of Sorrows', 'C'), 1425: ('The Hinterlands', 'C'), 1444: ('Feralas', 'C'),
    1446: ('Tanaris', 'C'), 1427: ('Searing Gorge', 'C'), 1447: ('Azshara', 'C'), 1419: ('Blasted Lands', 'C'),
    1449: ("Un'Goro Crater", 'C'), 1448: ('Felwood', 'C'), 1428: ('Burning Steppes', 'C'),
    1422: ('Western Plaguelands', 'C'), 1423: ('Eastern Plaguelands', 'C'), 1452: ('Winterspring', 'C'),
    1430: ('Deadwind Pass', 'C'), 1450: ('Moonglade', 'C'), 1451: ('Silithus', 'C'),
    # WoW Forever additions
    2482: ('Mount Hyjal', 'C'), 2548: ('Riverglades', 'C'), 2521: ('Zephras Isle', 'C'), 2652: ("Shen'dralas", 'C'),
}

def to_map(area):
    try:
        a = int(area)
    except (TypeError, ValueError):
        return None
    u = area2map.get(a)
    return u if u in OUTDOOR else None

# ---------------------------------------------------------------- npcs
npc_ids = ids_of('Npc')
ru_blob = get('X-l10n-ruRU-Npc')
ru_names = {}
if ru_blob:
    d = cbor_decode(zlib.decompress(base64.b64decode(ru_blob)))[0]
    names = d[0]
    for idx, nid in enumerate(npc_ids):
        if idx < len(names) and names[idx]:
            ru_names[nid] = txt(names[idx])

NPC = {}
for nid in npc_ids:
    S = row('Npc', nid)
    if not S:
        continue
    NPC[nid] = S

def npc_spawns(nid):
    sp = field('Npc', nid, 7)
    out = defaultdict(int)
    if isinstance(sp, dict):
        for area, pts in sp.items():
            u = to_map(area)
            if u:
                out[u] += len(pts) if isinstance(pts, list) else 1
    return out

# zone level ranges from hostile, non-elite, non-critter npcs, weighted by spawns
zone_levels = defaultdict(list)
spawn_cache = {}
for nid, S in NPC.items():
    if S.get(13):  # friendly to someone
        continue
    lo, hi = S.get(4) or 0, S.get(5) or 0
    rank = S.get(6) or 0
    if lo <= 1 or lo > 63 or rank in (1, 2, 3):
        continue
    sp = npc_spawns(nid)
    spawn_cache[nid] = sp
    for u, c in sp.items():
        for _ in range(min(c, 40)):
            zone_levels[u].append((lo + hi) / 2)

def pct(lst, p):
    lst = sorted(lst)
    if not lst:
        return None
    k = (len(lst) - 1) * p
    return lst[int(round(k))]

ZONES = {}
for u, (nm, fac) in OUTDOOR.items():
    lv = zone_levels.get(u, [])
    if len(lv) >= 10:
        ZONES[u] = (int(pct(lv, 0.08)), int(round(pct(lv, 0.92))), nm, fac, len(lv))
    else:
        ZONES[u] = (None, None, nm, fac, len(lv))

# ---------------------------------------------------------------- items / objects
item_ids = set(ids_of('Item'))
obj_ids = set(ids_of('Object'))

HERB_NODES = {
    'Peacebloom': 1, 'Silverleaf': 1, 'Earthroot': 15, 'Mageroyal': 50, 'Briarthorn': 70, 'Stranglekelp': 85,
    'Bruiseweed': 100, 'Wild Steelbloom': 115, 'Grave Moss': 120, 'Kingsblood': 125, 'Liferoot': 150,
    'Fadeleaf': 160, 'Goldthorn': 170, "Khadgar's Whisker": 185, 'Wintersbite': 195, 'Firebloom': 205,
    'Purple Lotus': 210, "Arthas' Tears": 220, 'Sungrass': 230, 'Blindweed': 235, 'Ghost Mushroom': 245,
    'Gromsblood': 250, 'Golden Sansam': 260, 'Dreamfoil': 270, 'Mountain Silversage': 280, 'Plaguebloom': 285,
    'Icecap': 290, 'Black Lotus': 300,
}
ORE_NODES = {
    'Copper Vein': 1, 'Poor Copper Vein': 1, 'Tin Vein': 65, 'Incendicite Mineral Vein': 65, 'Silver Vein': 75,
    'Ooze Covered Silver Vein': 75, 'Lesser Bloodstone Deposit': 75, 'Iron Deposit': 125,
    'Ooze Covered Iron Deposit': 125, 'Indurium Mineral Vein': 150, 'Gold Vein': 155, 'Ooze Covered Gold Vein': 155,
    'Mithril Deposit': 175, 'Ooze Covered Mithril Deposit': 175, 'Truesilver Deposit': 230,
    'Ooze Covered Truesilver Deposit': 230, 'Dark Iron Deposit': 230, 'Small Thorium Vein': 245,
    'Ooze Covered Thorium Vein': 245, 'Rich Thorium Vein': 275, 'Ooze Covered Rich Thorium Vein': 275,
    'Hakkari Thorium Vein': 275,
}
NODE_SKILL = dict(HERB_NODES)
NODE_SKILL.update(ORE_NODES)

obj_cache = {}
NODE_COORDS = defaultdict(lambda: defaultdict(set))  # node name -> uiMap -> {(x10, y10)}

def coords_of(pts):
    out = []
    if isinstance(pts, list):
        for p in pts:
            if isinstance(p, list) and len(p) >= 2 and isinstance(p[0], (int, float)) and isinstance(p[1], (int, float)):
                if 0 <= p[0] <= 100 and 0 <= p[1] <= 100:
                    out.append((int(round(p[0] * 10)), int(round(p[1] * 10))))
    return out

def obj_info(oid):
    if oid in obj_cache:
        return obj_cache[oid]
    S = row('Object', oid) if oid in obj_ids else None
    name = txt(S.get(1)) if S else None
    sp = field('Object', oid, 4) if S else None
    zones = defaultdict(int)
    if isinstance(sp, dict):
        for area, pts in sp.items():
            u = to_map(area)
            if u:
                zones[u] += len(pts) if isinstance(pts, list) else 1
                if name in NODE_SKILL:
                    NODE_COORDS[name][u].update(coords_of(pts))
    obj_cache[oid] = (name, zones)
    return obj_cache[oid]

# All node-sourced items we track (primary + secondary). Others are mob-sourced or rule-based.
NODE_ITEMS = [
    2447, 765, 2449, 785, 2450, 2452, 3820, 2453, 3355, 3369, 3356, 3357, 3818, 3821, 3358, 3819, 4625, 8831,
    8836, 8838, 8839, 8845, 8846, 13464, 13463, 13465, 13466, 13467, 13468, 8153,
    2770, 2771, 2772, 2775, 2776, 3858, 7911, 10620, 11370, 3340, 4278, 5833,
    2835, 2836, 2838, 7912, 12365,
    818, 774, 1210, 1206, 1705, 1529, 3864, 7909, 7910, 12799, 12361, 12364, 12800, 12363, 11382, 9262,
    249391, 249425, 249426, 249399, 249424, 249274,
]
objs_by_name = defaultdict(list)
for oid in obj_ids:
    S = row('Object', oid)
    if S and txt(S.get(1)) in NODE_SKILL:
        objs_by_name[txt(S.get(1))].append(oid)

# Russian names of gathering nodes (for tooltips on the nodes themselves)
_obj_list = ids_of('Object')
_ru_obj = {}
_blob = get('X-l10n-ruRU-Object')
if _blob:
    _d = cbor_decode(zlib.decompress(base64.b64decode(_blob)))[0][0]
    if isinstance(_d, dict):   # sparse: 1-based index into the object ID list
        for _k, _v in _d.items():
            if isinstance(_k, int) and 1 <= _k <= len(_obj_list) and _v:
                _ru_obj[_obj_list[_k - 1]] = txt(_v)
    else:
        for _i, _oid in enumerate(_obj_list):
            if _i < len(_d) and _d[_i]:
                _ru_obj[_oid] = txt(_d[_i])
NODE_RU = defaultdict(set)
for _name, _oids in objs_by_name.items():
    for _oid in _oids:
        if _oid in _ru_obj:
            NODE_RU[_name].add(_ru_obj[_oid])

ITEM_ZONES, ITEM_SKILL, ITEM_NODES = {}, {}, {}
for iid in NODE_ITEMS:
    if iid not in item_ids:
        print('missing item', iid)
        continue
    od = list(field('Item', iid, 3) or [])
    iname = txt(row('Item', iid).get(1))
    if iname in HERB_NODES:  # herb node objects are named exactly like the herb
        od += objs_by_name.get(iname, [])
    od = list(dict.fromkeys(od))
    zones = defaultdict(int)
    skills = []
    nodes = set()
    for oid in od:
        name, oz = obj_info(oid)
        if name not in NODE_SKILL:
            continue
        nodes.add(name)
        skills.append(NODE_SKILL[name])
        for u, c in oz.items():
            zones[u] += c
    if not zones:
        print('no zones for', iid, txt(row('Item', iid).get(1)))
        continue
    mx = max(zones.values())
    keep = {u: c for u, c in zones.items() if c >= max(3, 0.04 * mx)}
    ITEM_ZONES[iid] = keep
    ITEM_SKILL[iid] = min(skills)
    ITEM_NODES[iid] = sorted(nodes)

# ---------------------------------------------------------------- mob-sourced items
def npc_name(nid):
    S = NPC.get(nid)
    return txt(S.get(1)) if S else None

MOB_ITEMS = {}
# from Questie drop data
for iid in [8167, 4461, 8165, 6470, 6471, 15416, 15420, 5784, 5785, 14256, 248824, 248825,
            249427, 249428, 249429, 8153, 7067, 7068, 7069, 7070, 7076, 7078, 7080, 7082, 12808, 12803, 10286]:
    nd = field('Item', iid, 2) or []
    MOB_ITEMS.setdefault(iid, set()).update(n for n in nd if n in NPC)

def killable(S):
    """Hostile mobs and neutral (yellow) ones. Questie marks a neutral mob as friendly to "AH", the same as
    neutral town folk, so among those skip anyone with an NPC service flag (vendor, quest giver, trainer...),
    the friendly-to-all faction template 35 and elites (Booty Bay / Gadgetzan / Everlook bruisers and the like)."""
    f = txt(S.get(13))
    if not f:
        return True
    if f != 'AH':                   # friendly to one faction: guards and town folk
        return False
    return not S.get(15) and S.get(12) != 35 and (S.get(6) or 0) not in (1, 2)


# name-based families (skinning specials with no drop data)
def find(pred):
    return {nid for nid, S in NPC.items() if killable(S) and pred(npc_name(nid) or '', S)}

def lvl(S):
    return S.get(4) or 0

MOB_ITEMS.setdefault(15417, set()).update(find(lambda n, S: 'Devilsaur' in n or n == 'King Mosh'))
MOB_ITEMS.setdefault(15422, set()).update(find(lambda n, S: 'Frostsaber' in n and lvl(S) >= 50))
MOB_ITEMS.setdefault(15423, set()).update(find(lambda n, S: 'Chimaera' in n and 'Chimaerok' not in n and lvl(S) >= 40))
FELWOOD_WS = {1448, 1452}
def in_zones(nid, zs):
    sp = spawn_cache.get(nid)
    if sp is None:
        sp = npc_spawns(nid)
        spawn_cache[nid] = sp
    return any(u in zs for u in sp)
MOB_ITEMS.setdefault(15419, set()).update(find(lambda n, S: re.search(r'Bear|Grizzly|Shardtooth|Ursa', n) and lvl(S) >= 48))
MOB_ITEMS[15419] = {n for n in MOB_ITEMS[15419] if in_zones(n, FELWOOD_WS)}
MOB_ITEMS.setdefault(8154, set()).update(find(lambda n, S: 'Scorpid' in n and 36 <= lvl(S) < 50))
MOB_ITEMS.setdefault(15408, set()).update(find(lambda n, S: 'Scorpid' in n and lvl(S) >= 50))
MOB_ITEMS.setdefault(7286, set()).update(find(lambda n, S: re.search(r'Black (Dragon )?Whelp', n) is not None))
MOB_ITEMS.setdefault(7287, set()).update(find(lambda n, S: re.search(r'(Red|Crimson) (Dragon )?Whelp', n) is not None))
MOB_ITEMS.setdefault(7392, set()).update(find(lambda n, S: re.search(r'(Green|Dreaming) (Dragon )?Whelp', n) is not None))
MOB_ITEMS[8167].update(find(lambda n, S: re.search(r'Tortoise|Turtle|Snapjaw', n) and lvl(S) >= 35))

# ---------------------------------------------------------------- drop chances (wowhead-derived, shipped with Questie)
CHANCE = defaultdict(dict)  # itemID -> npcID -> percent
_dsrc = open(os.path.join(QDIR, 'support', 'Forever', 'DropTables', 'classicItemDrops.lua'), encoding='utf-8').read()
_cur = None
for _line in _dsrc[_dsrc.index('[[return {') + 9:].splitlines():
    _m = re.match(r'\s{4}\[(\d+)\] = \{', _line)
    if _m:
        _cur = int(_m.group(1))
        continue
    _m = re.match(r'\s{8}\[(\d+)\] = ([\d.]+)', _line)
    if _m and _cur:
        CHANCE[_cur][int(_m.group(1))] = float(_m.group(2))


def spawns_for(nid):
    sp = spawn_cache.get(nid)
    if sp is None:
        sp = npc_spawns(nid)
        spawn_cache[nid] = sp
    return sp


def usable_npc(nid):
    S = NPC.get(nid)
    if not S or not killable(S):    # friendly to a faction (neutral mobs stay)
        return False
    if (S.get(6) or 0) == 3:        # raid/world boss
        return False
    return bool(spawns_for(nid))    # has open-world spawns


# ---------------------------------------------------------------- general mob drops (anything tradeable)
DROP_CLASS = {0: 'goods', 5: 'goods', 7: 'goods', 15: 'goods', 9: 'recipe', 2: 'gear', 4: 'gear'}
SKIP = set(NODE_ITEMS) | set(MOB_ITEMS) | {2934, 2318, 783, 2319, 4232, 4234, 4235, 4304, 8169, 8170, 8171,
                                           2589, 2592, 4306, 4338, 14047}
WORLD_LIMIT = 40   # more droppers than this = treat as a world drop (level band instead of a mob list)
DROPS = {}
for iid in sorted(item_ids):
    if iid in SKIP:
        continue
    S = row('Item', iid)
    if not S:
        continue
    cls = S.get(12) or 0
    if cls not in DROP_CLASS or S.get(5):   # not a tradeable class, or starts a quest
        continue
    nd = field('Item', iid, 2) or []
    npcs = [n for n in nd if usable_npc(n)]
    if not npcs:
        continue
    if len(npcs) > WORLD_LIMIT:
        lv, zc = [], defaultdict(int)
        for n in npcs:
            Sx = NPC[n]
            lv.append(((Sx.get(4) or 0) + (Sx.get(5) or Sx.get(4) or 0)) / 2)
            for u, c in spawns_for(n).items():
                zc[u] += c
        lv.sort()
        lo, hi = int(lv[int(len(lv) * 0.1)]), int(round(lv[int(len(lv) * 0.9)]))
        ch = sorted(CHANCE[iid].values()) if iid in CHANCE else []
        DROPS[iid] = {'cls': DROP_CLASS[cls], 'world': (max(1, lo), max(lo, hi), len(npcs)),
                      'zones': dict(sorted(zc.items(), key=lambda x: -x[1])[:12]),
                      'chance': ch[len(ch) // 2] if ch else None}
    else:
        DROPS[iid] = {'cls': DROP_CLASS[cls], 'npcs': sorted(npcs)}


# ---------------------------------------------------------------- CMaNGOS (optional): chances, more drops, filters
CM = None
if len(sys.argv) > 3:
    sys.path.insert(0, HERE)
    from cmangos import Loot
    CM = Loot(sys.argv[3])
    print('CMaNGOS: creatures', len(CM.creature), 'items', len(CM.items))

RULE_ITEMS = {2934, 2318, 783, 2319, 4232, 4234, 4235, 4304, 8169, 8170, 8171, 2589, 2592, 4306, 4338, 14047}
RULE_CHANCE = defaultdict(dict)   # leather / cloth: item -> npc -> % (any npc, used for tooltips on that mob)
CM_AGG = {}                       # item -> {'n': [(npc, pct)] or None, 'lv': [...], 'pct': [...], 'z': {map: n}}


def tradeable(iid):
    """False for bind-on-pickup, quest and grey (vendor trash) items when CMaNGOS knows the item."""
    if not CM or iid not in CM.items:
        return True
    quality, bonding = CM.items[iid]
    return bonding not in (1, 4) and (quality or 0) >= 1


if CM:
    for nid in [n for n in NPC if usable_npc(n)]:
        loot, skin, _ = CM.creature_probs(nid)
        Sx = NPC[nid]
        lvl = ((Sx.get(4) or 0) + (Sx.get(5) or Sx.get(4) or 0)) / 2
        for table in (loot, skin):
            for it, pct in table.items():
                if pct < 0.01:
                    continue
                if it in RULE_ITEMS:
                    RULE_CHANCE[it][nid] = max(RULE_CHANCE[it].get(nid, 0), pct)
                    continue
                a = CM_AGG.get(it)
                if a is None:
                    a = {'n': [], 'lv': [], 'pct': [], 'z': defaultdict(int)}
                    CM_AGG[it] = a
                if a['n'] is not None:
                    a['n'].append((nid, pct))
                    if len(a['n']) > WORLD_LIMIT:
                        a['n'] = None
                a['lv'].append(lvl)
                a['pct'].append(pct)
                for u, c in spawns_for(nid).items():
                    a['z'][u] += c

    def cm_world(a):
        lv = sorted(a['lv'])
        lo, hi = int(lv[int(len(lv) * 0.1)]), int(round(lv[int(len(lv) * 0.9)]))
        return (max(1, lo), max(lo, hi), len(lv)), dict(sorted(a['z'].items(), key=lambda x: -x[1])[:12])

    # drop what cannot be sold; give Questie world drops a chance; add drops Questie does not list
    for iid in list(DROPS):
        if not tradeable(iid):
            del DROPS[iid]
    # world drops (greens, scrolls) that Questie ties to a handful of mobs while CMaNGOS has them on hundreds
    widened = 0
    for iid, d in DROPS.items():
        a = CM_AGG.get(iid)
        if 'npcs' in d and a and a['n'] is None and len(a['lv']) >= 3 * len(d['npcs']):
            w, z = cm_world(a)
            DROPS[iid] = {'cls': d['cls'], 'world': w, 'zones': z, 'chance': None}
            widened += 1
    print('CMaNGOS: mob lists turned into world drops', widened)
    added = 0
    for iid, a in CM_AGG.items():
        if iid in DROPS or iid in SKIP or iid not in item_ids or not tradeable(iid):
            continue
        S = row('Item', iid)
        cls = (S.get(12) or 0) if S else None
        if cls not in DROP_CLASS or S.get(5):
            continue
        if a['n'] is not None:
            DROPS[iid] = {'cls': DROP_CLASS[cls], 'npcs': sorted(n for n, _ in a['n'])}
        else:
            w, z = cm_world(a)
            DROPS[iid] = {'cls': DROP_CLASS[cls], 'world': w, 'zones': z, 'chance': None}
        added += 1
    for iid, d in DROPS.items():
        if 'world' in d and not d['chance'] and iid in CM_AGG:
            pc = sorted(CM_AGG[iid]['pct'])
            d['chance'], d['csrc'] = pc[len(pc) // 2], 'c'
    print('CMaNGOS: drops added', added, 'total drops', len(DROPS))

# ---------------------------------------------------------------- npc table (everything referenced)
NPC_OUT = {}
ITEM_NPCS = {}


def add_npc(nid):
    if nid in NPC_OUT:
        return True
    if not usable_npc(nid):
        return False
    S = NPC[nid]
    sp = spawns_for(nid)
    main = max(sp.items(), key=lambda x: x[1])[0]
    NPC_OUT[nid] = (S.get(4) or 0, S.get(5) or S.get(4) or 0, S.get(6) or 0, main, sum(sp.values()),
                    npc_name(nid), ru_names.get(nid))
    return True


for iid, nids in MOB_ITEMS.items():
    keep = [n for n in sorted(nids) if add_npc(n)]
    if keep:
        ITEM_NPCS[iid] = keep
    else:
        print('no open-world npcs for', iid)
for iid, d in DROPS.items():
    for n in d.get('npcs', []):
        add_npc(n)

CHANCE_OUT = {}
for iid, nids in list(ITEM_NPCS.items()) + [(i, d['npcs']) for i, d in DROPS.items() if 'npcs' in d]:
    if iid in CHANCE:
        c = {n: CHANCE[iid][n] for n in nids if n in CHANCE[iid]}
        if c:
            CHANCE_OUT[iid] = c

CHANCE_C = {}   # CMaNGOS chances for listed mobs where Questie has none
if CM:
    for iid, nids in list(ITEM_NPCS.items()) + [(i, d['npcs']) for i, d in DROPS.items() if 'npcs' in d]:
        c = {}
        for n in nids:
            if n in CHANCE_OUT.get(iid, {}):
                continue
            loot, skin, _ = CM.creature_probs(n)
            pct = max(loot.get(iid, 0), skin.get(iid, 0))
            if pct >= 0.01:
                c[n] = pct
        if c:
            CHANCE_C[iid] = c

# ---------------------------------------------------------------- coordinates for the world map
PACK = [chr(c) for c in range(35, 127) if c != 92]   # 91 printable chars, no quote/backslash


def enc(v):
    v = max(0, min(1000, v))
    return PACK[v // 91] + PACK[v % 91]


def pack(points, cap):
    pts = sorted(set(points))
    if len(pts) > cap:
        step = len(pts) / cap
        pts = [pts[int(i * step)] for i in range(cap)]
    return ''.join(enc(x) + enc(y) for x, y in pts)


NPC_COORDS = {}
for nid in NPC_OUT:
    sp = field('Npc', nid, 7)
    per = defaultdict(list)
    if isinstance(sp, dict):
        for area, pts in sp.items():
            u = to_map(area)
            if u:
                per[u].extend(coords_of(pts))
    if per:
        NPC_COORDS[nid] = {u: pack(p, 30) for u, p in per.items() if p}

used_nodes = set()
for iid in ITEM_ZONES:
    used_nodes.update(ITEM_NODES[iid])
NODE_OUT = {n: {u: pack(p, 400) for u, p in NODE_COORDS[n].items() if p} for n in sorted(used_nodes) if n in NODE_COORDS}

# ---------------------------------------------------------------- emit
def lstr(s):
    if s is None:
        return 'nil'
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


L = []
L.append('-- GENERATED from QuestieDB (Forever flavor) by tools/gen.py. Do not edit by hand.')
L.append('-- Coordinates are packed: 4 chars per point, see ns.UnpackCoords in Map.lua.')
L.append('local _, ns = ...')
L.append('ns.GEN = {}')
L.append('-- [uiMapID] = {minLevel, maxLevel, englishName, faction}')
L.append('ns.GEN.zones = {')
for u in sorted(ZONES):
    lo, hi, nm, fac, n = ZONES[u]
    L.append('  [%d] = {%s, %s, %s, "%s"}, -- samples %d' % (u, lo if lo is not None else 'nil',
             hi if hi is not None else 'nil', lstr(nm), fac, n))
L.append('}')
L.append('-- [itemID] = { skill = minNodeSkill, zones = {[uiMapID] = nodeSpawnCount}, nodes = {nodeName, ...} }')
L.append('ns.GEN.nodeItems = {')
for iid in sorted(ITEM_ZONES):
    z = ', '.join('[%d]=%d' % (u, c) for u, c in sorted(ITEM_ZONES[iid].items(), key=lambda x: -x[1]))
    nodes = ', '.join(lstr(n) for n in ITEM_NODES[iid])
    L.append('  [%d] = {skill=%d, zones={%s}, nodes={%s}},' % (iid, ITEM_SKILL[iid], z, nodes))
L.append('}')
L.append('-- [nodeName] = {[uiMapID] = packedCoords}')
L.append('ns.GEN.nodeCoords = {')
for n, per in NODE_OUT.items():
    L.append('  [%s] = {%s},' % (lstr(n), ', '.join('[%d]=%s' % (u, lstr(p)) for u, p in sorted(per.items()))))
L.append('}')
L.append('-- gathering nodes: [enName] = {skill = required skill, ru = {russian names}}')
L.append('ns.GEN.nodeInfo = {')
for n in sorted(NODE_SKILL):
    ru = ', '.join(lstr(x) for x in sorted(NODE_RU.get(n, ())))
    L.append('  [%s] = {skill=%d, ru={%s}},' % (lstr(n), NODE_SKILL[n], ru))
L.append('}')
L.append('-- [npcID] = {minLevel, maxLevel, rank, uiMapID, spawnCount, enName, ruName}')
L.append('ns.GEN.npcs = {')
for nid in sorted(NPC_OUT):
    a, b, r, u, c, en, ru = NPC_OUT[nid]
    L.append('  [%d] = {%d, %d, %d, %d, %d, %s, %s},' % (nid, a, b, r, u, c, lstr(en), lstr(ru)))
L.append('}')
L.append('-- [npcID] = {[uiMapID] = packedCoords}')
L.append('ns.GEN.npcCoords = {')
for nid in sorted(NPC_COORDS):
    per = NPC_COORDS[nid]
    L.append('  [%d] = {%s},' % (nid, ', '.join('[%d]=%s' % (u, lstr(p)) for u, p in sorted(per.items()))))
L.append('}')
L.append('-- gathering-related items dropped/skinned from specific mobs: [itemID] = {npcID, ...}')
L.append('ns.GEN.itemNpcs = {')
for iid in sorted(ITEM_NPCS):
    L.append('  [%d] = {%s},' % (iid, ', '.join(str(n) for n in ITEM_NPCS[iid])))
L.append('}')
L.append('-- other tradeable mob drops: c = goods|recipe|gear; n = mob list, or w = {minLevel, maxLevel, mobCount} for')
L.append('-- world drops (z = zones with most droppers, ch = median drop chance %)')
L.append('ns.GEN.drops = {')
for iid in sorted(DROPS):
    d = DROPS[iid]
    if 'npcs' in d:
        L.append('  [%d] = {c="%s", n={%s}},' % (iid, d['cls'], ','.join(str(n) for n in d['npcs'])))
    else:
        lo, hi, cnt = d['world']
        z = ','.join('[%d]=%d' % (u, c) for u, c in d['zones'].items())
        ch = (', ch=%.3g' % d['chance']) if d['chance'] else ''
        if d.get('csrc'):
            ch += ', cs="c"'
        L.append('  [%d] = {c="%s", w={%d,%d,%d}, z={%s}%s},' % (iid, d['cls'], lo, hi, cnt, z, ch))
L.append('}')
L.append('-- drop chance in percent (wowhead data shipped with Questie): [itemID] = {[npcID] = pct}')
L.append('ns.GEN.chance = {')
for iid in sorted(CHANCE_OUT):
    L.append('  [%d] = {%s},' % (iid, ','.join('[%d]=%.1f' % (n, p) for n, p in sorted(CHANCE_OUT[iid].items()))))
L.append('}')
L.append('-- drop chance in percent from CMaNGOS classic-db (vanilla 1.12 data): [itemID] = {[npcID] = pct}')
L.append('ns.GEN.chanceC = {')
for iid in sorted(CHANCE_C):
    L.append('  [%d] = {%s},' % (iid, ','.join('[%d]=%.3g' % (n, p) for n, p in sorted(CHANCE_C[iid].items()))))
L.append('}')
L.append('-- leather (skinning) and cloth chances per mob from CMaNGOS: [itemID] = {[npcID] = pct}')
L.append('ns.GEN.ruleChance = {')
for iid in sorted(RULE_CHANCE):
    L.append('  [%d] = {%s},' % (iid, ','.join('[%d]=%.3g' % (n, p) for n, p in sorted(RULE_CHANCE[iid].items()))))
L.append('}')
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(L) + '\n')

print('zones', len(ZONES), 'nodeItems', len(ITEM_ZONES), 'nodes', len(NODE_OUT), 'npcs', len(NPC_OUT),
      'itemNpcs', len(ITEM_NPCS), 'drops', len(DROPS), 'world', sum(1 for d in DROPS.values() if 'world' in d),
      'chance items', len(CHANCE_OUT), 'cmangos chance items', len(CHANCE_C), 'rule chance items', len(RULE_CHANCE))
from collections import Counter
print('drop classes', Counter(d['cls'] for d in DROPS.values()))
