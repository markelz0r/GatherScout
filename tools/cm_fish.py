"""Read fishing data from a CMaNGOS classic-db dump: per-area catch probabilities (references resolved, loot groups
rolled like the server does), zone fishing skill, fishing-hole objects and their catches, item info.
Usage: python -I cm_fish.py <ClassicDB.sql.gz> <out.json>"""
import sys, gzip, re, json
from collections import defaultdict

SRC, OUT = sys.argv[1], sys.argv[2]
WANT = {'fishing_loot_template', 'reference_loot_template', 'skill_fishing_base_level', 'gameobject_template',
        'gameobject_loot_template', 'item_template', 'pool_template', 'pool_gameobject', 'gameobject'}

def split_values(s):
    """Split the VALUES (...),(...) part of an INSERT into rows of python values."""
    rows, row, cur, i, n, inq = [], [], [], 0, len(s), False
    while i < n:
        c = s[i]
        if inq:
            if c == '\\':
                cur.append(s[i + 1]); i += 2; continue
            if c == "'":
                if i + 1 < n and s[i + 1] == "'":
                    cur.append("'"); i += 2; continue
                inq = False; i += 1; continue
            cur.append(c); i += 1; continue
        if c == "'":
            inq = True; cur.append('\x00'); i += 1; continue
        if c == '(':
            row, cur = [], []; i += 1; continue
        if c == ',' and row is not None:
            row.append(''.join(cur)); cur = []; i += 1; continue
        if c == ')':
            row.append(''.join(cur)); rows.append(row); row, cur = None, []; i += 1; continue
        if row is None:
            i += 1; continue
        cur.append(c); i += 1
    out = []
    for r in rows:
        vals = []
        for v in r:
            if v.startswith('\x00'):
                vals.append(v[1:])
            elif v.strip().upper() == 'NULL':
                vals.append(None)
            else:
                try:
                    vals.append(int(v))
                except ValueError:
                    try: vals.append(float(v))
                    except ValueError: vals.append(v)
        out.append(vals)
    return out

cols, data = {}, defaultdict(list)
cur = None
with gzip.open(SRC, 'rt', encoding='utf-8', errors='replace') as f:
    for line in f:
        m = re.match(r'CREATE TABLE `?(\w+)`?', line)
        if m:
            cur = m.group(1) if m.group(1) in WANT else None
            if cur: cols[cur] = []
            continue
        if cur:
            mc = re.match(r'\s*`(\w+)`', line)
            if mc: cols[cur].append(mc.group(1))
            if line.startswith(')'): cur = None
            continue
        m = re.match(r'INSERT INTO `?(\w+)`? VALUES (.*);\s*$', line, re.S)
        if m and m.group(1) in WANT:
            data[m.group(1)].extend(split_values(m.group(2)))

def table(name):
    c = cols[name]
    return [dict(zip(c, r)) for r in data[name]]

LOOT = {}
for name in ('fishing_loot_template', 'reference_loot_template', 'gameobject_loot_template'):
    t = defaultdict(list)
    for r in table(name):
        t[r['entry']].append(r)
    LOOT[name] = t

def probs(name, entry, depth=0):
    """item -> probability (0..1) that one roll of this loot template yields at least one of it."""
    rows = LOOT[name].get(entry, [])
    res = defaultdict(float)
    def add(item, p):
        res[item] = 1 - (1 - res[item]) * (1 - p)
    groups = defaultdict(list)
    for r in rows:
        if r['ChanceOrQuestChance'] is not None and r['ChanceOrQuestChance'] < 0:
            continue  # quest drops
        if r['groupid']:
            groups[r['groupid']].append(r)
            continue
        p = (r['ChanceOrQuestChance'] or 0) / 100
        if r['mincountOrRef'] < 0:
            if depth < 4:
                sub = probs('reference_loot_template', -r['mincountOrRef'], depth + 1)
                times = max(1, r['maxcount'] or 1)
                for it, q in sub.items():
                    add(it, p * (1 - (1 - q) ** times))
        else:
            add(r['item'], p)
    for g, grows in groups.items():
        explicit = [r for r in grows if (r['ChanceOrQuestChance'] or 0) > 0]
        equal = [r for r in grows if not r['ChanceOrQuestChance']]
        rest = max(0.0, 1 - sum(r['ChanceOrQuestChance'] for r in explicit) / 100)
        for r in grows:
            p = (r['ChanceOrQuestChance'] / 100) if r in explicit else (rest / len(equal) if equal else 0)
            if r['mincountOrRef'] < 0:
                if depth < 4:
                    for it, q in probs('reference_loot_template', -r['mincountOrRef'], depth + 1).items():
                        add(it, p * q)
            else:
                add(r['item'], p)
    return res

items = {r['entry']: r for r in table('item_template')}
fish_area = {e: dict(probs('fishing_loot_template', e)) for e in LOOT['fishing_loot_template']}
skill = {r['entry']: r['skill'] for r in table('skill_fishing_base_level')}
holes = {}
for r in table('gameobject_template'):
    if r['type'] == 25:
        holes[r['entry']] = {'name': r['name'], 'loot': dict(probs('gameobject_loot_template', r['data1'])) if r['data1'] else {}}
spawns = defaultdict(list)
for r in table('gameobject'):
    if r['id'] in holes:
        spawns[r['id']].append((r['map'], round(r['position_x'], 1), round(r['position_y'], 1)))
pools = table('pool_template')
pool_go = table('pool_gameobject')
pool_desc = {p['entry']: p.get('description') for p in pools}
hole_pool_desc = defaultdict(set)
for pg in pool_go:
    d = pool_desc.get(pg.get('pool_entry'))
    if d and pg.get('guid') is not None:
        hole_pool_desc[pg['guid']].add(d)
go_guid_hole = {r['guid']: r['id'] for r in table('gameobject') if r['id'] in holes}
hole_desc = defaultdict(set)
for guid, hid in go_guid_hole.items():
    for d in hole_pool_desc.get(guid, ()):
        hole_desc[hid].add(d)

def iteminfo(i):
    it = items.get(i)
    if not it: return None
    return {'name': it['name'], 'q': it['Quality'], 'bond': it.get('bonding'), 'class': it['class'], 'sub': it['subclass'],
            'sell': it['SellPrice'], 'stack': it['stackable']}

json.dump({'area': fish_area, 'skill': skill,
           'holes': {k: dict(v, spawns=spawns.get(k, []), pools=sorted(hole_desc.get(k, ()))) for k, v in holes.items()},
           'items': {i: iteminfo(i) for i in set(i for a in fish_area.values() for i in a) | set(i for h in holes.values() for i in h['loot'])}},
          open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
print('areas', len(fish_area), 'skill', len(skill), 'holes', len(holes), 'items', len(set(i for a in fish_area.values() for i in a)))
