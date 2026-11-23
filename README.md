# SOL CALC — Solana OS badge calculator

> **Solana OS 2.4 / current App Store?** Use [`sol-calc-24/`](sol-calc-24/) —
> it is a full rebuild for the Lua 5.5 `ui` / `sys` / `on_key` API (320×218).
> The root `main.lua` below targets the older DEF CON `badge.gfx` / `on_button`
> runtime and will not start on 2.4. See [sol-calc-24/README.md](sol-calc-24/README.md)
> for install and submission steps.

Single-file Lua app for the Solana OS SDK that exposes `badge.gfx`, `badge.input`
and the `on_start` / `on_update` / `on_draw` / `on_button` callbacks
(320×240, six buttons). No external modules, no `loadstring`, no blocking loop.

- `main.lua` — the complete app (~47 KB, within the store's 96 KB per-script cap)
- `app.ini` — optional launcher metadata

## Controls

| Input | Action |
| --- | --- |
| D-pad | Move the yellow keypad focus (6×4 grid) |
| `up` from top row | Focus the five page tabs; `left`/`right` switch page |
| `a` (SELECT) | Insert the focused token / run the focused action |
| `b` (CANCEL) | Backspace. **Hold > 0.65 s** to clear the expression |
| Hold `left`/`right` > 0.45 s | Move the text cursor in the input line |
| Page 5 `◀C` / `C>` | Move the text cursor one character |
| BOOT | Reserved by the OS — not used by this app |

Graph view: `left`/`right` pan, `up`/`down` zoom, `a` cycles detected features,
`b` returns. History view: `up`/`down` scroll, `a` recalls, `b` returns.
Matrix editor: `a` types the selected pad key, `CELL` switches between pad and
cell focus, `EXE` commits a cell, `DIM` toggles 2×2/3×3, `A/B` switches matrix,
`b` backspaces (hold to clear), `BACK` returns.

## Pages

1. **BASIC** — digits, operators, `x`, `y`, `ANS`, `DEL`, `EXE`
2. **SCI** — trig/inverse trig, `ln`, `log10`, `sqrt`, `abs`, `exp`, `pi`, `e`, `!`, DEG/RAD
3. **CALC** — `SOLVE`, `QUAD`, `DERIV`, `INTEG`, `LIMIT`, comma, variables
4. **MATR** — `DET`, `INV`, `TRANS`, `RREF`, `A`, `B`, matrix arithmetic, editor
5. **TOOLS** — `GRAPH`, `HIST`, `CLRMEM`, angle mode, cursor keys, `EXIT`

The solver keys insert ready-to-run examples (`SOLVE(x^2-4,x)`, etc.). Edit them
with backspace / the cursor keys, or clear and type your own using the comma key
on page 3. Implicit multiplication works: `2x`, `3sin(x)`, `(x+1)(x-1)`.
Free `x`/`y` evaluate against `ANS` when you press `EXE`; inside solvers they are
the independent variable. QUAD prints complex roots as `re +/- imi`.

The graph engine samples 161 points, auto-scales from 5th/95th percentiles (so
asymptotic spikes do not flatten the curve), and marks roots, the y-intercept,
local minima/maxima, vertical asymptotes and removable holes. History is capped
at 20 entries; `CLRMEM` also resets `ANS`, both matrices and garbage-collects.

## Test in the Solana OS web emulator

1. Open <https://solanadefcon.com/badge/> (virtual badge) and note the 8-character
   badge ID shown beside the screen.
2. Put this file in a **public GitHub repo** as `scripts/sol_calc.lua` (the store
   uses the filename as the app id and the first `--` comment as the description).
3. Open <https://solanadefcon.com/store/>, enter `owner/repo`, scan, paste the
   badge ID and send. Accept the offer on the virtual badge (or on hardware under
   Settings → Identity for the ID).
4. Launch **sol_calc** from the launcher. Arrow keys move, `Z`/Enter is SELECT,
   `Esc`/`X` is CANCEL. `print`/`badge.log` output appears in the console pane.

## Put it on hardware

- Same store flow, using the badge's 8-character ID from **Settings → Identity**.
- Or copy the folder to the badge filesystem as `/apps/sol_calc/` containing
  `main.lua` and `app.ini` (over USB/serial or by pushing the files), then launch
  it from the app launcher. Firmware flashing itself is documented at
  <https://solanadefcon.com/flash/> — set the USB switch to **UART** first.

## Sanity-check off-device

Any Lua 5.4/5.5 interpreter can load the file if a minimal `badge` stub exists:

```lua
badge = {
  millis = function() return 0 end,
  log = function() end,
  system = { exit = function() end },
  led = { take = function() end },
  input = { down = function() return false end, held_ms = function() return 0 end },
  gfx = setmetatable({
    color = function() return 0 end, gradient = function() return 0 end,
    text = function() end, text_center = function() end, line = function() end,
    clear = function() end, rect = function() end, fill_rect = function() end,
    circle = function() end, fill_circle = function() end,
    triangle = function() end, fill_triangle = function() end,
  }, { __index = function() return 0 end }),
}
assert(loadfile("main.lua"))
```

The parser and math engines were also exercised with `SOLVE`, `QUAD`, `DERIV`,
`INTEG`, `LIMIT`, 2×2/3×3 matrices and graph feature detection in a mocked
runtime; all four views were drawn without errors.
