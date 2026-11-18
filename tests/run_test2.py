"""v2 smoke test: full scan with drops, chances, mob tooltip, card, world map. Usage: run_test2.py <addon> <harness> [auctionator] [locale]"""
import sys, re
from lupa import LuaRuntime
sys.stdout.reconfigure(encoding='utf-8')
ADDON, HARNESS = sys.argv[1], sys.argv[2]
OPTS = sys.argv[3:]  # any order: "auctionator", a client locale (default ruRU; enUS, deDE, ...)
LOCALE = next((a for a in OPTS if re.fullmatch(r'[a-z]{2}[A-Z]{2}', a)), 'ruRU')
for a in OPTS:
    if a != 'auctionator' and a != LOCALE:
        sys.exit('unknown option: %s' % a)
L = LuaRuntime(unpack_returned_tuples=True)
L.execute('TEST_LOCALE = "%s"' % LOCALE)
L.execute(open(HARNESS, encoding='utf-8').read())
if 'auctionator' in OPTS:
    L.execute('InstallAuctionator()')


def strip(s):
    s = str(s)
    s = re.sub(r'\|c[0-9a-fA-F]{8}', '', s).replace('|r', '')
    s = re.sub(r'\|TInterface\\MoneyFrame\\UI-(Gold|Silver|Copper)Icon[^|]*\|t', lambda m: {'Gold': 'g', 'Silver': 's', 'Copper': 'c'}[m.group(1)], s)
    return re.sub(r'\|T[^|]*\|t', '[i]', s)


def flush():
    for line in L.eval('LOGS()').values():
        print('  [chat]', strip(line))


ns = L.eval('{}')
files = [l.strip() for l in open(ADDON + '/GatherScout.toc', encoding='utf-8') if l.strip() and not l.startswith('#')]
loader = L.eval('function(src, name, ns) local f = assert(load(src, "@" .. name)); f("GatherScout", ns) end')
for f in files:
    if f.endswith('.xml'):
        continue
    loader(open(ADDON + '/' + f.replace(chr(92), '/'), encoding='utf-8').read(), f, ns)
fire, tick = L.eval('FireEvent'), L.eval('Tick')
fire('ADDON_LOADED', 'GatherScout'); fire('PLAYER_LOGIN'); tick(2); flush()
L.execute('PLAYER_LEVEL = 40')
drops = ns.GEN.drops
print('drops in data:', len(drops), 'DROP index:', len(ns.DROP))

# AH contents: all MAT + some drops
repl = L.eval('REPL')
k = 1
def put(item, count, unit):
    global k
    repl[k] = L.table(item, count, unit * count)
    k += 1
for id in list(ns.MAT.keys()):
    put(id, 20, 500 + id % 300)
for id, unit in [(12207, 9000), (12811, 25000), (5637, 300), (3182, 4000), (4337, 9000), (2409, 15000), (10285, 7000)]:
    for j in range(3):
        put(id, 5, unit + j * 100)

print('== full scan (AH open, auto)')
fire('AUCTION_HOUSE_SHOW')
for _ in range(300):
    tick(1)
    if not ns.full.active and ns.Market().lastScan:
        break
flush()
res = ns.Compute()
rows = [res[i] for i in range(1, len(res) + 1)]
dr = [r for r in rows if r.m.drop]
print('rows', len(rows), 'drop rows', len(dr))
for r in sorted(dr, key=lambda r: -(r.value or 0)):
    print('  drop %-6s %-7s price=%s chance=%s guess=%s where=%s score=%s gain=%s' % (
        r.id, r.m.c, strip(ns.Money(r.price)), r.chance, r.chanceGuess, strip(ns.WhereText(r.best, r.id)) if r.best else None,
        r.scout, '%.2f' % r.best.gain if r.best else None))

print('== mob tooltip: a Giant Egg dropper')
npc = drops[12207].n[1]
n = ns.GEN.npcs[npc]
print('  npc', npc, n[6], n[7], 'lvl', n[1], n[2])
L.execute('MOB_GUID = "Creature-0-1-2-3-%d-1"; MOB_TYPE = CT.beast; MOB_LEVEL = %d' % (npc, n[1]))
ns.db.pins[12207] = True
ns.Invalidate(); tick(2)
lines = L.eval('FireUnitTooltip')(L.eval('MOB_GUID'))
for i in range(1, len(lines) + 1):
    print('   ', strip(lines[i]))
fire('NAME_PLATE_UNIT_ADDED', 'nameplate1')
print('  nameplate icon shown:', L.eval('TEST_PLATE.GatherScoutIcon and TEST_PLATE.GatherScoutIcon._shown'))

print('== learned chance: loot the same corpse twice + 5 more kills')
for j in range(6):
    L.execute('LOOT = { { id = 12207, guid = "Creature-0-1-2-3-%d-%d", qty = 1 } }' % (npc, 100 + j))
    fire('LOOT_OPENED')
    if j == 0:
        fire('LOOT_OPENED')  # reopened window must not double count
print('  kills', ns.db.learned.kills[npc], 'got', ns.db.learned.npc[npc][12207], 'chance ->', ns.DropChance(12207, npc))

print('== UI + card for a drop item')
ns.UI_Toggle(); tick(2)
ns.Card_Show(12207)
card = L.eval('GatherScoutCard')
print('  stats:\n    ' + strip(card.stats._text).replace('\n', '\n    '))
print('  where:\n    ' + strip(card.where._text).replace('\n', '\n    '))
search = L.eval('GatherScoutSearch')
search._text = 'item1220'
search._scripts.OnTextChanged(search)
print('  search applied without errors; frame count label:', strip(L.eval('GatherScoutFrame.count._text')))
search._text = ''
search._scripts.OnTextChanged(search)

print('== sorting by ScoutScore')
ns.S.minQty = 0  # the test AH has only a few units of each item: show every row
ns.Invalidate()
for desc in (True, False):
    ns.S.sortKey, ns.S.sortDesc = 'score', desc
    ns.UI_Refresh()
    view = ns.UI_View()
    vals = [view[i].value if view[i].value is not None else (-1 if view[i].best else -2) for i in range(1, len(view) + 1)]
    scores = [view[i].scout for i in range(1, len(view) + 1) if view[i].scout is not None]
    want = sorted(vals, reverse=desc)
    if vals != want or scores != sorted(scores, reverse=desc):
        sys.exit('FAIL: list not sorted by ScoutScore (desc=%s): %s' % (desc, scores[:20]))
    print('  desc=%s: %d rows in order, scores %s ... %s' % (desc, len(vals), scores[:5], scores[-3:]))
ns.S.sortKey, ns.S.sortDesc = 'score', True
ns.UI_Refresh()
ns.Card_Show(12207)
print('  card stats:\n    ' + strip(card.stats._text).replace('\n', '\n    '))

print('== world map')
ns.Map_Show(12207)
print('  map opened:', L.eval('WorldMapFrame._shown'), 'map', L.eval('CUR_MAP'), 'pins', len(L.eval('PINS')))
pins = L.eval('PINS')
if len(pins):
    p = pins[1]
    p.OnMouseEnter(p)
    gl = L.eval('GameTooltip._lines')
    print('  pin tooltip:', ' / '.join(strip(gl[i]) for i in range(1, len(gl) + 1)))
L.execute('CUR_MAP = 1415')
prov = L.eval('WorldMapFrame._provider')
prov.RefreshAllData(prov)
print('  continent 1415 pins:', len(L.eval('PINS')))
L.execute('CUR_MAP = 1414')
prov.RefreshAllData(prov)
print('  continent 1414 pins:', len(L.eval('PINS')))
if len(L.eval('PINS')):
    p = L.eval('PINS')[1]
    p.OnMouseEnter(p)
    gl = L.eval('GameTooltip._lines')
    print('  agg tooltip:', ' / '.join(strip(gl[i]) for i in range(1, len(gl) + 1)))

print('== node tooltips')
# Russian client: Russian names (fishing schools as the ruRU client shows them), plus an English one (always
# matched); other clients: English names. Everything but the chest must get lines.
NODES = (['Магороза', 'Медная жила', 'Мифриловые залежи', 'Косяк масляного черноротика', 'Косяк огнеперого снеппера',
          'Copper Vein', 'Сундук'] if LOCALE == 'ruRU' else
         ['Mageroyal', 'Copper Vein', 'Mithril Deposit', 'Oily Blackmouth School', 'Chest'])
for nm in NODES:
    lines = L.eval('FireObjectTooltip')(nm)
    print('  %s:' % nm, ' / '.join(strip(lines[i]) for i in range(1, len(lines) + 1)) or '(nothing)')
    if not len(lines) and nm not in ('Сундук', 'Chest'):
        sys.exit('FAIL: no tooltip lines for node %s' % nm)
# map pins and the card name a school as the game does
label = strip(ns.SchoolLabel('Oily Blackmouth School'))
print('  school label:', label)
want = {'ruRU': 'Косяк масляного черноротика', 'enUS': 'Oily Blackmouth School'}.get(LOCALE)
if want and label != want:
    sys.exit('FAIL: school label %s, want %s' % (label, want))
print('== money:', strip(ns.Money(1234567)), '|', strip(ns.Money(98)), '|', strip(ns.Money(20598)))
print('== lower:', ns.Lower('ЁЛКА Шерсть ABC'))
flush()
print('output language %s: %d texts checked' % (LOCALE, L.eval('CheckOutputLanguage()')))
print('ALL OK')
