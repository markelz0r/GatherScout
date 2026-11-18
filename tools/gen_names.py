"""Generate Data/Names/<locale>.lua: mob, gathering-node and fishing-school names in every client language, taken by
ID from QuestieDB's l10n data (the same source as the English/Russian names in Generated.lua).
Run after gen.py (and gen_fishing.py): it names every mob in Data/Generated.lua and every fishing school.

Fishing schools: QuestieDB's Forever data names them only in koKR and zhTW. The later flavours in the same QuestieDB
folder (QuestieDB_Cata.toc, then QuestieDB_Mists.toc) name them in every language, by the same object IDs. There a
school is split into variants under the old IDs ("Lesser/Sparse/Teeming/Abundant ... School"), while the Forever
client shows the plain name for all of them, so the name comes from the ID whose English name there is still ours.
A fish renamed since then (ruRU Firefin Snapper: "Огнеперый снеппер" became "Огнеперый луциан") gets its Forever
name back inside the school name ("Косяк огнеперого снеппера", as the ruRU client shows it); the later spelling
stays as a second name to match.
Usage: python -I tools/gen_names.py <QuestieDB dir> <addon dir>"""
import sys, os, re, base64, zlib
from collections import Counter

sys.stdout.reconfigure(encoding='utf-8')
QDIR, ADDON = sys.argv[1], sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, 'qdb.py'), encoding='utf-8').read().split('def main')[0])  # cbor_decode, dec

LOCALES = ('deDE', 'esES', 'esMX', 'frFR', 'koKR', 'ptBR', 'ruRU', 'zhCN', 'zhTW')
LATER = ('Cata', 'Mists')  # QuestieDB flavours that name the fishing schools in every language
rx = re.compile(r'^## (X-[^:]+): ?(.*)$')

def read_toc(flavour):
    out = {}
    with open(os.path.join(QDIR, 'QuestieDB_%s.toc' % flavour), encoding='utf-8') as f:
        for line in f:
            m = rx.match(line.rstrip('\n'))
            if m:
                out[m.group(1)] = m.group(2)
    return out

kv = read_toc('Forever')

def get(key, toc=None):
    toc = kv if toc is None else toc
    v = toc.get(key)
    if v is None:
        return None
    m = re.match(r'^~(\d+)~$', v)
    if m:
        v = ''.join(toc[key + '-' + str(p)] for p in range(1, int(m.group(1)) + 1))
    return v

def unz(raw):
    for wbits in (15, -15, 31):
        try:
            return zlib.decompress(raw, wbits)
        except Exception:
            pass
    raise RuntimeError('zlib')

def ids_of(ent, toc=None):
    return cbor_decode(unz(base64.b64decode(get('X-%s-IDS' % ent, toc))))[0]

def txt(v):
    return v.decode('utf-8', 'replace') if isinstance(v, bytes) else v

def l10n(loc, ent, ids, toc=None):
    blob = get('X-l10n-%s-%s' % (loc, ent), toc)
    if not blob:
        return {}
    d = cbor_decode(unz(base64.b64decode(blob)))[0]
    names = d[0]  # Lua table aligned with the IDS list: a dense list, or a sparse table keyed by 1-based index
    out = {}
    for i, eid in enumerate(ids):
        if isinstance(names, dict):
            v = names.get(i + 1)
        else:
            v = names[i] if i < len(names) else None
        if v:
            out[eid] = txt(v)
    return out

def obj_name(oid, toc=None):
    s = get('X-Object-%d-S' % oid, toc)
    if not s:
        return None
    S = dec(s)
    if isinstance(S, list):
        S = {i + 1: v for i, v in enumerate(S)}
    return txt(S.get(1))

gen = open(os.path.join(ADDON, 'Data', 'Generated.lua'), encoding='utf-8').read()
npc_block = gen.split('ns.GEN.npcs = {', 1)[1].split('\n}', 1)[0]
NPCS = set(int(x) for x in re.findall(r'^\s*\[(\d+)\] = \{', npc_block, re.M))
node_block = gen.split('ns.GEN.nodeInfo = {', 1)[1].split('\n}', 1)[0]
NODES = set(re.findall(r'^\s*\["((?:[^"\\]|\\.)*)"\] = \{', node_block, re.M))
# fishing schools (Data/Fishing.lua) are game objects too; what each gives tells which fish it is named after
POOLS, POOL_ITEMS = set(), {}
fishing_path = os.path.join(ADDON, 'Data', 'Fishing.lua')
if os.path.exists(fishing_path):
    fishing = open(fishing_path, encoding='utf-8').read()
    pool_block = fishing.split('G.fishPools = {', 1)[1].split('\n}', 1)[0]
    POOLS = set(re.findall(r'^\s*\["((?:[^"\\]|\\.)*)"\] = \{', pool_block, re.M))
    fish_block = fishing.split('G.fish = {', 1)[1].split('\n}', 1)[0]
    for item, rest in re.findall(r'^\s*\[(\d+)\] = \{(.*)$', fish_block, re.M):
        for pool in re.findall(r'\["((?:[^"\\]|\\.)*)"\]=', rest.split(' -- ')[0]):
            POOL_ITEMS.setdefault(pool, set()).add(int(item))
    NODES |= POOLS
print('npcs in addon:', len(NPCS), 'node names:', len(NODES), 'of them fishing schools:', len(POOLS))

npc_ids = ids_of('Npc')
obj_ids = ids_of('Object')
item_ids = ids_of('Item')
node_objs = {}
for oid in obj_ids:
    name = obj_name(oid)
    if name in NODES:
        node_objs[oid] = name
print('node objects:', len(node_objs))
pool_objs = {}  # school -> its object IDs
for oid, en in node_objs.items():
    if en in POOLS:
        pool_objs.setdefault(en, []).append(oid)

later_cache = {}
def later(flavour):
    """School names in a later QuestieDB flavour: (school -> its plain-named object IDs,
    locale -> object ID -> name, locale -> item ID -> name)."""
    if flavour not in later_cache:
        toc = read_toc(flavour)
        oids, iids = ids_of('Object', toc), ids_of('Item', toc)
        plain = {en: [o for o in oids_ if obj_name(o, toc) == en] for en, oids_ in pool_objs.items()}
        later_cache[flavour] = (plain, {loc: l10n(loc, 'Object', oids, toc) for loc in LOCALES},
                                {loc: l10n(loc, 'Item', iids, toc) for loc in LOCALES})
        print('  read QuestieDB_%s.toc for fishing school names' % flavour)
    return later_cache[flavour]

def respell(name, was, now):
    """`name` with a fish renamed back from `was` (its later name) to `now` (its Forever name), by the part of the two
    that differs: a word stem, so it also matches a declined form ("огнеперого луциана" -> "огнеперого снеппера")."""
    if not was or not now or was.lower() == now.lower():
        return name
    a = 0
    while a < min(len(was), len(now)) and was[a] == now[a]:
        a += 1
    b = 0
    while b < min(len(was), len(now)) - a and was[-1 - b] == now[-1 - b]:
        b += 1
    old, new = was[a:len(was) - b], now[a:len(now) - b]
    if len(old) < 2 or old not in name:
        return name
    return name.replace(old, new)

def school_names(loc, en, objL, itemL):
    """(the name the game shows, every name to match) for fishing school `en` in locale `loc`."""
    forever = [objL[o] for o in pool_objs.get(en, ()) if objL.get(o)]
    shown = Counter(forever).most_common(1)[0][0] if forever else None
    names = list(dict.fromkeys(forever))
    for flavour in LATER:
        plain, objLL, itemLL = later(flavour)
        n = next((objLL[loc][o] for o in plain.get(en, ()) if objLL[loc].get(o)), None)
        if not n:
            continue
        fixed = n
        for item in sorted(POOL_ITEMS.get(en, ())):
            fixed = respell(fixed, itemLL[loc].get(item), itemL.get(item))
        if fixed != n:
            print('  %s %s: "%s" -> "%s"' % (loc, en, n, fixed))
        shown = shown or fixed
        names += [x for x in (fixed, n) if x not in names]
        break
    return shown, names

def lstr(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ') + '"'

os.makedirs(os.path.join(ADDON, 'Data', 'Names'), exist_ok=True)
for loc in LOCALES:
    npcL = {k: v for k, v in l10n(loc, 'Npc', npc_ids).items() if k in NPCS}
    objL = l10n(loc, 'Object', obj_ids)
    itemL = l10n(loc, 'Item', item_ids) if POOLS else {}
    nodeL = {}
    for oid, en in node_objs.items():
        n = objL.get(oid)
        if n and n != en:
            nodeL.setdefault(n, en)
    poolL = {}
    for en in sorted(POOLS):
        shown, names = school_names(loc, en, objL, itemL)
        for n in names:
            if n != en:
                nodeL.setdefault(n, en)
        if shown and shown != en:
            poolL[en] = shown
    out = ['-- GENERATED from QuestieDB (Forever; Cata/Mists for fishing schools) l10n data by tools/gen_names.py.',
           '-- Do not edit by hand. Mob, gathering-node and fishing-school names in %s, by ID;' % loc,
           '-- English names stay in Generated.lua and Fishing.lua.',
           'if GetLocale() ~= "%s" then return end' % loc, 'local _, ns = ...', '',
           '-- [npcID] = name', 'ns.GEN.npcL = {']
    for k in sorted(npcL):
        out.append('  [%d] = %s,' % (k, lstr(npcL[k])))
    out.append('}')
    out.append('')
    out.append('-- [node or school name as the game shows it] = English name (key of ns.GEN.nodeInfo or ns.GEN.fishPools)')
    out.append('ns.GEN.nodeL = {')
    for k in sorted(nodeL):
        out.append('  [%s] = %s,' % (lstr(k), lstr(nodeL[k])))
    out.append('}')
    out.append('')
    out.append('-- [English school name (key of ns.GEN.fishPools)] = the name the game shows')
    out.append('ns.GEN.poolL = {')
    for k in sorted(poolL):
        out.append('  [%s] = %s,' % (lstr(k), lstr(poolL[k])))
    out.append('}')
    open(os.path.join(ADDON, 'Data', 'Names', loc + '.lua'), 'w', encoding='utf-8', newline='\n').write('\n'.join(out) + '\n')
    print(loc, 'npcs %d/%d' % (len(npcL), len(NPCS)), 'nodes %d (of %d node names)' % (len(set(nodeL.values())), len(NODES)),
          'schools %d/%d' % (len(poolL), len(POOLS)))
