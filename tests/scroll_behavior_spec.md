# Scroll Behavior Visual Contract

## Purpose

DiffBandit uses compact source buffers and a full aligned connector buffer. Scrolling must stay tied to the compact visual row model, not raw original line numbers and not Neovim's native `scrollbind`.

## Shared Scroll Rules

- Scrolling the left pane, right pane, or connector pane updates the other panes to the same compact screen row when possible.
- If the requested screen row is beyond a side's compact buffer near EOF, that side clamps to its final row while the connector can continue through its aligned route rows.
- Native `scrollbind`, `cursorbind`, folds, and inherited scroll offsets must not change the layout; DiffBandit owns synchronization.
- Gutter routes are viewport-aware. Scrolled-through middle rows show rails/background continuity; they do not invent transition glyphs just because a route crosses the viewport boundary.
- Transition-cell rules do not change while scrolling:
  - Addition and mixed change/add backgrounds begin after the right-docked triangle/wedge.
  - Deletion background stops before the left-docked triangle.
  - Triangles and wedges never float in the middle of the gutter.
- Triangles and wedges appear only on real connection rows close to the underline, origin, or destination they are connecting. If that connection row is off-screen, only the rail/background continuity is shown.

## Scroll Addition Fixture

Files:

- `tests/files/left_scroll_additions.txt`
- `tests/files/right_scroll_additions.txt`

Expected behavior:

- Long right-side addition blocks remain green in the right pane.
- Left origin rows keep native green underlines when visible.
- If the origin/transition row is above the viewport and the addition block is visible, the gutter shows the rail/background continuity without a synthetic triangle.
- Add background starts after the transition cell only on rows where the real transition glyph is visible.

## Scroll Deletion Fixture

Files:

- `tests/files/left_scroll_deletions.txt`
- `tests/files/right_scroll_deletions.txt`

Expected behavior:

- Long left-side deletion blocks remain grey/delete colored in the left pane.
- Right origin rows keep native delete underlines when visible.
- If the origin/transition row is above the viewport and the deletion block is visible, the gutter shows the rail/background continuity without a synthetic triangle.
- Delete gutter background stays compact on the left side and stops before the transition cell.

## Scroll Mixed Fixture

Files:

- `tests/files/left_scroll_mixed.txt`
- `tests/files/right_scroll_mixed.txt`

Expected behavior:

- A changed row followed by added-only rows remains one mixed change/add envelope.
- Changed words retain darker change emphasis on both sides after scrolling.
- Added-only text remains green, with cells after terminal added text returning to blue change envelope.
- If the top or bottom mixed wedge scrolls out of view, middle mixed rows continue the route without a synthetic wedge.
- Nearby deletion routes keep the compact left-docked delete behavior and must not touch the mixed route.

## Integration Capture Expectations

Each scroll integration scenario should capture:

- `initial`: unscrolled view.
- `top-clipped`: viewport starts inside the first large diff region.
- `middle-clipped`: viewport starts well inside the large region.
- `bottom-clipped`: viewport ends inside the large region.
- `clamped-end`: viewport near EOF where one side may be shorter.

Plain captures verify line alignment and glyph placement. ANSI captures verify backgrounds, underline spans, and token-level emphasis.
