-- Scientific & Graphing Calculator: algebra, calculus, matrices, graphs, history.
--[[
  sol_calc - Scientific & Graphing Calculator for Solana OS (BP26 badge)
  ---------------------------------------------------------------------
  Single-file Lua app for the badge.gfx / on_button SDK (320x240, 6 keys).
  Pure Lua parser, solvers, matrix algebra and graphing engine. No deps.

  Sections:
    1. SDK aliases, colours, helpers
    2. Application state
    3. Keypad page definitions
    4. Tokenizer + recursive-descent parser (AST)
    5. Evaluator, scientific functions, solvers, matrix algebra
    6. Graph engine (auto-scale, sampling, feature detection)
    7. Drawing (calc, graph, history, matrix editor)
    8. Input + lifecycle callbacks
]]

------------------------------------------------------------------------
-- 1. SDK aliases, colours, helpers
------------------------------------------------------------------------

local g  = badge.gfx
local bi = badge.input

local W, H = 320, 240
local floor, abs, sqrt, huge = math.floor, math.abs, math.sqrt, math.huge
local sub, format = string.sub, string.format

local function rgb(r, gg, b) return g.color(r, gg, b) end

local C = {
  BG      = g.BG      or rgb(12, 10, 20),
  PANEL   = g.PANEL   or rgb(28, 25, 42),
  PANEL2  = rgb(42, 38, 60),
  BORDER  = g.BORDER  or rgb(78, 72, 102),
  MUTED   = g.MUTED   or rgb(150, 146, 170),
  WHITE   = g.WHITE   or rgb(255, 255, 255),
  BLACK   = g.BLACK   or rgb(0, 0, 0),
  GREEN   = g.GREEN   or rgb(90, 235, 150),
  RED     = g.RED     or rgb(245, 85, 95),
  CYAN    = g.CYAN    or rgb(95, 225, 245),
  YELLOW  = g.YELLOW  or rgb(250, 220, 90),
  ORANGE  = g.ORANGE  or rgb(250, 155, 75),
  PURPLE  = g.SOLANA_PURPLE  or rgb(150, 85, 245),
  TEAL    = g.SOLANA_TEAL    or rgb(65, 215, 195),
  MAGENTA = g.SOLANA_MAGENTA or rgb(245, 95, 205),
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
  local s = format("%.8g", v)
  return s
end

local function isclose(a, b, rel)
  rel = rel or 1e-6
  return abs(a - b) <= rel * (1 + abs(a) + abs(b))
end

------------------------------------------------------------------------
-- 2. Application state  (all state kept in one small table)
------------------------------------------------------------------------

local HIST_MAX = 20
local EXPR_MAX = 200

local S = {
  view = "calc",                 -- calc | graph | history | matrix
  page = 1, tab = 1,             -- active keypad page (1..5)
  focusArea = 1,                 -- 0 = page tabs, 1 = key grid
  kr = 1, kc = 1,                -- focused key row / column (6 x 4)
  expr = "", cursor = 1,
  result = "", resColor = C.WHITE,
  ans = 0, ansSet = false,
  deg = false,                   -- false = radians
  hist = {}, histSel = 1,
  msg = "", msgUntil = 0,
  bCleared = false, curRepeat = 0,

  -- matrices: {mat=true, rows, cols, [row]={values}}
  matDim = 2,
  matA = nil, matB = nil,
  editWhich = 1,                 -- 1 = MatA, 2 = MatB
  editR = 1, editC = 1, editBuf = "",
  editFocus = 1,                 -- 1 = pad, 2 = cells
  epr = 1, epc = 1,              -- editor pad focus (4 x 5)

  -- graph
  gxmin = -10, gxmax = 10,
  gymin = -1, gymax = 1,
  gexpr = "", gerr = "",
  gsamples = nil, gfeatures = {}, gsel = 0, goverlay = true,
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

local function toast(text)
  S.msg = text
  S.msgUntil = badge.millis() + 1600
end

local function setResult(text, color)
  S.result = text
  S.resColor = color or C.WHITE
end

local function addHistory(expr, result)
  S.hist[#S.hist + 1] = { expr = expr, result = result }
  if #S.hist > HIST_MAX then table.remove(S.hist, 1) end
  S.histSel = #S.hist
end

------------------------------------------------------------------------
-- 3. Keypad pages - 6 columns x 4 rows = 24 keys per page
------------------------------------------------------------------------

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

-- The four special keys insert ready-to-run example calls; edit them with
-- <C / C> (or long-press left/right) and DEL.
local TEMPLATES = {
  SOLVE = "SOLVE(x^2-4,x)",
  QUAD  = "QUAD(1,0,-4)",
  DERIV = "DERIV(sin(x),0)",
  INTEG = "INTEG(x^2,0,1)",
  LIMIT = "LIMIT(sin(x)/x,0)",
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
  for _ = 1, 40 do
    local m = (a + b) / 2
    local fm = gEval(ast, env, m)
    if fm == nil then return m end
    if fa * fm <= 0 then b = m else a, fa = m, fm end
  end
  return (a + b) / 2
end

local function extremumNear(ast, env, a, b, wantMin)
  for _ = 1, 40 do
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
-- 7. Drawing
------------------------------------------------------------------------

local function trunc(s, n)
  if #s <= n then return s end
  return sub(s, 1, n - 1) .. ".."
end

local function gradientRule()
  for x = 0, W - 1, 4 do g.line(x, 0, x + 3, 2, g.gradient(x / W)) end
end

local function keyColor(label)
  if label == "DEL" or label == "CLRMEM" or label == "EXIT" then return C.RED end
  if label == "CLR" then return C.ORANGE end
  if label == "EXE" then return C.GREEN end
  if label == "GRAPH" or label == "HIST" or label == "EDIT" then return C.CYAN end
  if label == "<C" or label == "C>" or label == "MODE" or label == "RAD/DEG" then return C.MUTED end
  if label == "2x2" or label == "3x3" or label == "DIM" then return C.YELLOW end
  if label:match("[A-Z]") and label ~= "ANS" then return C.TEAL end
  if label:match("[%dig%.]") then return C.WHITE end
  return C.CYAN
end

local function visibleExpr()
  local s, c = S.expr, S.cursor
  local maxc = 27
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

local function drawTabs()
  local tw, x0, y0 = 62, 4, 76
  for i = 1, 5 do
    local x = x0 + (i - 1) * tw
    local on = (i == S.tab)
    local focused = (S.focusArea == 0 and i == S.tab)
    g.fill_rect(x, y0, tw - 2, 16, focused and C.PANEL2 or (on and C.PANEL or C.BG))
    g.rect(x, y0, tw - 2, 16, on and C.PURPLE or C.BORDER)
    g.text_center(i .. " " .. TABNAMES[i], x + (tw - 2) / 2, y0 + 3,
                  on and C.WHITE or C.MUTED, 1)
  end
end

local function drawKeypad()
  local cw, ch, x0, y0 = (W - 8) / 6, 32, 4, 96
  for i = 1, 24 do
    local row = floor((i - 1) / 6)
    local col = (i - 1) % 6
    local x = x0 + col * cw
    local y = y0 + row * ch
    local label = PAGES[S.page][i]
    local focused = (S.focusArea == 1 and row + 1 == S.kr and col + 1 == S.kc)
    g.fill_rect(x, y, cw - 2, ch - 2, focused and C.PANEL2 or C.PANEL)
    g.rect(x, y, cw - 2, ch - 2, focused and (C.YELLOW) or C.BORDER)
    g.text_center(label, x + (cw - 2) / 2, y + 9, keyColor(label), 1)
  end
end

local function drawCalc()
  g.clear(C.BG)
  gradientRule()
  g.text(visibleExpr(), 6, 9, C.WHITE, 2)
  g.text((S.deg and "DEG" or "RAD") .. "   [PAGE " .. S.page .. "/5]"
         .. "   ANS=" .. (S.ansSet and fmt(S.ans) or "-"), 6, 28, C.MUTED, 1)
  local rs = S.result
  if #rs > 27 then g.text(trunc(rs, 52), 6, 47, S.resColor, 1)
  else g.text(rs, 6, 45, S.resColor, 2) end
  g.line(0, 72, W, 72, C.BORDER)
  drawTabs()
  drawKeypad()
  g.text(trunc("A=SEL  B=DEL(hold CLR)  hold <L/R>=cursor  " .. S.msg, 52),
         4, 228, S.msg ~= "" and C.YELLOW or C.MUTED, 1)
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

local function drawGraph()
  g.clear(C.BG)
  gradientRule()
  g.text(trunc("f(x)=" .. S.gexpr, 52), 5, 6, C.WHITE, 1)
  g.text(trunc("x[" .. fmt(S.gxmin) .. "," .. fmt(S.gxmax) .. "]  y["
        .. fmt(S.gymin) .. "," .. fmt(S.gymax) .. "]", 52), 5, 19, C.MUTED, 1)

  local px0, py0, px1, py1 = 4, 34, 315, 194
  local pw, ph = px1 - px0, py1 - py0
  local function PX(x) return px0 + (x - S.gxmin) / (S.gxmax - S.gxmin) * pw end
  local function PY(y) return py1 - (y - S.gymin) / (S.gymax - S.gymin) * ph end

  g.fill_rect(px0, py0, pw, ph, C.BG)
  g.rect(px0, py0, pw, ph, C.BORDER)

  if S.gerr ~= "" then
    g.text_center(S.gerr, W / 2, 110, C.RED, 2)
    g.text_center("B = back", W / 2, 140, C.MUTED, 1)
    return
  end

  local sx = niceStep(S.gxmax - S.gxmin)
  local sy = niceStep(S.gymax - S.gymin)
  local v = floor(S.gxmin / sx) * sx
  while v <= S.gxmax do
    local xx = floor(PX(v))
    if xx >= px0 and xx <= px1 then
      g.line(xx, py0, xx, py1, abs(v) < sx / 2 and C.MUTED or g.color(38, 36, 52))
    end
    v = v + sx
  end
  v = floor(S.gymin / sy) * sy
  while v <= S.gymax do
    local yy = floor(PY(v))
    if yy >= py0 and yy <= py1 then
      g.line(px0, yy, px1, yy, abs(v) < sy / 2 and C.MUTED or g.color(38, 36, 52))
    end
    v = v + sy
  end
  if S.gymin < 0 and S.gymax > 0 then g.line(px0, PY(0), px1, PY(0), C.MUTED) end
  if S.gxmin < 0 and S.gxmax > 0 then g.line(PX(0), py0, PX(0), py1, C.MUTED) end

  local sm = S.gsamples
  if sm then
    local ys = sm.ys
    for i = 2, GSAMP do
      local a, b = ys[i - 1], ys[i]
      if a and b and abs(b - a) < 0.9 * (S.gymax - S.gymin) then
        local ay = clamp(PY(a), py0, py1)
        local by = clamp(PY(b), py0, py1)
        g.line(PX(sm.xs[i - 1]), ay, PX(sm.xs[i]), by, C.GREEN)
      end
    end
  end

  if S.goverlay then
    for i = 1, #S.gfeatures do
      local f = S.gfeatures[i]
      local x, y = PX(f.x), f.y and PY(f.y) or py1
      if x >= px0 and x <= px1 then
        if f.kind == "root" then
          g.fill_circle(x, y, 3, C.GREEN)
        elseif f.kind == "yint" then
          g.fill_rect(x - 3, y - 3, 6, 6, C.CYAN)
        elseif f.kind == "min" or f.kind == "max" then
          g.fill_triangle(x, y - 4, x - 4, y + 3, x + 4, y + 3, C.YELLOW)
        elseif f.kind == "asym" then
          local yy = py0
          while yy < py1 do
            g.line(x, yy, x, yy + 5, C.RED)
            yy = yy + 10
          end
        elseif f.kind == "hole" then
          g.circle(x, f.y and y or py0 + 12, 4, C.MAGENTA)
        end
      end
    end
  end

  g.text("o root   [] y-int   /\\ extrem   | asym   O hole", 5, 199, C.MUTED, 1)
  local readout
  if S.gsel > 0 and S.gfeatures[S.gsel] then
    readout = "[" .. S.gsel .. "/" .. #S.gfeatures .. "] " .. S.gfeatures[S.gsel].text
  else
    readout = #S.gfeatures .. " features   A=cycle   B=back"
  end
  g.text(trunc(readout, 52), 5, 213, C.WHITE, 1)
  g.text("L/R pan   U/D zoom   A cycle feature   B back", 5, 227, C.MUTED, 1)
end

local function drawHistory()
  g.clear(C.BG)
  gradientRule()
  g.text_center("SESSION HISTORY  (" .. #S.hist .. "/" .. HIST_MAX .. ")",
                W / 2, 8, C.WHITE, 1)
  g.line(0, 22, W, 22, C.BORDER)
  if #S.hist == 0 then
    g.text_center("No entries yet. Press EXE in the calculator.",
                  W / 2, 110, C.MUTED, 1)
  end
  local top = clamp(S.histSel - 4, 1, math.max(1, #S.hist - 7))
  for row = 0, 7 do
    local idx = top + row
    if idx <= #S.hist then
      local e = S.hist[idx]
      local y = 28 + row * 24
      local on = idx == S.histSel
      g.fill_rect(3, y, W - 6, 22, on and C.PANEL2 or C.PANEL)
      g.rect(3, y, W - 6, 22, on and C.YELLOW or C.BORDER)
      g.text(trunc(idx .. ". " .. e.expr .. "  = " .. e.result, 51),
             8, y + 6, on and C.WHITE or C.MUTED, 1)
    end
  end
  g.text("UP/DN scroll   A recall expression   B back", 5, 228, C.MUTED, 1)
end

local MATRIX_PAD = {
  "7", "8", "9", "CELL",
  "4", "5", "6", "DIM",
  "1", "2", "3", "A/B",
  "0", ".", "-", "CLR",
  "EXE", "BACK", "", "",
}

local function drawMatrixEditor()
  g.clear(C.BG)
  gradientRule()
  local name = S.editWhich == 1 and "MatA" or "MatB"
  g.text(name .. "  " .. S.matDim .. "x" .. S.matDim
         .. (S.editFocus == 2 and "   [CELL]" or "   [PAD]"), 5, 7, C.WHITE, 1)
  g.text(trunc("cell(" .. S.editR .. "," .. S.editC .. ") = " .. S.editBuf, 52),
         5, 20, C.YELLOW, 1)

  local m = S.editWhich == 1 and S.matA or S.matB
  local cw, ch = 88, 36
  local x0 = (W - S.matDim * cw) / 2
  local y0 = 46
  for r = 1, S.matDim do
    for c = 1, S.matDim do
      local x, y = x0 + (c - 1) * cw, y0 + (r - 1) * ch
      local on = S.editFocus == 2 and r == S.editR and c == S.editC
      g.fill_rect(x, y, cw - 3, ch - 3, on and C.PANEL2 or C.PANEL)
      g.rect(x, y, cw - 3, ch - 3, on and C.YELLOW or C.BORDER)
      local txt = (on and S.editBuf ~= "") and S.editBuf or fmt(m[r][c])
      g.text_center(trunc(txt, 10), x + (cw - 3) / 2, y + 11,
                    on and C.WHITE or C.MUTED, 1)
    end
  end

  for i = 1, 20 do
    local row = floor((i - 1) / 4)
    local col = (i - 1) % 4
    local label = MATRIX_PAD[i]
    if label ~= "" then
      local x, y = 10 + col * 76, 158 + row * 13
      local on = S.editFocus == 1 and row + 1 == S.epr and col + 1 == S.epc
      g.fill_rect(x, y, 73, 12, on and C.PANEL2 or C.PANEL)
      g.rect(x, y, 73, 12, on and C.YELLOW or C.BORDER)
      g.text_center(label, x + 36, y + 2, keyColor(label), 1)
    end
  end
  g.text("A=type/select   B=backspace   EXE commit   CELL switch focus",
         5, 228, C.MUTED, 1)
end

function on_draw()
  if S.view == "graph" then drawGraph()
  elseif S.view == "history" then drawHistory()
  elseif S.view == "matrix" then drawMatrixEditor()
  else drawCalc() end
end

------------------------------------------------------------------------
-- 8. Input, actions and lifecycle callbacks
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
  if e:find("Syntax", 1, true) then return "Syntax Error", C.RED end
  if e:find("Singular", 1, true) then return "Singular matrix", C.RED end
  if e:find("No root", 1, true) then return "No root found", C.RED end
  return "Math Error", C.RED
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
    setResult(a, C.WHITE)
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
  setResult("Memory cleared", C.CYAN)
  collectgarbage("collect")
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
    setResult("", C.WHITE)
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
  elseif label == "EXIT" then badge.system.exit()
  elseif TEMPLATES[label] then insertText(TEMPLATES[label])
  else insertText(label) end
end

function on_button(key, pressed)
  if not pressed then
    if key == "b" then S.bCleared = false end
    return
  end
  S.msg = ""

  if key == "b" then
    if S.view == "graph" or S.view == "history" then S.view = "calc"; return end
    if S.view == "matrix" then
      if S.editFocus == 2 then S.editFocus = 1
      elseif S.editBuf ~= "" then S.editBuf = sub(S.editBuf, 1, -2)
      else S.view = "calc" end
      return
    end
    backspace()
    return
  end

  if key == "a" then
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
    return
  end

  if S.view == "graph" then
    if key == "left" then panGraph(-0.1)
    elseif key == "right" then panGraph(0.1)
    elseif key == "up" then zoomGraph(0.8)
    elseif key == "down" then zoomGraph(1.25) end
    return
  end

  if S.view == "history" then
    if key == "up" then S.histSel = clamp(S.histSel - 1, 1, math.max(1, #S.hist))
    elseif key == "down" then S.histSel = clamp(S.histSel + 1, 1, math.max(1, #S.hist)) end
    return
  end

  if S.view == "matrix" then
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
    return
  end

  -- calculator keypad / tab navigation
  if S.focusArea == 0 then
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
end

function on_update(dt)
  local now = badge.millis()
  if S.msg ~= "" and now > S.msgUntil then S.msg = "" end

  -- Long-press CANCEL = clear / long-press L/R = move the text cursor.
  if bi.down("b") and bi.held_ms("b") > 650 and not S.bCleared then
    if S.view == "calc" then
      S.expr, S.cursor = "", 1
      setResult("", C.WHITE)
    elseif S.view == "matrix" then
      S.editBuf = ""
    end
    S.bCleared = true
    toast("Cleared")
  end
  if S.view == "calc" and now - S.curRepeat > 90 then
    if bi.down("left") and bi.held_ms("left") > 450 then
      moveCursor(-1); S.curRepeat = now
    elseif bi.down("right") and bi.held_ms("right") > 450 then
      moveCursor(1); S.curRepeat = now
    end
  end
end

function on_start()
  if badge.led and badge.led.take then badge.led.take() end
  setResult("Ready", C.CYAN)
  toast("D-PAD move   A select   B delete")
  if badge.log then badge.log("sol_calc ready") end
end

function on_stop()
  collectgarbage("collect")
end
