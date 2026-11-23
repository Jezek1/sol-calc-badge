# SOL CALC 2.4 — Solana OS 2.4+ build

This is the rebuild for the **current** Solana OS App Store API (Lua 5.5,
`ui` / `sys`, 320×218 screen). The original `main.lua` in the repo root targets
the older DEF CON `badge.gfx` / `on_button` runtime and will **not** run on 2.4;
this folder is the drop-in replacement.

- `main.lua` — the complete single-file app (~50 KB, under the store's 64 KB cap)
- `app.json` — store manifest (no permissions required)
- `test_mock.py` — optional off-device test harness (needs `pip install lupa`)

## What changed from the v1 build

| v1 (`../main.lua`) | 2.4 (`main.lua`) |
| --- | --- |
| `badge.gfx` drawing calls | one `ui.canvas` + `ui.label` objects |
| 320×240 | 320×218 (`ui.W` / `ui.H`) |
| `on_start` / `on_update` / `on_draw` / `on_button` | top-level build, `on_key(key, rep)` / `on_tick(ms)` / `on_exit()` |
| `badge.input.down` / `held_ms` | `sys.keys()` polled in `on_tick` |
| `badge.millis()` / `badge.system.exit()` | `sys.millis()` / `sys.exit()` |
| own toast + message timer | `ui.toast()` / `ui.hint()` |
| `app.ini`, `scripts/*.lua` store scan | `app.json`, web submission |
| `collectgarbage("collect")` | removed (2.4 only allows `collectgarbage("count")`) |

The parser, solvers, matrix algebra and graph engine are the same math core as
the v1 app (with shorter graph bisection loops to stay well inside the
200,000-instruction-per-callback budget). Graphs are recomputed only on view
entry, pan and zoom — never every tick.

## Controls

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

## Solving an equation

Press **up** → **right ×2** → **down** to reach page 3 (CALC), select `SOLVE`,
then select `EXE`:

```
SOLVE(x^2-4,x)     -> -2
SOLVE(x^2-4,3)     ->  2
3x+5-20            ->  5   (type with EXE on page 1/5)
QUAD(1,-3,2)       -> x=2 , 1
```

`SOLVE(f(x),guess)` rearranges nothing for you: enter `f(x) = 0` with everything
on the left. The second argument is the starting guess (`x` means 0). Implicit
multiplication works (`2x`, `3sin(x)`, `(x+1)(x-1)`). Use page 2's `RAD/DEG` key
for trigonometric equations.

## Install on Solana OS 2.4

1. Open the badge site at <https://solana.com/breakpoint/badge> and follow the
   App Store → submit/publish link (the store also links the API reference at
   `/apps/docs`).
2. Upload this folder (or a zip of it). `main.lua` is the entry point; the form
   reads `app.json`, and the store compiles both with Lua 5.5 before accepting.
3. Publish, then install from the badge's App Store (or scan the store listing
   with the emulator at <https://solana.com/breakpoint/badge/emulator>).
4. There are **no permissions**: the app only draws, reads buttons and uses
   `sys.millis()` / `sys.keys()`.

## Off-device test

```sh
pip install lupa
python3 sol-calc-24/test_mock.py
```

The harness stubs `ui`, `sys` and `timer` and drives `on_key` / `on_tick` through
startup, SOLVE, history, back/clear, graph pan/zoom, the matrix editor, `DET(A)`
and `EXIT`. It also compiles `main.lua` with Lua 5.5, which catches the 5.5
read-only-for-loop-variable change that the store rejects at publish time.
