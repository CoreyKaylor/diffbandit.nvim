# Mixed Add + Delete Test Case - Expected Behavior

## Test Files
- **Left**: `left_mixed.txt`
- **Right**: `right_mixed.txt`

## Purpose
Verify a single file can contain **changes**, **deletions**, and **additions** simultaneously, with IntelliJ-like gutter semantics:
- Line numbers always represent the actual line numbers for that side’s file.
- The gutter’s connector shapes + triangles/underlines tell the “story” of how the diff maps.

## Expected Behavior (high-level)

### Change block: `Old value A/B` → `New value A/B`
- Left + right panes: change background (blue).
- Gutter: change background (blue) and multi-row change connector (`start/finish`).

### Deletion: `Delete this line`
- Left pane: delete background on the deleted line.
- Gutter: left-docked delete triangle (`◤`) on the deleted row.
- Right side: native delete underline on the origin line immediately before the deletion.

### Change + trailing additions: `Original text here` → `Modified…` + `Added line 1/2`
- Replacement line: change background (blue), with a green added suffix when the right line has appended text.
- Added-only lines: add background (green).
- Gutter:
  - One blue mixed change/add envelope covers the replacement row and adjacent added-only rows.
  - Top/bottom blue wedge glyphs approximate IntelliJ's softened route edge.
  - No separate green add triangle or add-origin underline is rendered for the embedded added-only rows.

## Notes
- Add/delete rows produced inside a `change` hunk still use true add/delete pane backgrounds.
- Adjacent added-only rows inside a mixed replacement are embedded in the blue route envelope so the gutter does not imply a separate add hunk.
