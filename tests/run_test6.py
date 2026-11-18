"""Reproduce the 'pins appear gradually' bug with a Blizzard-like AcquirePin (pool + new-pin mouse setup)."""
import sys
from lupa import LuaRuntime
sys.stdout.reconfigure(encoding='utf-8')
ADDON, HARNESS = sys.argv[1], sys.argv[2]
L = LuaRuntime(unpack_returned_tuples=True)
L.execute(open(HARNESS, encoding='utf-8').read())
L.execute('''
-- Blizzard-like pin pool: reuses released pins; only NEW click-enabled pins get the mouse setup,
-- and SetPassThroughButtons fails like it can on new clients.
local pool, active = {}, {}
local function newPin()
  local pin = CreateFrame("Frame")
  for k, v in pairs(GatherScoutMapPinMixin) do pin[k] = v end
  pin.Texture = pin:CreateTexture(); pin.Border = pin:CreateTexture(); pin.Shadow = pin:CreateTexture()
  pin._click = true                                   -- XML enableMouse="true"
  pin.IsMouseClickEnabled = function(self) return self._click end
  pin.SetMouseClickEnabled = function(self, v) self._click = v end
  pin.SetMouseMotionEnabled = function() end
  if not pin.SetPassThroughButtons or GatherScoutMapPinMixin.SetPassThroughButtons == nil then
    pin.SetPassThroughButtons = function() error("SetPassThroughButtons: action blocked") end
  end
  pin:OnLoad()                                        -- XML OnLoad
  return pin
end
WorldMapFrame.AcquirePin = function(self, template, info)
  local pin = table.remove(pool)
  local isNew = false
  if not pin then pin = newPin(); isNew = true end
  if isNew and pin:IsMouseClickEnabled() then pin:SetPassThroughButtons("LeftButton", "RightButton") end
  pin:OnAcquired(info)
  active[#active + 1] = pin
  return pin
end
WorldMapFrame.RemoveAllPinsByTemplate = function()
  for _, p in ipairs(active) do pool[#pool + 1] = p end
  active = {}
end
function ActivePins() return #active end
''')
ns = L.eval('{}')
files = [l.strip() for l in open(ADDON + '/GatherScout.toc', encoding='utf-8') if l.strip() and not l.startswith('#')]
loader = L.eval('function(src, name, ns) local f = assert(load(src, "@" .. name)); f("GatherScout", ns) end')
for f in files:
    if not f.endswith('.xml'):
        loader(open(ADDON + '/' + f.replace(chr(92), '/'), encoding='utf-8').read(), f, ns)
fire, tick = L.eval('FireEvent'), L.eval('Tick')
fire('ADDON_LOADED', 'GatherScout'); fire('PLAYER_LOGIN'); tick(2)
L.execute('PLAYER_LEVEL = 45')
ns.db.pins[12207] = True
ns.Invalidate(); tick(2)
L.execute('ToggleWorldMap(); CUR_MAP = 1446')
prov = L.eval('WorldMapFrame._provider')
counts = []
for i in range(5):           # open/close the map 5 times
    prov.RefreshAllData(prov)
    counts.append(L.eval('ActivePins()'))
print('pins after each map open:', counts)
