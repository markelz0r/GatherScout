"""Generate Data/Names/<locale>.lua: mob and gathering-node names in every client language, taken by ID from
QuestieDB's l10n data (the same source as the English/Russian names in Generated.lua).
Run after gen.py (and gen_fishing.py): it names every mob in Data/Generated.lua and every fishing school.
Usage: python -I tools/gen_names.py <QuestieDB dir> <addon dir>"""
import sys, os, re, base64, zlib

QDIR, ADDON = sys.argv[1], sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, 'qdb.py'), encoding='utf-8').read().split('def main')[0])  # cbor_decode, dec

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

def unz(raw):
    for wbits in (15, -15, 31):
        try:
            return zlib.decompress(raw, wbits)
        except Exception:
            pass
    raise RuntimeError('zlib')

def ids_of(ent):
    return cbor_decode(unz(base64.b64decode(get('X-%s-IDS' % ent))))[0]

def txt(v):
    return v.decode('utf-8', 'replace') if isinstance(v, bytes) else v

def l10n(loc, ent, ids):
    blob = get('X-l10n-%s-%s' % (loc, ent))
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

gen = open(os.path.join(ADDON, 'Data', 'Generated.lua'), encoding='utf-8').read()
npc_block = gen.split('ns.GEN.npcs = {', 1)[1].split('\n}', 1)[0]
NPCS = set(int(x) for x in re.findall(r'^\s*\[(\d+)\] = \{', npc_block, re.M))
node_block = gen.split('ns.GEN.nodeInfo = {', 1)[1].split('\n}', 1)[0]
NODES = set(re.findall(r'^\s*\["((?:[^"\\]|\\.)*)"\] = \{', node_block, re.M))
# fishing schools (Data/Fishing.lua) are game objects too
fishing_path = os.path.join(ADDON, 'Data', 'Fishing.lua')
if os.path.exists(fishing_path):
    pool_block = open(fishing_path, encoding='utf-8').read().split('G.fishPools = {', 1)[1].split('\n}', 1)[0]
    NODES |= set(re.findall(r'^\s*\["((?:[^"\\]|\\.)*)"\] = \{', pool_block, re.M))
print('npcs in addon:', len(NPCS), 'node names:', len(NODES))

npc_ids = ids_of('Npc')
obj_ids = ids_of('Object')
node_objs = {}
for oid in obj_ids:
    s = get('X-Object-%d-S' % oid)
    if not s:
        continue
    S = dec(s)
    if isinstance(S, list):
        S = {i + 1: v for i, v in enumerate(S)}
    name = txt(S.get(1))
    if name in NODES:
        node_objs[oid] = name
print('node objects:', len(node_objs))

def lstr(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ') + '"'

os.makedirs(os.path.join(ADDON, 'Data', 'Names'), exist_ok=True)
for loc in ('deDE', 'esES', 'esMX', 'frFR', 'koKR', 'ptBR', 'ruRU', 'zhCN', 'zhTW'):
    npcL = {k: v for k, v in l10n(loc, 'Npc', npc_ids).items() if k in NPCS}
    objL = l10n(loc, 'Object', obj_ids)
    nodeL = {}
    for oid, en in node_objs.items():
        n = objL.get(oid)
        if n and n != en:
            nodeL.setdefault(n, en)
    out = ['-- GENERATED from QuestieDB (Forever) l10n data by tools/gen_names.py. Do not edit by hand.',
           '-- Mob and gathering-node names in %s, by ID; English names stay in Generated.lua.' % loc,
           'if GetLocale() ~= "%s" then return end' % loc, 'local _, ns = ...', '',
           '-- [npcID] = name', 'ns.GEN.npcL = {']
    for k in sorted(npcL):
        out.append('  [%d] = %s,' % (k, lstr(npcL[k])))
    out.append('}')
    out.append('')
    out.append('-- [node name as the game shows it] = English node name (key of ns.GEN.nodeInfo)')
    out.append('ns.GEN.nodeL = {')
    for k in sorted(nodeL):
        out.append('  [%s] = %s,' % (lstr(k), lstr(nodeL[k])))
    out.append('}')
    open(os.path.join(ADDON, 'Data', 'Names', loc + '.lua'), 'w', encoding='utf-8', newline='\n').write('\n'.join(out) + '\n')
    print(loc, 'npcs %d/%d' % (len(npcL), len(NPCS)), 'nodes %d (of %d node names)' % (len(set(nodeL.values())), len(NODES)))
