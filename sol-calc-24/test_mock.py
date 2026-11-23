import lupa, os

PRELUDE = r'''
ui = { W = 320, H = 218 }
local objs = {}
HINT, TOAST, EXITED = "", "", false
local function newobj(kind)
  local o = { kind = kind, _text = "", _x = 0, _y = 0, _show = true }
  function o:text(t) self._text = tostring(t); return self end
  function o:pos(x,y) self._x, self._y = x, y; return self end
  function o:color(c) self._color = c; return self end
  function o:show(b) self._show = b; return self end
  function o:remove() self._removed = true end
  function o:size(w,h) self._w, self._h = w, h; return self end
  function o:set(v) self._v = v end
  function o:clear(c) self._cleared = c end
  function o:pixel(x,y,c) self._pixels = (self._pixels or 0) + 1 end
  function o:rect(x,y,w,h,c) self._rects = (self._rects or 0) + 1 end
  function o:line(x1,y1,x2,y2,c) self._lines = (self._lines or 0) + 1 end
  function o:get() return nil end
  function o:image() end
  function o:items() end
  function o:select() end
  function o:selected() return 1 end
  function o:stop() end
  function o:play() end
  function o:scale() end
  function o:playing() return false end
  return o
end
local function make(kind)
  local o = newobj(kind)
  objs[#objs + 1] = o
  return o
end
function ui.bg(c) BG = c end
function ui.label(x,y,text,opts)
  local o = make("label"); o._x, o._y, o._text, o._opts = x, y, tostring(text), opts
  return o
end
function ui.canvas(x,y,w,h,opts) return make("canvas") end
function ui.gradient(x,y,w,h) return make("gradient") end
function ui.rect(x,y,w,h,opts) return make("rect") end
function ui.bar(x,y,w,h,v) return make("bar") end
function ui.list(x,y,w,h,items,opts) return make("list") end
function ui.qr(x,y,s,t) return make("qr") end
function ui.image(x,y,src,opts) return make("image") end
function ui.load(src) return newobj("image") end
function ui.anim(x,y,src,opts) return make("anim") end
function ui.clear() for i = #objs, 1, -1 do objs[i] = nil end end
function ui.hint(t) HINT = t end
function ui.toast(t) TOAST = t end
function ui.confirm(t,cb) end
function ui.input(t,n,cb) end
function __objs() return objs end
function __hint() return HINT end
function __toast() return TOAST end

sys = {}
local now = 0
KEYS = {}
function sys.millis() return now end
function sys.keys() return KEYS end
function sys.exit() EXITED = true end
function sys.time() return 0 end
function sys.memory() return { used = 12345, max = 6*1024*1024 } end
function __settime(ms) now = ms end
function __keys(k)
  KEYS = {}
  if k then for key, value in pairs(k) do KEYS[key] = value end end
end
function __exited() return EXITED end

timer = {}
function timer.after() return 1 end
function timer.every() return 2 end
function timer.cancel() end
'''

SRC = open(os.path.join(os.path.dirname(__file__), 'main.lua')).read()
g = None
lua_rt = None

def new_app():
    global g, lua_rt
    lua_rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua_rt.execute(PRELUDE)
    lua_rt.execute('local f = assert(load(%r, "main.lua", "t", _G)); f()' % SRC)
    g = lua_rt.globals()

def keys(d=None):
    g.__keys(lua_rt.table_from(d or {}))

def key(k, rep=False):
    g.on_key(k, rep)

def tick(ms=30):
    g.on_tick(ms)

def labels():
    objs = g.__objs()
    return [objs[i] for i in range(1, len(objs) + 1)
            if objs[i].kind == 'label']

def texts():
    return [l._text for l in labels()]

def back():
    key('back')
    keys({'back': True}); tick()
    keys({}); tick()

def show(title):
    print('\n==', title, '==')
    print('hint:', g.__hint())
    print('labels:', texts()[:9])

def expect(part, title=''):
    assert any(part in t for t in texts()), (title or part, texts())
    print('  ok:', part)

# ------------------------------------------------- page label refresh
new_app()
def keypad_texts():
    return [l._text for l in labels()[8:32]]   # expr, status, result, 5 tabs, then keys

assert keypad_texts()[0] == '7', keypad_texts()[:6]
key('up'); key('right'); key('down')           # tab 1 -> 2, back to keypad
show('page 2 keypad')
assert keypad_texts()[:3] == ['sin(', 'cos(', 'tan('], keypad_texts()[:6]
key('up'); key('right'); key('right'); key('down')  # page 4
assert keypad_texts()[:4] == ['DET(', 'INV(', 'TRANS(', 'RREF('], keypad_texts()[:6]
print('PAGE LABEL REFRESH OK')

# ---------------------------------------------------------------- startup
new_app()
show('startup')
expect('Ready')
expect('PAGE 1/5')
print('STARTUP OK')

# ------------------------------------------------------------------ SOLVE
new_app()
key('up'); key('right'); key('right'); key('down')  # page 3
key('select')                                      # SOLVE template
show('SOLVE template')
expect('SOLVE(x^2-4,x)')
key('down',)*3 if False else None
for _ in range(3): key('down')                     # row 4
for _ in range(5): key('right')                    # col 6 = EXE
key('select')
show('SOLVE executed')
expect('ANS=-2')
expect('-2')
print('SOLVE OK')

# ---------------------------------------------------------------- HISTORY
new_app()
key('up'); key('right'); key('right'); key('down')
key('select')
for _ in range(3): key('down')
for _ in range(5): key('right')
key('select')                                      # run SOLVE
for _ in range(4): key('up')                       # row 4 -> tabs
key('right'); key('right')                         # tab 3 -> 5
key('down')
key('right'); key('right')                         # col 6 -> 1 -> 2 = HIST
key('select')
show('history')
expect('SESSION HISTORY')
expect('SOLVE(x^2-4,x)')
print('HISTORY OK')

# ------------------------------------------------------------ CANCEL back
back()
show('after short CANCEL')
expect('PAGE 5/5')
print('SHORT CANCEL OK')

# ----------------------------------------------------------- long CANCEL
new_app()
key('select')                                      # insert "7"
show('typed 7')
expect('7|')
key('back')
keys({'back': True})
g.__settime(1000); tick()
keys({}); tick()
show('after long CANCEL')
expect('|')
assert g.__toast() == 'Cleared', g.__toast()
print('LONG CANCEL CLEAR OK')

# ------------------------------------------------------------------ GRAPH
new_app()
key('up')
for _ in range(4): key('right')                    # tab 1 -> 5
key('down')
key('select')                                      # GRAPH
show('graph')
expect('f(x)=sin(x)')
expect('features')
key('right'); key('up')                            # pan + zoom
show('graph after pan/zoom')
expect('f(x)=sin(x)')
print('GRAPH OK')

# -------------------------------------------------------------- MATRIX UI
new_app()
key('up')
for _ in range(3): key('right')                    # tab 1 -> 4
key('down')
key('down'); key('down'); key('right')             # row3 col2 = EDIT
key('select')
show('matrix editor')
expect('MatA')
expect('cell(1,1)')
print('MATRIX UI OK')

# ------------------------------------------------------------------ DET(A)
new_app()
key('up')
for _ in range(3): key('right')                    # tab 4
key('down')
key('select')                                      # DET(
for _ in range(4): key('right')                    # A
key('select')
for _ in range(2): key('down')                     # row 3
for _ in range(4): key('left')                     # col 1 = )
key('select')
key('down')                                        # row 4
for _ in range(5): key('right')                    # col 6 = EXE
key('select')
show('DET(A)')
expect('1')
print('DET OK')

# --------------------------------------------------------------- EXIT key
new_app()
key('up')
for _ in range(4): key('right')                    # tab 5
key('down')
for _ in range(3): key('down')                     # row 4
for _ in range(5): key('right')                    # col 6
key('select')
assert g.__exited(), 'sys.exit not called'
print('EXIT OK')

print('\nALL 2.4 MOCK TESTS PASSED')
