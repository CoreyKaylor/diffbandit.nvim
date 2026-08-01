# Demo recordings

The GIFs embedded in the top-level `README.md` are generated, not hand-recorded.
Each one is a [VHS](https://github.com/charmbracelet/vhs) tape: a script that
drives a real Neovim in an embedded terminal and renders the result.

```bash
demo/record.sh                # render all clips into docs/demo/
demo/record.sh 03-merge       # just one (prefix match)
```

## Important: these tapes use *your* Neovim config

The tapes launch a bare `nvim`, with no `-u`. That is deliberate — clip 02 is a
demonstration that the right-hand pane of a diff is a real, editable document
with a language server attached, and that is only honest if the recording uses a
real editor setup. It also means the GIFs show DiffBandit in the theme it is
actually used in.

The consequence is that **these recordings are not contributor-reproducible**.
Running `record.sh` on another machine will produce something that looks
different, and clip 02 may show nothing interesting at all. Reproducing the
committed GIFs requires:

| requirement | why |
|---|---|
| DiffBandit loadable from this working tree | the tapes run `:DiffBandit*` commands |
| `lua-language-server` on `PATH` | clip 02's completion and diagnostics |
| a completion plugin that auto-triggers | clip 02's popup menu |
| `JetBrainsMono Nerd Font Mono` installed | icons render as tofu without a Nerd Font |
| `tic` (ncurses) | compiles `demo/terminfo/xterm-vhs.src` for colored underlines |
| a dark colorscheme | the tapes set a dark terminal background to match |

`record.sh` checks the ones it can check and fails early with an explanation.

The tapes make three small concessions for the VHS/xterm.js host:

- `vim.g.diffbandit_have_nerd_font = true` so `icons = "auto"` resolves to
  Nerd Font glyphs;
- `vim.g.diffbandit_cell_wedges = true` so connector wedges paint as Powerline
  extra symbols (U+E0B8–E0BE) instead of Unicode geometric triangles
  (U+25E2–25E5);
- `TERMINFO=/tmp/diffbandit-demo/terminfo TERM=xterm-vhs` when launching nvim
  so colored underlines (`guisp` / SGR 58) are actually emitted (see below).

After startup they also run `:set showtabline=0 laststatus=3 shortmess+=F` to
drop unrelated plugin chrome and suppress the "N lines" file-read message.
Nothing else is overridden.

### Why `cell_wedges`?

VHS renders through [ttyd](https://github.com/tsl0922/ttyd) + [xterm.js](https://xtermjs.org/).
xterm.js draws box-drawing and **Powerline** triangle private-use characters
with its own cell-filling vectors, but leaves U+25E2–25E5 (◢◣◤◥) to the font —
and every monospace font puts those on a typographic baseline with a gap above
the triangle. Ghostty (and similar native terminals) sprite the Unicode wedges
themselves, which is why the product looks correct in a real editor and wrong
under stock VHS.

`cell_wedges` remaps only at paint time. Geometry, tests, and normal users keep
Unicode. Demo-only alternatives (`ui.cell_wedges = true`,
`DIFFBANDIT_CELL_WEDGES=1`) do the same thing.

### Why `TERM=xterm-vhs`?

Origin underlines use native terminal underline with a special color
(`guisp` = add/delete band). xterm.js **can** paint that color (SGR 58), but
Neovim only emits SGR 58 when terminfo advertises colored underlines
(`Su` / `Setulc`). Stock `xterm-256color` (what ttyd reports) does not, so
underlines fall back to the default foreground — grey continuity into a green
add band.

Using Ghostty's full terminfo under VHS also switches truecolor to
colon-separated SGR (`38:2:…`), which xterm.js mishandles and washes the
colorscheme. So the tapes use a tiny custom entry — `demo/terminfo/xterm-vhs.src`
— that is `use=xterm-256color` plus only `Su`/`Setulc`/`Smulx`. That keeps
semicolon truecolor (correct under xterm.js) and adds green underlines.
`fixtures.sh` compiles it into `/tmp/diffbandit-demo/terminfo` with `tic`.

## Fixtures

`demo/fixtures.sh` builds `/tmp/diffbandit-demo/` from scratch:

- `pair/` — two versions of a small Lua module (clips 01, 02)
- `merge/` — a git repo genuinely mid-conflict (clip 03)
- `repo/` — clean history plus a dirty worktree (clip 04)
- `folder-left/`, `folder-right/` — two trees to compare (clip 05)

The "real code" fixtures are tracked under `demo/fixtures/`; the throwaway
folder-diff trees are generated inline by the script.

**The tapes mutate their fixtures.** Clip 03 resolves and stages a merge; clip 04
creates a commit. `record.sh` therefore rebuilds the fixtures before *every*
tape. Running `vhs demo/03-merge.tape` by hand a second time without rebuilding
will hang on a `Wait` for a conflict that no longer exists.

Fixture code is deliberately written to short lines, because panes are narrow and
anything longer simply truncates on screen. Current budgets, measured from the
rendered frames rather than calculated:

| clip | terminal | pane budget |
|---|---|---|
| 01, 02 (two panes) | 1240x640 | ~42 columns per side |
| 03 (three panes) | 1560x640 | ~28 per side, ~26 for the middle result pane |
| 04 (panel + two panes) | 1620x640 | 42-column panel, ~37 per diff pane |
| 05 (tree, then a child diff) | 1240x540 | ~42 per side |

## Sizing

All tapes run `FontSize 18`, `Padding 20`, and a 580px height (540 for the
folder clip, whose tree is short and would otherwise sit in dead space). Do
not set `LineHeight` above 1.0 for these tapes — it only widens the gap around
font-drawn glyphs, and values below 1.0 crash xterm.js.

The counter-intuitive part: **how large the text looks in the README depends on
the column count, not on `FontSize`.** GitHub scales every image to the same
content width, so a frame with 140 columns renders smaller text than one with
100 no matter what font size produced it. `FontSize` only buys native resolution
— worth having for high-DPI displays, but it will not make a cramped frame
readable.

So the levers, in order, when a clip feels cramped:

1. reduce columns — which usually means shortening the fixture code, since the
   layout's fixed costs (9-column connector, two number gutters, overview
   strips, the 42-column commit panel) do not shrink;
2. reduce rows, if the clip is showing more file than the beat needs;
3. only then adjust pixel width, and only to keep text from truncating.

Clips 03 and 04 are wider than the rest because their layouts are structurally
wider — three content panes, and a fixed-width panel alongside two panes. They
cannot be narrowed without truncating code.

## Editing a tape

Timing is the fiddly part. Prefer `Wait+Screen /regexp/` over a blind `Sleep`
wherever there is a string that only appears once the UI is ready
(`/merge result/`, `/lua_ls/`, a filename). Sleeps that remain are there to make
a beat *readable*, not to wait for correctness.

VHS cannot tell a mistimed `Sleep` from a correct one — a tape that records the
wrong thing still exits 0. Each tape writes stills to `docs/demo/.frames/`
(untracked) at every beat; read those to check a change rather than scrubbing
the GIF.

Two behaviours worth remembering, both learned the hard way:

- In the merge view the cursor opens at line 1, which is not inside a conflict,
  so `>>`/`<<` are no-ops there. Press `]c` first.
- In the folder view `]c` moves the selection between changed rows, but pressing
  it once past the last changed row opens that file's diff.
