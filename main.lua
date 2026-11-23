-- SOL CALC 2.4 - Scientific & Graphing Calculator for Solana OS 2.4+
--[[
  sol-calc-24 - Lua 5.5 app for the current Solana OS badge API.
  ---------------------------------------------------------------------
  Screen: 320 x 218 app area (ui.W / ui.H), drawn with one ui.canvas plus
  ui.label objects. Input is on_key("up"|"down"|"left"|"right"|"select"|
  "back", rep) and on_tick(ms); held keys are read with sys.keys().
  Pure Lua parser, solvers, matrix algebra and graphing engine. No deps.

  Sections:
    1. State, helpers, keypad pages
    2. Tokenizer + parser, evaluator, solvers, matrices  (ported unchanged)
    3. Graph engine                                       (ported unchanged)
    4. Canvas/label drawing
    5. Input, actions and lifecycle callbacks
]]

------------------------------------------------------------------------
-- 1. State, helpers, keypad pages
------------------------------------------------------------------------

local W, H = ui.W or 320, ui.H or 218
local floor, abs, sqrt, huge = math.floor, math.abs, math.sqrt, math.huge
local sub, format = string.sub, string.format

-- Canvas colours: theme names where possible, fixed RGB where a distinct
-- shade is needed. Label colours are theme names (see COL below).
local C = {
  BG     = "bg",
  PANEL  = "panel",
  PANEL2 = 0x393357,
  BORDER = "border",
  MUTED  = "dim",
  GRID   = 0x2B2840,
  GREEN  = "green",
  RED    = 0xF4555F,
  CYAN   = "aqua",
  YELLOW = "yellow",
  PURPLE = "purple",
  MAGENTA = "pink",
}

local COL = {
  WHITE = "text", MUTED = "dim", GREEN = "green", RED = "orange",
  CYAN = "aqua", YELLOW = "yellow", PURPLE = "purple", TEAL = "lime",
}

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function finite(v)
  return type(v) == "number" and v == v and v ~= huge and v ~= -huge
end

local function fmt(v)
  if v == huge then return "inf" end
  if v == -huge then return "-inf" end
  if v ~= v then return "nan" end
  if v == floor(v) and abs(v) < 1e14 then return format("%.0f", v) end
  return format("%.8g", v)
end

local function isclose(a, b, rel)
  rel = rel or 1e-6
  return abs(a - b) <= rel * (1 + abs(a) + abs(b))
end

local function trunc(s, n)
  if #s <= n then return s end
  return sub(s, 1, n - 1) .. ".."
end

local HIST_MAX = 20
local EXPR_MAX = 200

local S = {
  view = "calc", builtView = "",
  page = 1, tab = 1,           -- active keypad page (1..5)
  focusArea = 1,               -- 0 = page tabs, 1 = key grid
  kr = 1, kc = 1,              -- focused key row / column (6 x 4)
  expr = "", cursor = 1,
  result = "Ready", resColor = COL.CYAN,
  ans = 0, ansSet = false,
  deg = false,                 -- false = radians
  hist = {}, histSel = 1,

  matDim = 2,
  matA = nil, matB = nil,
  editWhich = 1,               -- 1 = MatA, 2 = MatB
  editR = 1, editC = 1, editBuf = "",
  editFocus = 1,               -- 1 = pad, 2 = cells
  epr = 1, epc = 1,            -- editor pad focus (4 x 5)

  gxmin = -10, gxmax = 10,
  gymin = -1, gymax = 1,
  gexpr = "", gerr = "",
  gsamples = nil, gfeatures = {}, gsel = 0, goverlay = true,

  backDown = false, backT0 = 0, backFired = false,
  holdL = 0, holdR = 0, curRepeat = 0,
  hint = "",
}

local function newMatrix(n)
  local m = { mat = true, rows = n, cols = n }
  for i = 1, n do
    local row = {}
    for j = 1, n do row[j] = (i == j) and 1 or 0 end
    m[i] = row
  end
  return m
end

S.matA = newMatrix(2)
S.matB = newMatrix(2)

local function toast(text) ui.toast(text) end

local function setResult(text, color)
  S.result = text
  S.resColor = color or COL.WHITE
end

local function addHistory(expr, result)
  S.hist[#S.hist + 1] = { expr = expr, result = result }
  if #S.hist > HIST_MAX then table.remove(S.hist, 1) end
  S.histSel = #S.hist
end

-- Keypad grids are 6 columns x 4 rows per page.
local PAGES = {
  { -- 1: basic / algebra
    "7", "8", "9", "/", "^", "(",
    "4", "5", "6", "*", ")", "x",
    "1", "2", "3", "-", "y", "ANS",
    "0", ".", "+", "CLR", "DEL", "EXE",
  },
  { -- 2: scientific / trig
    "sin(", "cos(", "tan(", "asin(", "acos(", "atan(",
    "ln(", "log10(", "sqrt(", "abs(", "exp(", "pi",
    "e", "!", "RAD/DEG", "x", "y", ",",
    "ANS", "(", ")", "^", "DEL", "EXE",
  },
  { -- 3: calculus / solvers
    "SOLVE", "QUAD", "DERIV", "INTEG", "LIMIT", ",",
    "x", "y", "0", "1", "2", "3",
    "(", ")", "+", "-", "*", "/",
    "ANS", "^", ".", "CLR", "DEL", "EXE",
  },
  { -- 4: linear algebra
    "DET(", "INV(", "TRANS(", "RREF(", "A", "B",
    "+", "-", "*", "/", "^", "(",
    ")", "EDIT", "2x2", "3x3", "=", "ANS",
    "0", "1", "x", "y", "DEL", "EXE",
  },
  { -- 5: graph / history / memory
    "GRAPH", "HIST", "CLRMEM", "MODE", "<C", "C>",
    "0", "1", "2", "3", "4", "5",
    "6", "7", "8", "9", ".", "EXE",
    "+", "-", "*", "/", "DEL", "EXIT",
  },
}

local TABNAMES = { "BASIC", "SCI", "CALC", "MATR", "TOOLS" }

local TEMPLATES = {
  SOLVE = "SOLVE(x^2-4,x)",
  QUAD  = "QUAD(1,0,-4)",
  DERIV = "DERIV(sin(x),0)",
  INTEG = "INTEG(x^2,0,1)",
  LIMIT = "LIMIT(sin(x)/x,0)",
}

local MATRIX_PAD = {
  "7", "8", "9", "CELL",
  "4", "5", "6", "DIM",
  "1", "2", "3", "A/B",
  "0", ".", "-", "CLR",
  "EXE", "BACK", "", "",
}

------------------------------------------------------------------------
-- 4. Tokenizer + recursive-descent parser
--    Produces a compact AST. No load/loadstring, all errors are caught.
------------------------------------------------------------------------

-- One-argument numeric functions recognised by the parser/evaluator.
local FUNC1 = {
  SIN = true, COS = true, TAN = true,
  ASIN = true, ACOS = true, ATAN = true,
  SINH = true, COSH = true, TANH = true,
  LN = true, LOG10 = true, SQRT = true, ABS = true,
  EXP = true, FLOOR = true, CEIL = true, SIGN = true,
}

local SPECIAL = {
  SOLVE = true, QUAD = true, DERIV = true, INTEG = true, LIMIT = true,
  DET = true, INV = true, TRANS = true, RREF = true,
}

local function tokenize(s)
  local t, i, n = {}, 1, #s
  while i <= n do
    local ch = sub(s, i, i)
    if ch:match("%s") then
      i = i + 1
    elseif ch:match("%d") or (ch == "." and sub(s, i + 1, i + 1):match("%d")) then
      local j = i
      while sub(s, j, j):match("%d") do j = j + 1 end
      if sub(s, j, j) == "." then
        j = j + 1
        while sub(s, j, j):match("%d") do j = j + 1 end
      end
      if sub(s, j, j):match("[eE]") then
        local k = j + 1
        if sub(s, k, k):match("[%+%-]") then k = k + 1 end
        if sub(s, k, k):match("%d") then
          while sub(s, k, k):match("%d") do k = k + 1 end
          j = k
        end
      end
      t[#t + 1] = { t = "num", v = tonumber(sub(s, i, j - 1)) }
      i = j
    elseif ch:match("%a") then
      local j = i + 1
      while sub(s, j, j):match("[%w_]") do j = j + 1 end
      t[#t + 1] = { t = "name", v = sub(s, i, j - 1):upper() }
      i = j
    elseif ch == "(" or ch == ")" or ch == "," or ch == "!" or ch == "=" then
      t[#t + 1] = { t = ch, v = ch }
      i = i + 1
    elseif ch:match("[%+%-*/^]") then
      t[#t + 1] = { t = "op", v = ch }
      i = i + 1
    else
      error("Syntax Error", 0)
    end
  end
  t[#t + 1] = { t = "eof" }
  return t
end

local function parse(src)
  local toks = tokenize(src)
  local p = 1
  local expr, muldiv, unary, power, postfix, primary, callArgs

  local function peek() return toks[p] end
  local function adv()
    local x = toks[p]
    p = p + 1
    return x
  end
  local function expect(tt)
    if peek().t ~= tt then error("Syntax Error", 0) end
    return adv()
  end
  local function bin(op, a, b) return { k = "bin", op = op, a = a, b = b } end

  callArgs = function()
    adv() -- (
    local args = {}
    if peek().t == ")" then error("Syntax Error", 0) end
    while true do
      args[#args + 1] = expr()
      if peek().t ~= "," then break end
      adv()
    end
    expect(")")
    return args
  end

  primary = function()
    local x = peek()
    if x.t == "num" then
      adv()
      return { k = "num", v = x.v }
    end
    if x.t == "(" then
      adv()
      local e = expr()
      expect(")")
      return e
    end
    if x.t == "name" then
      adv()
      local name = x.v
      if peek().t == "(" then
        return { k = "call", name = name, args = callArgs() }
      end
      -- Allow "sin x" as well as "sin(x)".
      if FUNC1[name] then
        local nx = peek()
        if nx.t == "num" or nx.t == "name" or nx.t == "(" then
          return { k = "call", name = name, args = { unary() } }
        end
      end
      return { k = "name", v = name }
    end
    error("Syntax Error", 0)
  end

  postfix = function()
    local n = primary()
    while peek().t == "!" do
      adv()
      n = { k = "un", op = "!", a = n }
    end
    return n
  end

  power = function()
    local n = postfix()
    if peek().t == "op" and peek().v == "^" then
      adv()
      n = bin("^", n, unary()) -- right associative; also handles 2^-3
    end
    return n
  end

  unary = function()
    local x = peek()
    if x.t == "op" and (x.v == "-" or x.v == "+") then
      adv()
      local a = unary()
      if x.v == "-" then return { k = "un", op = "-", a = a } end
      return a
    end
    return power()
  end

  muldiv = function()
    local n = unary()
    while true do
      local x = peek()
      if x.t == "op" and (x.v == "*" or x.v == "/") then
        adv()
        n = bin(x.v, n, unary())
      elseif x.t == "num" or x.t == "name" or x.t == "(" then
        -- implicit multiplication: 2x, 3sin(x), (x+1)(x-1), 2pi
        n = bin("*", n, unary())
      else
        break
      end
    end
    return n
  end

  expr = function()
    local n = muldiv()
    while true do
      local x = peek()
      if x.t == "op" and (x.v == "+" or x.v == "-") then
        adv()
        n = bin(x.v, n, muldiv())
      else
        break
      end
    end
    return n
  end

  -- A trailing "=" (from the page-1 key) is harmless.
  while peek().t == "=" do adv() end
  local root = expr()
  while peek().t == "=" do adv() end
  if peek().t ~= "eof" then error("Syntax Error", 0) end
  return root
end

------------------------------------------------------------------------
-- 5a. Matrix storage helpers (small dense tables, max 3x3 / 3x6)
------------------------------------------------------------------------

local function isMat(v) return type(v) == "table" and v.mat == true end

local function matCheck(v)
  if not isMat(v) then error("Math Error", 0) end
  return v
end

local function matCopy(m, cols)
  cols = cols or m.cols
  local r = { mat = true, rows = m.rows, cols = cols }
  for i = 1, m.rows do
    local row = {}
    for j = 1, cols do row[j] = m[i][j] or 0 end
    r[i] = row
  end
  return r
end

local function matToString(m)
  local rows = {}
  for i = 1, m.rows do
    local cells = {}
    for j = 1, m.cols do cells[j] = fmt(m[i][j]) end
    rows[i] = table.concat(cells, ",")
  end
  return "[" .. table.concat(rows, ";") .. "]"
end

local function matAdd(a, b)
  if a.rows ~= b.rows or a.cols ~= b.cols then error("Math Error", 0) end
  local r = { mat = true, rows = a.rows, cols = a.cols }
  for i = 1, a.rows do
    local row = {}
    for j = 1, a.cols do row[j] = a[i][j] + b[i][j] end
    r[i] = row
  end
  return r
end

local function matScale(a, s)
  local r = { mat = true, rows = a.rows, cols = a.cols }
  for i = 1, a.rows do
    local row = {}
    for j = 1, a.cols do row[j] = a[i][j] * s end
    r[i] = row
  end
  return r
end

local function matMul(a, b)
  if a.cols ~= b.rows then error("Math Error", 0) end
  local r = { mat = true, rows = a.rows, cols = b.cols }
  for i = 1, a.rows do
    local row = {}
    for j = 1, b.cols do
      local sum = 0
      for k = 1, a.cols do sum = sum + a[i][k] * b[k][j] end
      row[j] = sum
    end
    r[i] = row
  end
  return r
end

local function matTranspose(a)
  local r = { mat = true, rows = a.cols, cols = a.rows }
  for i = 1, r.rows do
    local row = {}
    for j = 1, r.cols do row[j] = a[j][i] end
    r[i] = row
  end
  return r
end

local function matDeterminant(a)
  if a.rows ~= a.cols then error("Math Error", 0) end
  local n = a.rows
  if n == 1 then return a[1][1] end
  if n == 2 then return a[1][1] * a[2][2] - a[1][2] * a[2][1] end
  return a[1][1] * (a[2][2] * a[3][3] - a[2][3] * a[3][2])
       - a[1][2] * (a[2][1] * a[3][3] - a[2][3] * a[3][1])
       + a[1][3] * (a[2][1] * a[3][2] - a[2][2] * a[3][1])
end

-- Gauss-Jordan reduction with partial pivoting. Works on rectangular rows.
local function matRREF(a)
  local m = matCopy(a)
  local row = 1
  for col = 1, m.cols do
    if row > m.rows then break end
    local piv, best = row, abs(m[row][col])
    for i = row + 1, m.rows do
      local v = abs(m[i][col])
      if v > best then best, piv = v, i end
    end
    if best < 1e-12 then
      m[row][col] = 0
    else
      if piv ~= row then m[row], m[piv] = m[piv], m[row] end
      local d = m[row][col]
      for j = col, m.cols do m[row][j] = m[row][j] / d end
      for i = 1, m.rows do
        if i ~= row then
          local f = m[i][col]
          if abs(f) > 1e-14 then
            for j = col, m.cols do m[i][j] = m[i][j] - f * m[row][j] end
          end
        end
      end
      row = row + 1
    end
  end
  return m
end

local function matInverse(a)
  if a.rows ~= a.cols or a.rows > 3 then error("Math Error", 0) end
  local n = a.rows
  local aug = matCopy(a, 2 * n)
  for i = 1, n do
    for j = 1, n do aug[i][n + j] = (i == j) and 1 or 0 end
  end
  local r = matRREF(aug)
  for i = 1, n do
    for j = 1, n do
      if abs(r[i][j] - ((i == j) and 1 or 0)) > 1e-7 then
        error("Singular", 0)
      end
    end
  end
  local out = { mat = true, rows = n, cols = n }
  for i = 1, n do
    local row = {}
    for j = 1, n do row[j] = r[i][n + j] end
    out[i] = row
  end
  return out
end

-- 5b. Numeric helpers and solvers. eval/call are declared here so the
--     solvers can evaluate an argument AST without turning it into a number.

local eval, call

local function num(v)
  if not finite(v) then error("Math Error", 0) end
  return v
end

local function toRad(a) if S.deg then return a * (math.pi / 180) end return a end
local function fromRad(a) if S.deg then return a * (180 / math.pi) end return a end

local function factorial(v)
  if v < 0 or v ~= floor(v) or v > 170 then error("Math Error", 0) end
  local r = 1
  for i = 2, v do r = r * i end
  return r
end

-- Make a fresh environment that shares Y but overrides X for each trial.
local function xenv(env)
  return { X = env.X, Y = env.Y }
end

local function fAt(node, e, x)
  e.X = x
  local ok, v = pcall(eval, node, e)
  if not ok or type(v) ~= "number" or v ~= v then return nil end
  return v
end

-- Root finder: bracket scan + bisection, with a Newton-Raphson fallback.
local function solveRoot(node, env, guess)
  local e = xenv(env)
  if not finite(guess) then guess = 0 end
  local lo, hi = guess - 50, guess + 50
  local steps = 200
  local px, py = lo, fAt(node, e, lo)
  local best, bestx = huge, guess

  for i = 1, steps do
    local x = lo + (hi - lo) * i / steps
    local y = fAt(node, e, x)
    if y then
      if abs(y) < best then best, bestx = abs(y), x end
      if py and y * py < 0 then
        local a, b, fa = px, x, py
        for _ = 1, 60 do
          local m = (a + b) * 0.5
          local fm = fAt(node, e, m)
          if fm == nil then break end
          if fa * fm <= 0 then b = m else a, fa = m, fm end
        end
        return (a + b) * 0.5
      end
      px, py = x, y
    end
  end

  -- Wider bracket pass, for roots far away from the initial guess.
  if best >= 1e-8 then
    lo, hi = -10000, 10000
    steps = 400
    px, py = lo, fAt(node, e, lo)
    for i = 1, steps do
      local x = lo + (hi - lo) * i / steps
      local y = fAt(node, e, x)
      if y then
        if abs(y) < best then best, bestx = abs(y), x end
        if py and y * py < 0 then
          local a, b, fa = px, x, py
          for _ = 1, 60 do
            local m = (a + b) * 0.5
            local fm = fAt(node, e, m)
            if fm == nil then break end
            if fa * fm <= 0 then b = m else a, fa = m, fm end
          end
          return (a + b) * 0.5
        end
        px, py = x, y
      end
    end
  end

  local x = guess
  for _ = 1, 60 do
    local y = fAt(node, e, x)
    if y == nil then break end
    local h = 1e-5 * (1 + abs(x))
    local yp, ym = fAt(node, e, x + h), fAt(node, e, x - h)
    if yp == nil or ym == nil then break end
    local d = (yp - ym) / (2 * h)
    if abs(d) < 1e-12 then break end
    local nx = x - y / d
    if not finite(nx) or abs(nx) > 1e12 then break end
    if abs(nx - x) < 1e-11 then return nx end
    x = nx
  end
  if best < 1e-8 then return bestx end
  return nil
end

-- Central difference with Richardson extrapolation.
local function doDeriv(node, env, x0)
  local e = xenv(env)
  local h = 1e-4 * (1 + abs(x0))
  local d1 = (num(fAt(node, e, x0 + h)) - num(fAt(node, e, x0 - h))) / (2 * h)
  local d2 = (num(fAt(node, e, x0 + h / 2)) - num(fAt(node, e, x0 - h / 2))) / h
  return (4 * d2 - d1) / 3
end

-- Adaptive Simpson's rule; evaluation count and depth are capped so a
-- pathological integrand can never blow the 250 ms callback budget.
local function doInteg(node, env, a, b)
  local e = xenv(env)
  local sign = 1
  if b < a then a, b, sign = b, a, -1 end
  local count, MAXEVAL = 0, 1600

  local function f(x)
    count = count + 1
    if count > MAXEVAL then error("Math Error", 0) end
    return num(fAt(node, e, x))
  end

  local fa, fb, fm = f(a), f(b), f((a + b) / 2)
  local whole = (b - a) * (fa + 4 * fm + fb) / 6

  local function refine(x1, x2, f1, f2, fmid, whole_v, tol, depth)
    if depth <= 0 or count > MAXEVAL then return whole_v end
    local m = (x1 + x2) / 2
    local lm, rm = (x1 + m) / 2, (m + x2) / 2
    local fl, fr = f(lm), f(rm)
    local left = (m - x1) * (f1 + 4 * fl + fmid) / 6
    local right = (x2 - m) * (fmid + 4 * fr + f2) / 6
    local delta = left + right - whole_v
    if abs(delta) <= 15 * tol then
      return left + right + delta / 15
    end
    local a1 = refine(x1, m, f1, fmid, fl, left, tol / 2, depth - 1)
    local a2 = refine(m, x2, fmid, f2, fr, right, tol / 2, depth - 1)
    return a1 + a2
  end

  local tol = 1e-8 * (1 + abs(whole))
  return sign * refine(a, b, fa, fb, fm, whole, tol, 14)
end

-- One-sided classification of sampled values approaching x0.
local function limitSide(vals)
  local inf, ninf, f = 0, 0, {}
  for i = 1, #vals do
    local v = vals[i]
    if v == huge then inf = inf + 1
    elseif v == -huge then ninf = ninf + 1
    elseif finite(v) then f[#f + 1] = v end
  end
  if inf == #vals then return huge end
  if ninf == #vals then return -huge end
  if #f == 0 then return nil end
  local last = f[#f]
  if abs(last) > 1e6 and #f >= 2 and abs(last) > 10 * abs(f[1]) then
    return last > 0 and huge or -huge
  end
  for i = 1, #f do
    if not isclose(f[i], last, 1e-3) then return nil end
  end
  return last
end

local function limitStr(v)
  if v == nil then return "DNE" end
  return fmt(v)
end

-- Left, right and two-sided limit, with removable-hole detection.
local function doLimit(node, env, x0)
  local e = xenv(env)
  local hs = { 1e-3, 1e-5, 1e-7 }
  local L, R = {}, {}
  for i = 1, #hs do
    e.X = x0 - hs[i]
    local ok, v = pcall(eval, node, e)
    L[i] = (ok and type(v) == "number") and v or nil
    e.X = x0 + hs[i]
    ok, v = pcall(eval, node, e)
    R[i] = (ok and type(v) == "number") and v or nil
  end
  local lv, rv = limitSide(L), limitSide(R)
  local lim
  if lv and rv and (lv == huge and rv == huge or lv == -huge and rv == -huge
      or finite(lv) and finite(rv) and isclose(lv, rv, 1e-3)) then
    lim = finite(lv) and (lv + rv) / 2 or lv
  end

  e.X = x0
  local ok, at = pcall(eval, node, e)
  local hole = false
  if not ok or not finite(at) then
    hole = lim ~= nil
  elseif lim and finite(lim) and not isclose(at, lim, 1e-4) then
    hole = true
  end

  local s = "lim=" .. limitStr(lim) .. " L=" .. limitStr(lv) .. " R=" .. limitStr(rv)
  if hole then s = s .. " HOLE" end
  return s
end

local function doQuad(a, b, c)
  if abs(a) < 1e-14 then
    if abs(b) < 1e-14 then error("Math Error", 0) end
    return "x=" .. fmt(-c / b)
  end
  local d = b * b - 4 * a * c
  if d >= 0 then
    local s = sqrt(d)
    return "x=" .. fmt((-b + s) / (2 * a)) .. " , " .. fmt((-b - s) / (2 * a))
  end
  local re = -b / (2 * a)
  local im = sqrt(-d) / abs(2 * a)
  return "x=" .. fmt(re) .. " +/- " .. fmt(im) .. "i"
end

-- 5c. Function dispatch and AST evaluator

call = function(name, args, env)
  if FUNC1[name] then
    if #args ~= 1 then error("Syntax Error", 0) end
    local a = num(eval(args[1], env))
    if name == "SIN"  then return math.sin(toRad(a)) end
    if name == "COS"  then return math.cos(toRad(a)) end
    if name == "TAN"  then return math.tan(toRad(a)) end
    if name == "SINH" then return math.sinh(a) end
    if name == "COSH" then return math.cosh(a) end
    if name == "TANH" then return math.tanh(a) end
    if name == "ASIN" then
      if abs(a) > 1 then error("Math Error", 0) end
      return fromRad(math.asin(a))
    end
    if name == "ACOS" then
      if abs(a) > 1 then error("Math Error", 0) end
      return fromRad(math.acos(a))
    end
    if name == "ATAN" then return fromRad(math.atan(a)) end
    if name == "LN"   then
      if a <= 0 then error("Math Error", 0) end
      return math.log(a)
    end
    if name == "LOG10" then
      if a <= 0 then error("Math Error", 0) end
      return math.log(a) / math.log(10)
    end
    if name == "SQRT" then
      if a < 0 then error("Math Error", 0) end
      return sqrt(a)
    end
    if name == "ABS"   then return abs(a) end
    if name == "EXP"   then return math.exp(a) end
    if name == "FLOOR" then return floor(a) end
    if name == "CEIL"  then return math.ceil(a) end
    if name == "SIGN"  then return a > 0 and 1 or (a < 0 and -1 or 0) end
  end

  if name == "SOLVE" then
    if #args < 1 then error("Syntax Error", 0) end
    local guessNode = args[2]
    if guessNode and guessNode.k == "name" then guessNode = args[3] end -- "...,x"
    local guess = guessNode and num(eval(guessNode, env)) or 0
    local r = solveRoot(args[1], env, guess)
    if r == nil then error("No root", 0) end
    return r
  end

  if name == "QUAD" then
    if #args ~= 3 then error("Syntax Error", 0) end
    return doQuad(num(eval(args[1], env)), num(eval(args[2], env)),
                  num(eval(args[3], env)))
  end

  if name == "DERIV" then
    if #args < 2 then error("Syntax Error", 0) end
    return doDeriv(args[1], env, num(eval(args[2], env)))
  end

  if name == "INTEG" then
    if #args < 3 then error("Syntax Error", 0) end
    return doInteg(args[1], env, num(eval(args[2], env)),
                   num(eval(args[3], env)))
  end

  if name == "LIMIT" then
    if #args < 2 then error("Syntax Error", 0) end
    return doLimit(args[1], env, num(eval(args[2], env)))
  end

  if name == "DET"   then return matDeterminant(matCheck(eval(args[1], env))) end
  if name == "INV"   then return matInverse(matCheck(eval(args[1], env))) end
  if name == "TRANS" then return matTranspose(matCheck(eval(args[1], env))) end
  if name == "RREF"  then return matRREF(matCheck(eval(args[1], env))) end

  error("Syntax Error", 0)
end

eval = function(n, env)
  local k = n.k
  if k == "num" then return n.v end

  if k == "name" then
    local v = n.v
    if v == "PI"  then return math.pi end
    if v == "E"   then return math.exp(1) end
    if v == "ANS" then
      if not S.ansSet then error("Math Error", 0) end
      return S.ans
    end
    if v == "X" then
      if env.X == nil then error("Math Error", 0) end
      return env.X
    end
    if v == "Y" then
      if env.Y == nil then error("Math Error", 0) end
      return env.Y
    end
    if v == "A" then return S.matA end
    if v == "B" then return S.matB end
    error("Syntax Error", 0)
  end

  if k == "un" then
    local a = eval(n.a, env)
    if n.op == "-" then return -num(a) end
    if n.op == "!" then return factorial(num(a)) end
  end

  if k == "bin" then
    local a, b = eval(n.a, env), eval(n.b, env)
    local ma, mb = isMat(a), isMat(b)
    if ma or mb then
      if n.op == "+" then return matAdd(matCheck(a), matCheck(b)) end
      if n.op == "-" then return matAdd(matCheck(a), matScale(matCheck(b), -1)) end
      if n.op == "*" then
        if ma and mb then return matMul(a, b) end
        if ma then return matScale(a, num(b)) end
        return matScale(b, num(a))
      end
      error("Math Error", 0)
    end
    a, b = num(a), num(b)
    if n.op == "+" then return a + b end
    if n.op == "-" then return a - b end
    if n.op == "*" then return a * b end
    if n.op == "/" then return a / b end -- inf on /0: LIMIT needs it
    if n.op == "^" then return a ^ b end
  end

  if k == "call" then return call(n.name, n.args, env) end
  error("Syntax Error", 0)
end

-- Compile + run an expression. Returns a display string, or nil + error text.
local function compute(expr, env)
  local ast = parse(expr)
  local v = eval(ast, env or { X = S.ans, Y = S.ans })
  if isMat(v) then return matToString(v), nil, v end
  if type(v) == "string" then return v, nil, nil end
  if not finite(v) then return nil, "Math Error", nil end
  return fmt(v), nil, v
end

------------------------------------------------------------------------
-- 6. Graph engine: sampling, robust auto-scale, key-feature detection
------------------------------------------------------------------------

local GSAMP = 161

local function gEval(ast, env, x)
  env.X = x
  local ok, v = pcall(eval, ast, env)
  if not ok or not finite(v) then return nil end
  return v
end

local function addFeature(list, kind, x, y, text)
  if #list >= 12 then return end
  local dx = (S.gxmax - S.gxmin) / GSAMP
  for i = 1, #list do
    if list[i].kind == kind and abs(list[i].x - x) < 2 * dx then return end
  end
  list[#list + 1] = { kind = kind, x = x, y = y, text = text }
end

local function rootNear(ast, env, a, b, fa)
  for _ = 1, 24 do
    local m = (a + b) / 2
    local fm = gEval(ast, env, m)
    if fm == nil then return m end
    if fa * fm <= 0 then b = m else a, fa = m, fm end
  end
  return (a + b) / 2
end

local function extremumNear(ast, env, a, b, wantMin)
  for _ = 1, 24 do
    local m1 = a + (b - a) / 3
    local m2 = b - (b - a) / 3
    local f1, f2 = gEval(ast, env, m1), gEval(ast, env, m2)
    if f1 == nil or f2 == nil then break end
    if wantMin then
      if f1 < f2 then b = m2 else a = m1 end
    else
      if f1 > f2 then b = m2 else a = m1 end
    end
  end
  local x = (a + b) / 2
  return x, gEval(ast, env, x)
end

local function computeGraph()
  S.gerr = ""
  S.gexpr = S.expr ~= "" and S.expr or "sin(x)"
  local ok, ast = pcall(parse, S.gexpr)
  if not ok then
    S.gerr = "Syntax Error"
    S.gsamples, S.gfeatures = nil, {}
    return
  end

  local env = { X = 0, Y = S.ans }
  local xs, ys = {}, {}
  local vals = {}
  local i
  for i = 0, GSAMP - 1 do
    local x = S.gxmin + (S.gxmax - S.gxmin) * i / (GSAMP - 1)
    local y = gEval(ast, env, x)
    xs[i + 1], ys[i + 1] = x, y
    if y then vals[#vals + 1] = y end
  end

  -- Auto-scale with 5th/95th percentiles so asymptotic spikes do not
  -- flatten the useful part of the curve.
  local ylo, yhi = -1, 1
  if #vals >= 8 then
    table.sort(vals)
    ylo = vals[floor(#vals * 0.05) + 1]
    yhi = vals[floor(#vals * 0.95) + 1]
    if not finite(ylo) or not finite(yhi) or yhi - ylo < 1e-9 then
      ylo, yhi = vals[1], vals[#vals]
    end
    if not finite(ylo) or not finite(yhi) or yhi - ylo < 1e-9 then
      ylo, yhi = -1, 1
    end
    local pad = (yhi - ylo) * 0.12
    ylo, yhi = ylo - pad, yhi + pad
  end
  S.gymin, S.gymax = ylo, yhi

  S.gsamples = { xs = xs, ys = ys }
  local F = {}
  local step = (S.gxmax - S.gxmin) / (GSAMP - 1)

  -- Roots, extrema and discontinuities in one sampling pass.
  for i = 2, GSAMP - 1 do
    local x0, y0 = xs[i - 1], ys[i - 1]
    local x1, y1 = xs[i], ys[i]
    local x2, y2 = xs[i + 1], ys[i + 1]
    if y0 and y1 and y2 then
      if abs(y1) < 1e-12 then
        addFeature(F, "root", x1, 0, "root " .. fmt(x1))
      elseif y0 * y1 < 0 then
        local rx = rootNear(ast, env, x0, x1, y0)
        addFeature(F, "root", rx, 0, "root " .. fmt(rx))
      end
      local d1, d2 = y1 - y0, y2 - y1
      if d1 * d2 < 0 and abs(d1) > 1e-12 and abs(d2) > 1e-12 then
        local isMin = d2 > 0
        local ex, ey = extremumNear(ast, env, x0, x2, isMin)
        if ey then
          addFeature(F, isMin and "min" or "max", ex, ey,
                     (isMin and "min " or "max ") .. fmt(ex) .. "," .. fmt(ey))
        end
      end
      if abs(y1) > 12 * (1 + abs(y0)) and abs(y0) < abs(y1) / 4 then
        addFeature(F, "asym", x1, nil, "asym " .. fmt(x1))
      end
    elseif y0 and y1 == nil then
      local l = gEval(ast, env, x1 - 1e-5)
      local r = gEval(ast, env, x1 + 1e-5)
      if l and r and isclose(l, r, 1e-3) then
        addFeature(F, "hole", x1, l, "hole " .. fmt(x1))
      else
        addFeature(F, "asym", x1, nil, "asym " .. fmt(x1))
      end
    end
  end

  -- Y-intercept.
  if S.gxmin <= 0 and S.gxmax >= 0 then
    local y0 = gEval(ast, env, 0)
    if y0 and finite(y0) then
      addFeature(F, "yint", 0, y0, "y-int " .. fmt(y0))
    end
  end

  S.gfeatures = F
  S.gsel = 0
  S.goverlay = true
end

local function panGraph(dx)
  local w = S.gxmax - S.gxmin
  S.gxmin, S.gxmax = S.gxmin + dx * w, S.gxmax + dx * w
  computeGraph()
end

local function zoomGraph(factor)
  local cx = (S.gxmin + S.gxmax) / 2
  local w = (S.gxmax - S.gxmin) * factor
  if w < 1e-8 or w > 1e8 then return end
  S.gxmin, S.gxmax = cx - w / 2, cx + w / 2
  computeGraph()
end

------------------------------------------------------------------------
-- 4. Canvas + label drawing
------------------------------------------------------------------------

local cv
local L = {}

local function addLabel(name, x, y, text, size, color, w, align)
  local o = { size = size or 12, color = color or "text" }
  if w then o.w = w end
  if align then o.align = align end
  local l = ui.label(x, y, text, o)
  L[name] = l
  return l
end

local function keyColor(label)
  if label == "DEL" or label == "CLRMEM" or label == "EXIT" or label == "BACK" then
    return COL.RED
  end
  if label == "CLR" or label == "2x2" or label == "3x3" or label == "DIM" then
    return COL.YELLOW
  end
  if label == "EXE" then return COL.GREEN end
  if label == "GRAPH" or label == "HIST" or label == "EDIT" then return COL.CYAN end
  if label == "<C" or label == "C>" or label == "MODE" or label == "RAD/DEG" then
    return COL.MUTED
  end
  if label:match("[A-Z]") and label ~= "ANS" then return COL.TEAL end
  if label:match("[%dig%.]") then return COL.WHITE end
  return COL.CYAN
end

local function buildCalc()
  addLabel("expr", 5, 4, "", 20, "text")
  addLabel("status", 5, 30, "", 12, "dim")
  addLabel("result", 5, 46, "", 20, "text")
  for i = 1, 5 do
    local x = 4 + (i - 1) * 62
    addLabel("tab" .. i, x, 74, i .. " " .. TABNAMES[i], 12, "dim", 60, "center")
  end
  local cw, ch, x0, y0 = (W - 8) / 6, 27, 4, 92
  for i = 1, 24 do
    local row, col = floor((i - 1) / 6), (i - 1) % 6
    local lab = PAGES[S.page][i]
    addLabel("key" .. i, x0 + col * cw, y0 + row * ch + 6, lab, 12,
             keyColor(lab), cw - 2, "center")
  end
end

local function buildGraph()
  addLabel("title", 5, 4, "", 12, "text")
  addLabel("bounds", 5, 18, "", 12, "dim")
  addLabel("legend", 5, 168, "", 12, "dim")
  addLabel("readout", 5, 183, "", 12, "text")
end

local function buildHistory()
  addLabel("title", 4, 4, "", 12, "text", W - 8, "center")
  for i = 1, 7 do
    addLabel("row" .. i, 8, 26 + (i - 1) * 25, "", 12, "dim")
  end
end

local function buildMatrix()
  addLabel("title", 5, 4, "", 12, "text")
  addLabel("buf", 5, 18, "", 12, "yellow")
  for i = 1, 9 do
    addLabel("cell" .. i, 0, 0, "", 14, "text", 84, "center")
  end
  for i = 1, 20 do
    local row, col = floor((i - 1) / 4), (i - 1) % 4
    local lab = MATRIX_PAD[i]
    if lab ~= "" then
      addLabel("pad" .. i, 10 + col * 60, 137 + row * 16, lab, 12,
               keyColor(lab), 58, "center")
    end
  end
end

local function buildView()
  ui.clear()
  L = {}
  cv = ui.canvas(0, 0, W, H, { color = "bg" })
  ui.gradient(0, 0, W, 2)
  S.builtView = S.view
  if S.view == "graph" then buildGraph()
  elseif S.view == "history" then buildHistory()
  elseif S.view == "matrix" then buildMatrix()
  else buildCalc() end
end

-- Canvas primitives -----------------------------------------------------

local function fill(x, y, w, h, c)
  if w > 0 and h > 0 then
    cv:rect(floor(x), floor(y), floor(w), floor(h), c)
  end
end

local function outline(x, y, w, h, c)
  fill(x, y, w, 1, c)
  fill(x, y + h - 1, w, 1, c)
  fill(x, y, 1, h, c)
  fill(x + w - 1, y, 1, h, c)
end

local function ln(x1, y1, x2, y2, c)
  cv:line(floor(x1), floor(y1), floor(x2), floor(y2), c)
end

local function disc(cx, cy, r, c)
  cx, cy = floor(cx), floor(cy)
  for y = -r, r do
    for x = -r, r do
      if x * x + y * y <= r * r then cv:pixel(cx + x, cy + y, c) end
    end
  end
end

local function circle(cx, cy, r, c)
  cx, cy = floor(cx), floor(cy)
  for y = -r - 1, r + 1 do
    for x = -r - 1, r + 1 do
      local d = sqrt(x * x + y * y)
      if d >= r - 0.7 and d <= r + 0.7 then cv:pixel(cx + x, cy + y, c) end
    end
  end
end

local function triangle(x1, y1, x2, y2, x3, y3, c)
  ln(x1, y1, x2, y2, c)
  ln(x2, y2, x3, y3, c)
  ln(x3, y3, x1, y1, c)
end

local function visibleExpr()
  local s, c = S.expr, S.cursor
  local maxc = 24
  local start = 1
  if c > maxc - 5 then start = c - (maxc - 5) end
  if #s - start + 1 > maxc then start = #s - maxc + 1 end
  if start < 1 then start = 1 end
  local part = sub(s, start, start + maxc - 1)
  local ci = c - start + 1
  if ci >= 1 and ci <= #part + 1 then
    part = sub(part, 1, ci - 1) .. "|" .. sub(part, ci)
  else
    part = part .. "|"
  end
  return part
end

local keyShown = {}

local function paintCalc()
  cv:clear("bg")
  ln(0, 70, W, 70, C.BORDER)

  -- The labels are created once per view, so refresh their text whenever the
  -- active page changes (the canvas boxes below follow the same page).
  for i = 1, 24 do
    local lab = PAGES[S.page][i]
    if keyShown[i] ~= lab then
      L["key" .. i]:text(lab)
      L["key" .. i]:color(keyColor(lab))
      keyShown[i] = lab
    end
  end

  for i = 1, 5 do
    local x = 4 + (i - 1) * 62
    local on = (i == S.tab)
    local focused = (S.focusArea == 0 and i == S.tab)
    fill(x, 72, 60, 18, focused and C.PANEL2 or (on and C.PANEL or C.BG))
    outline(x, 72, 60, 18, on and C.PURPLE or C.BORDER)
    L["tab" .. i]:color(on and (focused and COL.YELLOW or COL.WHITE) or COL.MUTED)
  end

  local cw, ch, x0, y0 = (W - 8) / 6, 27, 4, 92
  for i = 1, 24 do
    local row, col = floor((i - 1) / 6), (i - 1) % 6
    local x, y = x0 + col * cw, y0 + row * ch
    local focused = (S.focusArea == 1 and row + 1 == S.kr and col + 1 == S.kc)
    fill(x, y, cw - 2, ch - 2, focused and C.PANEL2 or C.PANEL)
    outline(x, y, cw - 2, ch - 2, focused and C.YELLOW or C.BORDER)
  end

  L.expr:text(visibleExpr())
  L.status:text((S.deg and "DEG" or "RAD") .. "   [PAGE " .. S.page .. "/5]"
                .. "   ANS=" .. (S.ansSet and fmt(S.ans) or "-"))
  L.result:text(trunc(S.result, 28))
  L.result:color(S.resColor)
end

local function niceStep(range)
  if range <= 0 then return 1 end
  local raw = range / 5
  local p = 10 ^ floor(math.log(raw) / math.log(10))
  local m = raw / p
  if m < 1.5 then return p end
  if m < 3 then return 2 * p end
  if m < 7 then return 5 * p end
  return 10 * p
end

local function paintGraph()
  cv:clear("bg")
  local px0, py0, px1, py1 = 4, 32, 315, 164
  local pw, ph = px1 - px0, py1 - py0
  local function PX(x) return px0 + (x - S.gxmin) / (S.gxmax - S.gxmin) * pw end
  local function PY(y) return py1 - (y - S.gymin) / (S.gymax - S.gymin) * ph end

  fill(px0, py0, pw + 1, ph + 1, C.BG)
  outline(px0, py0, pw + 1, ph + 1, C.BORDER)
  L.title:text(trunc("f(x)=" .. S.gexpr, 46))
  L.bounds:text(trunc("x[" .. fmt(S.gxmin) .. "," .. fmt(S.gxmax) .. "]  y["
                      .. fmt(S.gymin) .. "," .. fmt(S.gymax) .. "]", 46))
  L.legend:color(COL.MUTED)

  if S.gerr ~= "" then
    L.legend:color(COL.RED)
    L.legend:text(S.gerr)
    L.readout:text("CANCEL = back")
    return
  end

  local sx, sy = niceStep(S.gxmax - S.gxmin), niceStep(S.gymax - S.gymin)
  local v = floor(S.gxmin / sx) * sx
  while v <= S.gxmax do
    local xx = floor(PX(v))
    if xx >= px0 and xx <= px1 then
      ln(xx, py0, xx, py1, abs(v) < sx / 2 and C.MUTED or C.GRID)
    end
    v = v + sx
  end
  v = floor(S.gymin / sy) * sy
  while v <= S.gymax do
    local yy = floor(PY(v))
    if yy >= py0 and yy <= py1 then
      ln(px0, yy, px1, yy, abs(v) < sy / 2 and C.MUTED or C.GRID)
    end
    v = v + sy
  end
  if S.gymin < 0 and S.gymax > 0 then ln(px0, PY(0), px1, PY(0), C.MUTED) end
  if S.gxmin < 0 and S.gxmax > 0 then ln(PX(0), py0, PX(0), py1, C.MUTED) end

  local sm = S.gsamples
  if sm then
    local ys = sm.ys
    for i = 2, GSAMP do
      local a, b = ys[i - 1], ys[i]
      if a and b and abs(b - a) < 0.9 * (S.gymax - S.gymin) then
        ln(PX(sm.xs[i - 1]), clamp(PY(a), py0, py1),
           PX(sm.xs[i]), clamp(PY(b), py0, py1), C.GREEN)
      end
    end
  end

  if S.goverlay then
    for i = 1, #S.gfeatures do
      local f = S.gfeatures[i]
      local x, y = PX(f.x), f.y and PY(f.y) or py1
      if x >= px0 and x <= px1 then
        if f.kind == "root" then
          disc(x, y, 3, C.GREEN)
        elseif f.kind == "yint" then
          fill(x - 3, y - 3, 6, 6, C.CYAN)
        elseif f.kind == "min" or f.kind == "max" then
          triangle(x, y - 4, x - 4, y + 3, x + 4, y + 3, C.YELLOW)
        elseif f.kind == "asym" then
          local yy = py0
          while yy < py1 do
            ln(x, yy, x, yy + 5, C.RED)
            yy = yy + 10
          end
        elseif f.kind == "hole" then
          circle(x, f.y and y or py0 + 12, 4, C.MAGENTA)
        end
      end
    end
  end

  L.legend:text("o root  [] y-int  /\\ extrem  | asym  O hole")
  if S.gsel > 0 and S.gfeatures[S.gsel] then
    L.readout:text("[" .. S.gsel .. "/" .. #S.gfeatures .. "] "
                   .. S.gfeatures[S.gsel].text)
  else
    L.readout:text(#S.gfeatures .. " features   SELECT cycle")
  end
end

local function paintHistory()
  cv:clear("bg")
  ln(0, 22, W, 22, C.BORDER)
  L.title:text("SESSION HISTORY  (" .. #S.hist .. "/" .. HIST_MAX .. ")")
  if #S.hist == 0 then
    L.row4:text("No entries yet. Press EXE in the calculator.")
    L.row4:color(COL.MUTED)
    for i = 1, 7 do if i ~= 4 then L["row" .. i]:text("") end end
    return
  end
  local top = clamp(S.histSel - 4, 1, math.max(1, #S.hist - 6))
  for i = 1, 7 do
    local idx = top + i - 1
    local y = 26 + (i - 1) * 25
    if idx <= #S.hist then
      local e = S.hist[idx]
      local on = idx == S.histSel
      fill(3, y, W - 6, 23, on and C.PANEL2 or C.PANEL)
      outline(3, y, W - 6, 23, on and C.YELLOW or C.BORDER)
      L["row" .. i]:text(trunc(idx .. ". " .. e.expr .. " = " .. e.result, 44))
      L["row" .. i]:color(on and COL.WHITE or COL.MUTED)
    else
      L["row" .. i]:text("")
    end
  end
end

local function paintMatrix()
  cv:clear("bg")
  local name = S.editWhich == 1 and "MatA" or "MatB"
  L.title:text(name .. "  " .. S.matDim .. "x" .. S.matDim
               .. (S.editFocus == 2 and "   [CELL]" or "   [PAD]"))
  L.buf:text(trunc("cell(" .. S.editR .. "," .. S.editC .. ") = " .. S.editBuf, 44))

  local m = S.editWhich == 1 and S.matA or S.matB
  local cw, ch = 88, 32
  local x0 = (W - S.matDim * cw) / 2
  local y0 = 34
  for r = 1, S.matDim do
    for c = 1, S.matDim do
      local i = (r - 1) * S.matDim + c
      local x, y = x0 + (c - 1) * cw, y0 + (r - 1) * ch
      local on = (S.editFocus == 2 and r == S.editR and c == S.editC)
      fill(x, y, cw - 3, ch - 3, on and C.PANEL2 or C.PANEL)
      outline(x, y, cw - 3, ch - 3, on and C.YELLOW or C.BORDER)
      local l = L["cell" .. i]
      l:pos(x + 2, y + 9)
      local txt = (on and S.editBuf ~= "") and S.editBuf or fmt(m[r][c])
      l:text(trunc(txt, 10))
      l:color(on and COL.WHITE or COL.MUTED)
    end
  end
  for i = S.matDim * S.matDim + 1, 9 do L["cell" .. i]:text("") end

  for i = 1, 20 do
    local row, col = floor((i - 1) / 4), (i - 1) % 4
    local lab = MATRIX_PAD[i]
    if lab ~= "" then
      local x, y = 10 + col * 60, 136 + row * 16
      local on = (S.editFocus == 1 and row + 1 == S.epr and col + 1 == S.epc)
      fill(x, y, 58, 15, on and C.PANEL2 or C.PANEL)
      outline(x, y, 58, 15, on and C.YELLOW or C.BORDER)
    end
  end
end

local HINTS = {
  calc = "SEL type  CANCEL del/hold clear  hold LR cursor",
  graph = "SEL cycle  CANCEL back  LR pan  UD zoom",
  history = "UD scroll  SEL recall  CANCEL back",
  matrix = "SEL select  CANCEL del  EXE commit  CELL focus",
}

local function refresh()
  if S.builtView ~= S.view then buildView() end
  if S.view == "graph" then paintGraph()
  elseif S.view == "history" then paintHistory()
  elseif S.view == "matrix" then paintMatrix()
  else paintCalc() end
  local h = HINTS[S.view] or ""
  if h ~= S.hint then S.hint = h; ui.hint(h) end
end

------------------------------------------------------------------------
-- 5. Input, actions and lifecycle callbacks
------------------------------------------------------------------------

local function insertText(t)
  if #S.expr + #t > EXPR_MAX then toast("Expression full") return end
  S.expr = sub(S.expr, 1, S.cursor - 1) .. t .. sub(S.expr, S.cursor)
  S.cursor = S.cursor + #t
end

local function backspace()
  if S.cursor > 1 then
    S.expr = sub(S.expr, 1, S.cursor - 2) .. sub(S.expr, S.cursor)
    S.cursor = S.cursor - 1
  end
end

local function moveCursor(d)
  S.cursor = clamp(S.cursor + d, 1, #S.expr + 1)
end

local function mapError(e)
  if e:find("Syntax", 1, true) then return "Syntax Error", COL.RED end
  if e:find("Singular", 1, true) then return "Singular matrix", COL.RED end
  if e:find("No root", 1, true) then return "No root found", COL.RED end
  return "Math Error", COL.RED
end

local function execute()
  local expr = S.expr:gsub("%s+$", ""):gsub("=+$", "")
  if expr == "" then return end
  local ok, a, b, val = pcall(compute, expr, { X = S.ans, Y = S.ans })
  if not ok then
    local msg, col = mapError(tostring(a))
    setResult(msg, col)
  elseif a == nil then
    local msg, col = mapError(tostring(b or "Math Error"))
    setResult(msg, col)
  else
    setResult(a, COL.WHITE)
    if finite(val) then S.ans, S.ansSet = val, true end
    addHistory(expr, a)
  end
end

local function clearMemory()
  S.hist = {}
  S.histSel = 1
  S.ans, S.ansSet = 0, false
  S.matA, S.matB = newMatrix(S.matDim), newMatrix(S.matDim)
  S.expr, S.cursor = "", 1
  setResult("Memory cleared", COL.CYAN)
  toast("CLEAR MEM")
end

local function resizeMatrix(m, n)
  local out = newMatrix(n)
  for i = 1, math.min(n, m.rows) do
    for j = 1, math.min(n, m.cols) do out[i][j] = m[i][j] end
  end
  return out
end

local function setDim(n)
  S.matDim = n
  S.matA, S.matB = resizeMatrix(S.matA, n), resizeMatrix(S.matB, n)
  S.editR, S.editC = math.min(S.editR, n), math.min(S.editC, n)
  toast(n .. "x" .. n .. " matrices")
end

local function enterGraph()
  S.view = "graph"
  computeGraph()
end

local function enterMatrix()
  S.view = "matrix"
  S.editWhich, S.editR, S.editC = 1, 1, 1
  S.editBuf, S.editFocus = "", 1
  S.epr, S.epc = 1, 1
end

local function commitCell()
  local m = S.editWhich == 1 and S.matA or S.matB
  local expr = S.editBuf
  if expr == "" then return end
  local ok, a, b, v = pcall(compute, expr, { X = S.ans, Y = S.ans })
  if not ok or a == nil or not finite(v) then
    toast("Bad cell value")
    return
  end
  m[S.editR][S.editC] = v
  S.editBuf = ""
  S.editC = S.editC + 1
  if S.editC > S.matDim then S.editC, S.editR = 1, S.editR + 1 end
  if S.editR > S.matDim then S.editR = 1 end
end

local function selectPad(key)
  if key == "" then return end
  if S.editFocus == 2 then
    if key == "CELL" then S.editFocus = 1 end
    return
  end
  if key == "CELL" then S.editFocus = 2
  elseif key == "DIM" then setDim(S.matDim == 2 and 3 or 2)
  elseif key == "A/B" then S.editWhich = S.editWhich == 1 and 2 or 1
  elseif key == "CLR" then S.editBuf = ""
  elseif key == "BACK" then S.view = "calc"
  elseif key == "EXE" then commitCell()
  elseif #S.editBuf < 20 then S.editBuf = S.editBuf .. key end
end

local function selectKey(label)
  if label == "EXE" then execute()
  elseif label == "DEL" then backspace()
  elseif label == "CLR" then
    S.expr, S.cursor = "", 1
    setResult("", COL.WHITE)
  elseif label == "<C" then moveCursor(-1)
  elseif label == "C>" then moveCursor(1)
  elseif label == "MODE" or label == "RAD/DEG" then
    S.deg = not S.deg
    toast(S.deg and "DEGREES" or "RADIANS")
  elseif label == "GRAPH" then enterGraph()
  elseif label == "HIST" then S.view = "history"
  elseif label == "CLRMEM" then clearMemory()
  elseif label == "EDIT" then enterMatrix()
  elseif label == "2x2" then setDim(2)
  elseif label == "3x3" then setDim(3)
  elseif label == "EXIT" then sys.exit()
  elseif TEMPLATES[label] then insertText(TEMPLATES[label])
  else insertText(label) end
end

local function doBack()
  if S.view == "graph" or S.view == "history" then
    S.view = "calc"
    refresh()
    return
  end
  if S.view == "matrix" then
    if S.editFocus == 2 then S.editFocus = 1
    elseif S.editBuf ~= "" then S.editBuf = sub(S.editBuf, 1, -2)
    else S.view = "calc" end
    refresh()
    return
  end
  backspace()
  refresh()
end

local function doClear()
  if S.view == "calc" then
    S.expr, S.cursor = "", 1
    setResult("", COL.WHITE)
  elseif S.view == "matrix" then
    S.editBuf = ""
  else
    return
  end
  refresh()
  toast("Cleared")
end

local function dispatchKey(key)
  if key == "select" then
    if S.view == "graph" then
      if #S.gfeatures > 0 then
        S.gsel = S.gsel + 1
        if S.gsel > #S.gfeatures then S.gsel = 0 end
      else
        S.goverlay = not S.goverlay
      end
    elseif S.view == "history" then
      local e = S.hist[S.histSel]
      if e then
        S.expr, S.cursor = e.expr, #e.expr + 1
        S.view = "calc"
      end
    elseif S.view == "matrix" then
      selectPad(MATRIX_PAD[(S.epr - 1) * 4 + S.epc])
    elseif S.focusArea == 0 then
      S.page = S.tab
      S.focusArea = 1
    else
      selectKey(PAGES[S.page][(S.kr - 1) * 6 + S.kc])
    end
  elseif S.view == "graph" then
    if key == "left" then panGraph(-0.1)
    elseif key == "right" then panGraph(0.1)
    elseif key == "up" then zoomGraph(0.8)
    elseif key == "down" then zoomGraph(1.25) end
  elseif S.view == "history" then
    if key == "up" then S.histSel = clamp(S.histSel - 1, 1, math.max(1, #S.hist))
    elseif key == "down" then S.histSel = clamp(S.histSel + 1, 1, math.max(1, #S.hist)) end
  elseif S.view == "matrix" then
    if S.editFocus == 2 then
      if key == "up" then S.editR = S.editR - 1
      elseif key == "down" then S.editR = S.editR + 1
      elseif key == "left" then S.editC = S.editC - 1
      elseif key == "right" then S.editC = S.editC + 1 end
      S.editR = clamp(S.editR, 1, S.matDim)
      S.editC = clamp(S.editC, 1, S.matDim)
    else
      if key == "up" then S.epr = S.epr - 1
      elseif key == "down" then S.epr = S.epr + 1
      elseif key == "left" then S.epc = S.epc - 1
      elseif key == "right" then S.epc = S.epc + 1 end
      if S.epr < 1 then S.epr = 5 elseif S.epr > 5 then S.epr = 1 end
      if S.epc < 1 then S.epc = 4 elseif S.epc > 4 then S.epc = 1 end
    end
  elseif S.focusArea == 0 then
    if key == "left" then S.tab = S.tab - 1
    elseif key == "right" then S.tab = S.tab + 1
    elseif key == "down" or key == "up" then S.focusArea = 1 end
    if S.tab < 1 then S.tab = 5 elseif S.tab > 5 then S.tab = 1 end
    S.page = S.tab
  else
    if key == "left" then S.kc = S.kc - 1
    elseif key == "right" then S.kc = S.kc + 1
    elseif key == "up" then
      if S.kr == 1 then S.focusArea = 0 else S.kr = S.kr - 1 end
    elseif key == "down" then S.kr = S.kr + 1 end
    if S.kc < 1 then S.kc = 6 elseif S.kc > 6 then S.kc = 1 end
    if S.kr > 4 then S.kr = 1 end
  end
  refresh()
end

function on_key(key, rep)
  if key == "back" then
    if not rep and not S.backDown then
      S.backDown = true
      S.backT0 = sys.millis()
      S.backFired = false
    end
    return true
  end
  -- In the calculator, left/right auto-repeat is used for the text cursor
  -- by on_tick, so don't also scroll the keypad focus on repeats.
  if rep and S.view == "calc" and (key == "left" or key == "right") then
    return true
  end
  dispatchKey(key)
  return true
end

function on_tick(ms)
  local now = sys.millis()
  local k = sys.keys and sys.keys() or {}

  -- CANCEL: short press = delete/back, hold = clear the current buffer.
  if S.backDown then
    if not k.back then
      S.backDown = false
      if not S.backFired then doBack() end
    elseif not S.backFired and now - S.backT0 > 650 then
      S.backFired = true
      doClear()
    end
  end

  -- Hold left/right to move the expression cursor (90 ms repeat).
  if S.view == "calc" then
    if k.left then
      if S.holdL == 0 then S.holdL = now end
      if now - S.holdL > 450 and now - S.curRepeat > 90 then
        moveCursor(-1)
        S.curRepeat = now
      end
    else
      S.holdL = 0
    end
    if k.right then
      if S.holdR == 0 then S.holdR = now end
      if now - S.holdR > 450 and now - S.curRepeat > 90 then
        moveCursor(1)
        S.curRepeat = now
      end
    else
      S.holdR = 0
    end
  else
    S.holdL, S.holdR = 0, 0
  end
end

function on_exit()
  -- Nothing to free explicitly; collectgarbage("collect") is unavailable.
end

------------------------------------------------------------------------
-- Start
------------------------------------------------------------------------

ui.bg("bg")
setResult("Ready", COL.CYAN)
refresh()
toast("D-PAD move   SELECT type   CANCEL delete")
