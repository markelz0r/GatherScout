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

TPS = 20  # harness ticks per second
MINE = strip(ns.L["full scan: %s auctions in %d s, tracked items on the auction house: %d."]).split('%')[0]
OTHER = strip(ns.L["full scan (data from another addon): %s auctions in %d s, tracked items on the auction house: %d."]).split('%')[0]


def chat_lines():
    chat = [strip(l) for l in L.eval('LOGS()').values()]
    for l in chat:
        print('  [chat]', l)
    return chat


def wait_scan(before, secs):
    for _ in range(secs * TPS):
        tick(1)
        if ns.Market().lastScan != before and not ns.full.active:
            break


print('== full scan (AH open, auto)')
if 'auctionator' in OPTS:
    # An Auctionator user with its defaults (summary scan mode, its own auto-scan off): on opening the AH
    # GatherScout asks Auctionator for its full scan, so both get the data, and takes the data only when
    # Auctionator has finished with the list.
    atr = L.eval('Auctionator.State.FullScanFrameRef')
    inc = L.eval('Auctionator.State.IncrementalScanFrameRef')
fire('AUCTION_HOUSE_SHOW')
early = False
for _ in range(300):
    tick(1)
    if 'auctionator' in OPTS and atr.inProgress and ns.Market().lastScan:
        early = True
    if not ns.full.active and ns.Market().lastScan:
        break
calls = L.eval('REPL_CALLS')
if 'auctionator' in OPTS:
    chat = chat_lines()
    print("  Auctionator's full scans:", atr.initiated, 'summary scans:', inc.started, 'replicate calls:', calls)
    if atr.initiated != 1 or inc.started != 0 or calls != 1 or not ns.Market().lastScan:
        sys.exit("FAIL: opening the AH did not run Auctionator's full scan, or its data was not taken")
    if early:
        sys.exit('FAIL: GatherScout read the list while Auctionator was still working on it')
    if not any(MINE in l for l in chat):
        sys.exit('FAIL: the full scan we asked Auctionator for is not reported as ours')
    ns.Scan_Full(True)
    tick(5)
    flush()
    if L.eval('REPL_CALLS') != calls or atr.initiated != 1:
        sys.exit('FAIL: GatherScout asked for a full scan while Auctionator waits for its 15 minutes')
    print('  second click within 15 min: no new request')
else:
    flush()
    if calls != 1:
        sys.exit('FAIL: expected one full scan request, got %s' % calls)
# the client repeats the event while item data loads (thousands of times when Auctionator reads a scan):
# the repeats must not read the list again
L.execute('REPL_READS = 0')
for _ in range(300):
    fire('REPLICATE_ITEM_LIST_UPDATE')
    tick(1)
print('  300 repeated list events read the list %d times' % L.eval('REPL_READS'))
if L.eval('REPL_READS') != 0:
    sys.exit('FAIL: repeated REPLICATE_ITEM_LIST_UPDATE events read the list again')
if 'auctionator' in OPTS:
    # a full scan Auctionator starts itself 16 minutes later is picked up
    L.eval('ShiftTime')(16 * 60)
    put(12207, 1, 9500)  # the AH changed meanwhile
    before = ns.Market().lastScan
    atr.InitiateScan(atr)
    wait_scan(before, 10)
    chat = chat_lines()
    if ns.Market().lastScan == before or not any(OTHER in l for l in chat):
        sys.exit("FAIL: Auctionator's own full scan was not picked up")
    print("  Auctionator's own scan picked up: %d items" % ns.Market().scanned)

    # Auctionator's summary scan (its Scan button in its default mode) is not used: lowest prices only
    tick(3 * TPS)
    L.eval('ShiftTime')(60)
    put(12207, 2, 8000)  # a cheaper stack
    before = ns.Market().lastScan
    L.eval('AuctionatorScanButtonMixin.OnClick')(L.eval('AuctionatorScanButtonMixin'))
    tick(6 * TPS)
    flush()
    print('  Auctionator summary scan: summary scans %d, stored %s, button busy %s' % (inc.started, ns.Market().lastScan != before, ns.full.active))
    if inc.started != 1 or ns.Market().lastScan != before or ns.full.active:
        sys.exit("FAIL: Auctionator's summary scan was taken as data, or left the button busy")

    # the AH closes while Auctionator reads a big list: its scan fails, and the remnant it hands out 2 s later
    # ("finished processing N items") is not stored; the button is free
    for _ in range(3000):
        put(99999, 1, 100)  # an untracked item: a big AH that Auctionator reads over several frames
    L.eval('ShiftTime')(16 * 60)
    put(12207, 1, 9700)
    before = ns.Market().lastScan
    ns.Scan_Full(True)
    for _ in range(5 * TPS):
        tick(1)
        if atr.inProgress and not atr.listening:
            break
    busy = ns.full.active
    fire('AUCTION_HOUSE_CLOSED')
    tick(5 * TPS)
    chat = chat_lines()
    remnant = [l for l in chat if 'Finished processing' in l]
    print('  AH closed during the scan: busy before %s, remnant %s, stored %s, busy after %s'
          % (busy, remnant, ns.Market().lastScan != before, ns.full.active))
    if not busy or not remnant or remnant[0].endswith(' 0 items') or ns.Market().lastScan != before or ns.full.active:
        sys.exit("FAIL: closing the AH during Auctionator's scan")

    # the AH closes after Auctionator has read the list, while it merges its data: the data comes after closing
    # and is taken from Auctionator's copy (our auto-scan on opening the AH asked for it)
    L.eval('ShiftTime')(31 * 60)
    put(12207, 1, 9800)
    before, n0 = ns.Market().lastScan, atr.initiated
    fire('AUCTION_HOUSE_SHOW')
    for _ in range(10 * TPS):
        tick(1)
        if atr.initiated > n0 and not atr.inProgress:
            break
    fire('AUCTION_HOUSE_CLOSED')
    tick(3 * TPS)
    chat = chat_lines()
    print('  AH closed while Auctionator merges: stored %s' % (ns.Market().lastScan != before))
    if atr.initiated != n0 + 1 or ns.Market().lastScan == before or not any(MINE in l for l in chat):
        sys.exit("FAIL: Auctionator's data that came after the AH closed was not taken")

    # Auctionator's own auto-scan in its full mode: the scan on opening the AH is Auctionator's, and ours does
    # not ask again
    L.execute('AUCTIONATOR_CFG.autoscan_2 = true; AUCTIONATOR_CFG.replicate_scan_3 = true')
    L.eval('ShiftTime')(31 * 60)
    before, n0, calls = ns.Market().lastScan, atr.initiated, L.eval('REPL_CALLS')
    fire('AUCTION_HOUSE_SHOW')
    wait_scan(before, 15)
    tick(6 * TPS)
    chat = chat_lines()
    print("  Auctionator's own auto-scan: full scans %d, replicate calls %d, stored %s"
          % (atr.initiated - n0, L.eval('REPL_CALLS') - calls, ns.Market().lastScan != before))
    if atr.initiated != n0 + 1 or L.eval('REPL_CALLS') != calls + 1 or ns.Market().lastScan == before \
            or not any(OTHER in l for l in chat):
        sys.exit("FAIL: with Auctionator's own auto-scan on")
    L.execute('AUCTIONATOR_CFG.autoscan_2 = false; AUCTIONATOR_CFG.replicate_scan_3 = false')
    tick(3 * TPS)

# A big AH can take the server a minute or more to send. A late answer is still our scan, with no false
# "no answer" in the chat before it; after 2 minutes the chat says the scan has not come yet, and if it comes
# after that it is still read as ours. Closing the AH drops a request that got no answer. (Without Auctionator:
# with it the scan is Auctionator's.)
NOANSWER = strip(ns.L["the server has not sent the full scan for 2 minutes: a big auction house can take longer, or the server's 15-minute limit is not over yet (another addon may have just done a scan). If it still comes, it is read; until then the data of the last scan stays."])


def slow_scan(delay, secs):
    tick(3 * TPS)  # Auctionator is done with the previous list
    L.eval('ShiftTime')(16 * 60)
    put(12207, 1, 9600 + (delay or 0))  # the AH changed meanwhile
    L.execute('REPL_DELAY = %s' % ('false' if delay is None else delay))
    before = ns.Market().lastScan
    ns.Scan_Full(True)
    for _ in range(secs * TPS):
        tick(1)
        if ns.Market().lastScan != before and not ns.full.active:
            break
    chat = [strip(l) for l in L.eval('LOGS()').values()]
    for l in chat:
        print('  [chat]', l)
    return ns.Market().lastScan != before, any(NOANSWER in l for l in chat), chat


if 'auctionator' not in OPTS:
    for delay in (50, 150):
        got, noanswer, chat = slow_scan(delay, 200)
        ours = any(MINE in l for l in chat) and not any(OTHER in l for l in chat)
        print('  server answers after %d s: read %s, "no answer" note %s, read as our scan %s' % (delay, got, noanswer, ours))
        if not got or not ours or noanswer != (delay > 120):
            sys.exit('FAIL: a full scan the server sends after %d s' % delay)
    got, noanswer, chat = slow_scan(None, 125)
    print('  no answer: note %s, button free %s' % (noanswer, not ns.full.active))
    if got or not noanswer or ns.full.active:
        sys.exit('FAIL: no answer from the server')
    fire('AUCTION_HOUSE_CLOSED')
    if ns.full.requested:
        sys.exit('FAIL: closing the AH did not drop the request')
    L.execute('REPL_DELAY = 0')
    fire('AUCTION_HOUSE_SHOW')
    tick(5 * TPS)
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
print('== market key with regionally unique names (WoW Forever): one AH per ruleset and faction')
# GetRealmName() is a changing server label there ("… Realm 5 PvE", later empty): data kept under such labels
# folds into "<ruleset>-<faction>"; another ruleset, another faction and a plain realm stay apart
L.execute('''
RegionalUniqueNamesEnabled = function() return true end
local M = GatherScoutDB.market
local function rec(day, q, p, t) return { t = t, q = q, p = p, min = p, d = { [day] = { p, p, q, p, 1 } }, h = { { t, p, q, p } } } end
M["CAMWOW EU5 Realm 5 PvE-Alliance"] = { items = { [2447] = rec(2000, 100, 50, 1000), [999001] = rec(2000, 5, 7, 1000) }, lastScan = 1000, scanned = 2 }
M["-Alliance"] = { items = { [2447] = rec(2007, 80, 60, 2000) }, lastScan = 2000, scanned = 1 }
M["Some Realm PvP-Alliance"] = { items = { [2447] = rec(2001, 1, 1, 1500) }, lastScan = 1500, scanned = 1 }
M["-Horde"] = { items = {}, lastScan = 3, scanned = 0 }
''')
ns.MigrateMarkets()
M = L.eval('GatherScoutDB.market')
key = ns.RealmKey()
cur = M[key]
keys_left = sorted(str(k) for k in M.keys())
r = cur['items'][2447] if cur else None
days = sorted(r.d.keys()) if r else []
snaps = [r.h[i][1] for i in range(1, len(r.h) + 1)] if r else []
print('  key %s, keys left %s, Peacebloom days %s, snapshots %s, now q=%s' % (key, keys_left, days, snaps, r.q if r else None))
if key != 'PvE-Alliance' or not cur or days != [2000, 2007] or snaps != [1000, 2000] or r.q != 80 \
        or cur['items'][999001] is None or cur.lastScan != 2000 \
        or 'CAMWOW EU5 Realm 5 PvE-Alliance' in keys_left or '-Alliance' in keys_left \
        or 'Some Realm PvP-Alliance' not in keys_left or '-Horde' not in keys_left:
    sys.exit('FAIL: market data under the old server labels was not folded into the AH key')
L.execute('RegionalUniqueNamesEnabled = nil')
print('== money:', strip(ns.Money(1234567)), '|', strip(ns.Money(98)), '|', strip(ns.Money(20598)))
print('== lower:', ns.Lower('ЁЛКА Шерсть ABC'))
flush()
print('output language %s: %d texts checked' % (LOCALE, L.eval('CheckOutputLanguage()')))
print('ALL OK')
