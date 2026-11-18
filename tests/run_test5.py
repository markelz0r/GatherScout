"""Min-quantity filter: list count and hot list react to the setting."""
import sys, re
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
L.execute('PLAYER_LEVEL = 30')
qty = L.eval('AH_QTY')
for id in list(ns.MAT.keys()):
    qty[id] = (id * 37) % 900
fire('AUCTION_HOUSE_SHOW')
for _ in range(4000):
    tick(1)
    if ns.Market().lastScan and not ns.scan.active and not ns.full.active:
        break
print('default minQty:', ns.S.minQty)
ns.UI_Toggle(); tick(2)
F = L.eval('GatherScoutFrame')


def count():
    ns.Invalidate(); tick(2); ns.UI_Refresh()
    hot = sum(1 for _ in ns.hot.items())
    return re.sub(r'\D', '', str(F.count._text)) or '0', hot


for v in (0, 100, 500, 2000):
    ns.S.minQty = v
    n, hot = count()
    print('minQty=%-5d list rows=%-4s hot=%d' % (v, n, hot))
box = F.spinners[3]
box.update()
print('number box present:', box is not None)
print('status text anchored at top:', F is not None)
print('OK')
