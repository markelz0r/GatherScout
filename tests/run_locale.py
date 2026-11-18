"""Whole-addon smoke test under one client locale (WoW's Lua 5.1 via lupa): loads every file from the .toc,
fires login/AH events, builds the list window, item card, map markers and tooltips, prints what they show.
Usage: python -I tests/run_locale.py <addon dir> <locale> [harness_locale.lua]
Locales: enUS ruRU deDE esES esMX frFR ptBR koKR zhCN zhTW"""
import os, sys
import lupa.lua51 as L
sys.stdout.reconfigure(encoding='utf-8')

ADDON, LOC = sys.argv[1], sys.argv[2]
HARNESS = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'harness_locale.lua')
lua = L.LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
g.ADDON_DIR = os.path.abspath(ADDON).replace(os.sep, '/')
g.TEST_LOCALE = LOC
lua.execute(open(HARNESS, encoding='utf-8').read())
