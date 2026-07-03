# Mixed Add + Delete Test Case - Expected Behavior

## Test Files
- **Left**: `left_mixed.txt`
- **Right**: `right_mixed.txt`

## Purpose
Verify a single file can contain **changes**, **deletions**, and **additions** simultaneously, with IntelliJ-like gutter semantics:
- Line numbers always represent the actual line numbers for that side’s file.
- The gutter’s connector shapes + triangles/underlines tell the “story” of how the diff maps.
- The same visual contracts from `visual_contract.md` apply when add/delete/change regions are adjacent.

## Expected Behavior (high-level)

### Change block: `Old value A/B` → `New value A/B`
- Left + right panes: change background (blue).
- Gutter: change background (blue) and multi-row change connector (`start/finish`).
- Word-level emphasis:
  - Left side emphasizes only `Old` with the darker change background; `value A/B` keeps the lighter change background.
  - Right side emphasizes only `New` with the darker change background; `value A/B` keeps the lighter change background.

### Deletion: `Delete this line`
- Left pane: delete background on the deleted line.
- Gutter:
  - Delete background appears in the left number pane and stops before the triangle.
  - The delete triangle (`◤`) sits in the rightmost cell of the left number pane (`6◤` in this fixture).
  - `◤` is the expected orientation for this fixture's visible route. Scroll-clipped or from-below routes may flip the glyph if needed to keep the rail/underline connected to the transition cell.
  - The triangle cell is a transition cell, not part of the delete background fill.
- Right side: native delete underline on the origin line immediately before the deletion. It must reach the right edge of the gutter and start after the triangle/rail cell in the connector area.

### Change + adjacent additions: `Original text here` → `Modified…` + `Added line 1/2`
Linematch splits this region into two chunks: a 1↔1 change (`Original text here` →
`Modified text here with extra content`) and a zero-context adjacent add chunk
(`Added line 1/2`). Chunks are the staging unit, so their backgrounds and routes
never fuse.
- Left replacement line: change background (blue), with the changed token `Original` emphasized by a darker change background.
- Right replacement line:
  - `Modified` is emphasized with darker change background.
  - `text here` keeps the lighter change background.
  - `with extra content` uses add background because it is appended text.
- Added-only lines: full add background (green) across the text and to the end of the row, including their right line numbers — they are an independent add chunk, not part of a change envelope.
- Gutter:
  - The change chunk routes on its own; the add chunk draws its own route with its origin wedge in the left number pane (`8◤` in this fixture).
  - Wedges render in the leftmost cell of the right number pane (`◢7` for the change target, `◢8`/`◥9` around the add band in this fixture). They must not float in the connector core.
  - Wedge orientation is part of the route shape. Scrolled-through middle rows must not invent synthetic wedges; wedges appear only when the real connection rows are visible.
  - The change and add routes stay visually separate; they may share an edge cell only where both genuinely dock on the same row and pane edge.

## Notes
- Add/delete rows produced inside a `change` hunk still use true add/delete pane backgrounds.
- Embedded adds merge into a change band only within their own chunk (uneven change hunks that linematch bypasses). Adjacent added-only rows in a *separate* chunk always route independently, even with zero context between the chunks.
- Chevrons/buttons from IntelliJ are intentionally out of scope for DiffBandit. Pull/apply actions belong to keybindings or commands.

## Integration Regression Checks

The tmux integration verifier should protect these visual details:

- Plain capture contains the delete triangle at `6◤` and the change/add wedges.
- ANSI capture shows left changed-token emphasis for `Old` and `Original`.
- ANSI capture shows right changed-token emphasis for `New` and `Modified`.
- ANSI capture distinguishes the replacement tail (`text here`) from the appended suffix (`with extra content`).
- ANSI capture shows `Added line 2` keeping its add background after the text, distinct from the change background.
- Plain/ANSI capture shows wedges in the number panes, not centered in the connector core.
