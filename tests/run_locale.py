"""Whole-addon smoke test under one client locale (WoW's Lua 5.1 via lupa): loads every file from the .toc,
fires login/AH events, builds the list window, item card, map markers and tooltips, prints what they show.
Fails if a non-Russian locale shows any Cyrillic (chat, window, card, map, tooltips).
Usage: python -I tests/run_locale.py <addon dir> <locale> [harness_locale.lua]
Locales: enUS ruRU deDE esES esMX frFR ptBR koKR zhCN zhTW"""
import os, re, sys
import lupa.lua51 as L
sys.stdout.reconfigure(encoding='utf-8')

ADDON, LOC = sys.argv[1], sys.argv[2]
HARNESS = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'harness_locale.lua')
lua = L.LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
g.ADDON_DIR = os.path.abspath(ADDON).replace(os.sep, '/')
g.TEST_LOCALE = LOC
shown = []


def lua_print(*args):
    line = ' '.join(str(a) for a in args)
    shown.append(line)
    print(line)


g.print = lua_print  # everything the harness and the addon's chat print
lua.execute(open(HARNESS, encoding='utf-8').read())
if LOC != 'ruRU':
    cyr = [l for l in shown if re.search('[\u0400-\u04ff]', l)]
    if cyr:
        sys.exit('FAIL: %d lines with Cyrillic in %s output, e.g.: %s' % (len(cyr), LOC, ' // '.join(cyr[:5])))
    print('no Cyrillic in %s output (%d lines)' % (LOC, len(shown)))
