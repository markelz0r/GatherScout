"""Smoke test GatherScout in an emulated WoW API. Usage: python -I run_test.py <addon dir> <harness.lua> [auctionator] [locale]"""
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
    s = re.sub(r'\|c[0-9a-fA-F]{8}', '', s)
    s = s.replace('|r', '')
    s = re.sub(r'\|T[^|]*\|t', '[i]', s)
    return s

def flush():
    for line in L.eval('LOGS()').values():
        print('  [chat]', strip(line))

ns = L.eval('{}')
files = [l.strip() for l in open(ADDON + '/GatherScout.toc', encoding='utf-8') if l.strip() and not l.startswith('#')]
loader = L.eval('function(src, name, ns) local f = assert(load(src, "@" .. name)); f("GatherScout", ns) end')
for f in files:
    if f.endswith('.xml'): continue
    loader(open(ADDON + '/' + f.replace(chr(92), '/'), encoding='utf-8').read(), f, ns)
print('loaded', len(files), 'files')

fire = L.eval('FireEvent')
tick = L.eval('Tick')
fire('ADDON_LOADED', 'GatherScout')
fire('PLAYER_LOGIN')
tick(2)
flush()

def show_top(n=12):
    res = ns.Compute()
    rows = [res[i] for i in range(1, len(res) + 1)]
    ok = [r for r in rows if r.best is not None]
    print('rows', len(rows), 'obtainable', len(ok))
    ok.sort(key=lambda r: -(r.value or -1))
    for r in ok[:n]:
        print('  %-7s %-6s price=%-8s qty=%-5s F=%.2f %-14s diff=%-8s score=%-4s gain=%-6s where=%s' % (
            r.id, r.m.c, int(r.price) if r.price else '-', r.qty, r.F, strip(r.dem.label),
            strip(ns.DiffLabel(r.best.mult)), r.scout if r.scout is not None else '-',
            '%.1f' % r.best.gain if r.best.gain else '-', strip(ns.WhereText(r.best))))

print('== before any scan')
show_top(6)

print('== scan 1 (auto on AH open)')
qty = L.eval('AH_QTY')
for id in list(ns.MAT.keys()):
    qty[id] = (id * 7) % 400
qty[13464] = 0  # Golden Sansam: none on AH
fire('AUCTION_HOUSE_SHOW')
for _ in range(4000):
    tick(1)
    if ns.scan.active is False and ns.scan.total:
        break
flush()
print('scan done', ns.scan.done, '/', ns.scan.total, 'found', ns.scan.found)

print('== scan 2, 3h later, stock dropped')
L.eval('ShiftTime')(3 * 3600)
for id in list(ns.MAT.keys()):
    qty[id] = max(0, qty[id] - 40)
ns.Scan_Start(True)
for _ in range(4000):
    tick(1)
    if not ns.scan.active:
        break
flush()
ns.Invalidate(); tick(1)
show_top(15)

print('== demand detail for 2447 (Peacebloom) and 13464 (Golden Sansam)')
for iid in (2447, 13464):
    F, d = ns.Demand(iid)
    print('  ', iid, 'F=%.2f' % F, strip(d.label), 'q=', d.q, 'refQ=', d.refQ, 'refP=', d.refP, 'trend=', d.trend,
          'perDay=', d.perDay, 'ownDays=', d.ownDays, 'extDays=', d.extDays)

print('== mob: Devilsaur (npc 6498, lvl 54 beast) as player 35 then 55')
for lvl in (35, 55):
    L.execute('PLAYER_LEVEL = %d' % lvl)
    ns.Invalidate(); tick(1)
    lst, level, *_ = ns.UnitMaterials('target')
    items = [(lst[i].id, lst[i].why, lst[i].hot, lst[i].low, lst[i].req) for i in range(1, len(lst) + 1)] if lst else None
    print('  player', lvl, 'mob level', level, items)
    lines = L.eval('FireUnitTooltip')(L.eval('MOB_GUID'))
    for i in range(1, len(lines) + 1):
        print('    tooltip:', strip(lines[i]))
    print('    nameplate icon shown:', L.eval('TEST_PLATE.GatherScoutIcon and TEST_PLATE.GatherScoutIcon._shown'))

print('== icons: skinning 300, Devilsaur Leather pinned, player 56')
L.execute('SKIN_RANK = 300; PLAYER_LEVEL = 56')
fire('SKILL_LINES_CHANGED'); tick(1)
ns.db.pins[15417] = True
ns.Invalidate(); tick(2)
fire('NAME_PLATE_UNIT_ADDED', 'nameplate1')
fire('PLAYER_TARGET_CHANGED')
print('  hot rank of 15417:', ns.hot[15417])
print('  nameplate icon shown:', L.eval('TEST_PLATE.GatherScoutIcon and TEST_PLATE.GatherScoutIcon._shown'))
print('  target icon shown:', L.eval('GatherScoutTargetIcon and GatherScoutTargetIcon._shown'))
L.execute('GatherScout.S.enabled = false'); ns.Invalidate(); tick(2)
print('  after /gs off -> nameplate:', L.eval('TEST_PLATE.GatherScoutIcon._shown'), 'target:', L.eval('GatherScoutTargetIcon._shown'))
print('  tooltip lines when off:', len(L.eval('FireUnitTooltip')(L.eval('MOB_GUID'))))
L.execute('GatherScout.S.enabled = true'); ns.Invalidate(); tick(2)
F, d = ns.Demand(13464)
print('  Golden Sansam demand with/without Auctionator history: refP=', d.refP, 'refQ=', d.refQ, 'trend=', d.trend, 'extDays=', d.extDays)

print('== humanoid lvl 40 (cloth rule)')
L.execute('MOB_GUID = "Creature-0-1-2-3-999999-1"; MOB_TYPE = CT.humanoid; MOB_LEVEL = 40; PLAYER_LEVEL = 40')
ns.Invalidate(); tick(1)
lst, level, *_ = ns.UnitMaterials('mouseover')
print('  ', [(lst[i].id, lst[i].why, lst[i].hot) for i in range(1, len(lst) + 1)] if lst else lst)

print('== loot learning: herb from a gameobject in zone 1417')
L.execute('LOOT = { { id = 248821, guid = "GameObject-0-1-2-3-566786-1", qty = 2 } }')
fire('LOOT_OPENED'); tick(1)
print('  learned zone 1417:', dict(ns.db.learned.zone[1417].items()) if ns.db.learned.zone[1417] else None)

print('== UI: open list, click first row, chart')
L.execute('PLAYER_LEVEL = 35; MOB_TYPE = nil; MOB_LEVEL = nil')
ns.Invalidate(); tick(1)
ns.UI_Toggle(); tick(2)
gf = L.eval('GatherScoutFrame')
print('  frame shown:', gf._shown)
ns.Chart_Show(13464)
ch = L.eval('GatherScoutCard')
print('  chart shown:', ch._shown)
print('  chart summary:\n    ' + strip(ch.summary._text).replace('\n', '\n    '))
ns.Chart_Show(2447)
print('  chart 2447 summary:\n    ' + strip(ch.summary._text).replace('\n', '\n    '))
L.eval('SlashCmdList.GATHERSCOUT')('help')
L.eval('SlashCmdList.GATHERSCOUT')('off')
L.eval('SlashCmdList.GATHERSCOUT')('on')
tick(2)
flush()
print('output language %s: %d texts checked' % (LOCALE, L.eval('CheckOutputLanguage()')))
print('ALL OK')
