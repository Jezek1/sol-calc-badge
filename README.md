# SOL CALC — badge calculator

Two builds live in this repo:

| Folder | Target | Entry |
| --- | --- | --- |
| **repo root** | **Solana OS 2.4+** (Lua 5.5 `ui`/`sys`/`on_key`, 320×218) | `main.lua` + `app.json` |
| `sol-calc-24/` | Same 2.4 build, kept as a standalone upload folder | `main.lua` + `app.json` |
| `v1/` | Legacy DEF CON runtime (`badge.gfx`, `on_button`, 320×240) | `main.lua` + `app.ini` |
| `scripts/` | Legacy store entry for the v1 App Store | `sol_calc.lua` |

**If you got `main.lua:33: attempt to index a nil value (local 'g')` in the
2.4 emulator, you loaded the v1 file.** Use the root `main.lua` (or the one in
`sol-calc-24/`), not `v1/main.lua` or `scripts/sol_calc.lua`. The root file is
now the 2.4 build, so uploading/cloning the repo root picks the right one.

## 2.4 build (root / `sol-calc-24/`)

- `main.lua` — complete single-file Lua 5.5 app (~50 KB, under the 64 KB cap)
- `app.json` — store manifest, no permissions
- `sol-calc-24/test_mock.py` — optional off-device test harness (`pip install lupa`)

### Controls

| Input | Action |
| --- | --- |
| D-pad | Move the highlighted keypad key / tab / history row / matrix cell |
| `up` from the top key row | Focus the five page tabs; `left`/`right` changes page |
| SELECT | Insert the focused token or run the focused action |
| CANCEL | Backspace / go back. **Hold > 0.65 s** to clear the current buffer |
| Hold `left`/`right` > 0.45 s | Move the text cursor in the expression line |
| Page 5 `<C` / `C>` | Move the text cursor one character |

Graph view: left/right pan, up/down zoom, SELECT cycles detected features,
CANCEL returns. History: up/down scroll, SELECT recalls, CANCEL returns. Matrix
editor: SELECT types, `CELL` switches pad/cell focus, `EXE` commits a cell,
`DIM` toggles 2×2/3×3, `A/B` switches matrix, `BACK` returns.

### Pages

1. **BASIC** — digits, operators, `x`, `y`, `ANS`, `DEL`, `EXE`
2. **SCI** — trig/inverse trig, `ln`, `log10`, `sqrt`, `abs`, `exp`, `pi`, `e`, `!`, DEG/RAD
3. **CALC** — `SOLVE`, `QUAD`, `DERIV`, `INTEG`, `LIMIT`, comma, variables
4. **MATR** — `DET`, `INV`, `TRANS`, `RREF`, `A`, `B`, matrix arithmetic, editor
5. **TOOLS** — `GRAPH`, `HIST`, `CLRMEM`, angle mode, cursor keys, `EXIT`

### Solving an equation

Reach page 3 (`up`, `right`, `right`, `down`), select `SOLVE`, then `EXE`:

```
SOLVE(x^2-4,x)   -> -2        SOLVE(x^2-4,3) -> 2
3x+5-20          -> 5         QUAD(1,-3,2)   -> x=2 , 1
```

`SOLVE(f(x),guess)` expects `f(x) = 0` rearranged with everything on the left;
the guess `x` means 0. Implicit multiplication works (`2x`, `3sin(x)`,
`(x+1)(x-1)`). Use page 2's `RAD/DEG` for trig equations. The graph engine
samples 161 points, auto-scales, and marks roots, intercepts, extrema,
asymptotes and holes. History is capped at 20 entries; `CLRMEM` resets `ANS`
and both matrices.

### Install / test on Solana OS 2.4

1. Open <https://solana.com/breakpoint/badge> and use **Try in emulator** with
   the root `main.lua` (or upload `sol-calc-24/` as a folder/zip).
2. For the App Store, submit the root folder (`main.lua` + `app.json`) — the
   store compiles it with Lua 5.5 and rejects code that doesn't compile.
3. No permissions are requested: the app only draws, reads buttons, and uses
   `sys.millis()` / `sys.keys()`.

Off-device check:

```sh
pip install lupa
python3 sol-calc-24/test_mock.py
python3 -c "import lupa; lupa.LuaRuntime().execute('assert(load(open(\"main.lua\").read()))')"
```

### 2.4 API notes

The 2.4 build uses one `ui.canvas` plus `ui.label` objects at 320×218,
`ui.hint`/`ui.toast`, top-level UI construction with `on_key(key, rep)` /
`on_tick(ms)` / `on_exit()`, `sys.keys()` for long-press detection, and
`sys.millis()` / `sys.exit()`. `collectgarbage("collect")` is unavailable on
2.4, so `CLRMEM` just drops its tables. Graph recomputation happens only on
entry, pan and zoom, keeping the heaviest callback around 94k of the allowed
200k VM instructions.

## Legacy v1 build (`v1/`, `scripts/`)

For the old DEF CON `badge.gfx` / `on_button` runtime only (Lua 5.4, 320×240).
It will **not** start on 2.4. The old store flow is unchanged: enter
`Jezek1/sol-calc-badge` at <https://solanadefcon.com/store/>, scan, paste the
8-character badge ID, send, and accept on the badge. The v1 emulator is at
<https://solanadefcon.com/badge/>.
