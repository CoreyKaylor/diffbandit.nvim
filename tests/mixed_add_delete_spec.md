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

### Change + trailing additions: `Original text here` → `Modified…` + `Added line 1/2`
- Left replacement line: change background (blue), with the changed token `Original` emphasized by a darker change background.
- Right replacement line:
  - `Modified` is emphasized with darker change background.
  - `text here` keeps the lighter change background.
  - `with extra content` uses add background because it is appended text.
- Added-only lines: their text uses add background (green), while the surrounding mixed route can remain in the change envelope.
- Gutter:
  - One blue mixed change/add envelope covers the replacement row and adjacent added-only rows.
  - Top/bottom blue wedge glyphs approximate IntelliJ's softened route edge.
  - Wedges render in the leftmost cell of the right number pane (`◢7`, `◥9` in this fixture). They must not float in the connector core.
  - Wedge orientation is part of the route shape. Scrolled-through middle rows must not invent synthetic wedges; wedges appear only when the real envelope edge row is visible.
  - Blue route background begins after the top wedge, not before it.
  - The right line numbers inside the mixed envelope participate in the blue route background.
  - No separate green add triangle or add-origin underline is rendered for the embedded added-only rows.
- Terminal embedded add row:
  - `Added line 2` uses add background through the end of the text.
  - The cells after the text return to the mixed change envelope background, matching IntelliJ's return from green added text to blue route fill.

## Notes
- Add/delete rows produced inside a `change` hunk still use true add/delete pane backgrounds.
- Adjacent added-only rows inside a mixed replacement are embedded in the blue route envelope so the gutter does not imply a separate add hunk.
- Chevrons/buttons from IntelliJ are intentionally out of scope for DiffBandit. Pull/apply actions belong to keybindings or commands.

## Integration Regression Checks

The tmux integration verifier should protect these visual details:

- Plain capture contains the delete triangle at `6◤` and the mixed top/bottom wedges.
- ANSI capture shows left changed-token emphasis for `Old` and `Original`.
- ANSI capture shows right changed-token emphasis for `New` and `Modified`.
- ANSI capture distinguishes the replacement tail (`text here`) from the appended suffix (`with extra content`).
- ANSI capture shows `Added line 2` returning to the blue mixed envelope after the text.
- ANSI capture shows no route background before the top mixed wedge and matching blue background after it.
- Plain/ANSI capture shows mixed wedges in the right number pane, not centered in the connector core.
