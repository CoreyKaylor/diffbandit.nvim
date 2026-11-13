# DiffBandit Visual Contract

This contract records the IntelliJ-inspired behavior that the integration tests (`tests/helpers/verify.lua`) preserve. Where this document and the working software disagree, treat the software as correct and update this document.

## Shared Principles

- Line numbers always represent real line numbers from their side of the diff. Alignment gaps are communicated by connector geometry, not by inserting filler text into source buffers.
- The gutter is split into three visual-only panes: left line numbers, connector core, and right line numbers. Source-number panes scroll with their owner source buffers; the connector core owns only route lines, underlines, and connector backgrounds.
- Each number pane is exactly one blank cell, the widest line number in its document (merge: across all three documents), and one blank cell. Numbers align away from the connector, toward their document, so a shorter number leaves its spare cells beside the triangle/wedge column. The blank cell facing the connector is the triangle/wedge column.
- The number panes and the connector core read as one gutter: the window separators between them are invisible. With the cell renderer, a one-column bridge over each of them continues the core's edge cell (bands, underlines, active tint), so an underline or band meets the triangle or wedge with no blank cell in between. Rail glyphs stay inside the core. The separators between each document and its number pane stay visible on plain rows; a bridge over each takes the band color where the number pane's outer cell is banded and underlines the separator glyph on insertion rows, so a band runs unbroken from one document through the gutter to the other.
- Connector shapes tell where a change originates and where it expands. Underlines mark the origin row, vertical bars carry distant paths, and triangle glyphs create the transition into the affected region.
- Triangle cells are transition cells. The affected background starts after the triangle for additions, and deletion gutter fill stops before the triangle so the glyph remains visually distinct.
- Triangle and wedge glyphs must be rendered in the relevant line-number pane and edge-docked to the connector side they connect with. They should not float in the middle of the connector core; middle-gutter space is reserved for rails, underlines, and lane separation.
- Triangle orientation is path-directional, not fixed only by diff kind. The glyph must flip when the connector rail approaches from the opposite vertical direction so the rail/underline visually touches the triangle's point or open edge.
- Adjacent or overlapping change regions must not touch in the gutter. When paths are close, lanes must stay compact and leave at least one clear transition cell between unrelated regions.
- Route lines and rails crossing a solid connector band decorate it instead of cutting it: the band background continues underneath while the crossing route's underline/rail renders on top, so both stay visible on shared rows. The same rule covers number-pane spacer cells on delete-origin rows inside a change band — the band fills the whole pane width and the origin underline rides over it, so the corridor never shows a bare default cell between the core and the number text.
- Native terminal underline is the required representation for separator spans. Diagrams may use `▁`, but implementation and integration tests should inspect ANSI underline (`SGR 4`) rather than literal underline characters.
- ANSI captures are part of the spec. Plain captures verify glyph geometry and text placement; the ANSI capture (`tests/helpers/child.lua`, same format as `tmux capture-pane -e`) verifies color backgrounds, underline spans, and token-level emphasis.
- Optional overview gutters are independent one-column visual maps at the outer edges of the diff view. They summarize side-native changed rows proportionally across the source viewport height and must not affect source text, line-number panes, connector routing, or scroll synchronization.

## Additions

- Added content lives on the right pane with full-width add background.
- The origin row on the left pane gets a native add underline that extends into the gutter.
- The add triangle (`◥`) sits at the first added display row, near the right side of the gutter.
- The exact add triangle orientation may flip when the visible rail approaches the target from below instead of above. The invariant is that the connector touches the triangle cleanly and the add background still begins after the transition cell.
- The add background begins immediately after the triangle cell in the right number pane and flows through the right number pane and right content. It must not paint the triangle cell itself.
- Distant additions use vertical bars and tail underlines to connect the origin underline to the triangle. Overlapping paths use separate lanes, moving progressively left as nesting increases.

## Deletions

- Deleted content lives on the left pane with full-width delete background.
- The origin row on the right pane gets a native delete underline that extends leftward into the gutter and reaches the right edge of the gutter.
- The delete triangle sits in the rightmost cell of the left number pane on the deleted display row. From-above deletion paths use `◤`; from-below paths use the mirrored delete glyph.
- The exact delete triangle orientation may flip when the visible rail approaches the target from below instead of above. The invariant is that the rail/underline meets the transition glyph without overlap, and delete background still stops before the transition cell.
- Delete gutter background starts in the left number pane and stops before the triangle. The triangle, rails, and underlines then connect the left-side deletion region to the right-side origin.
- Delete routes must stay compact at the left number pane edge. Rails and underlines carry the path across the connector core; broad delete background must not consume the connector core or collide with nearby change/add routes.

## Changes

- Changed rows use change background on both panes and the gutter route.
- Word-level replacement emphasis uses a darker change background only on the changed token. Unchanged replacement tails keep the lighter change background.
- The same word-level rule applies on both sides: old changed words on the left and new changed words on the right should both be emphasized.

## Mixed Change/Add/Delete Hunks

- Chunks are the staging unit: change bands and routes never fuse across chunk boundaries. A replacement followed by an adjacent added-only chunk renders as two independent routes, even with zero context between them.
- Embedded added-only rows merge into a change band only when they belong to the same chunk (uneven change hunks that linematch bypasses); those rows keep add background on their text and return to the surrounding change band after it ends.
- The replacement row keeps change background, while a truly appended suffix on the right can use add background for just the added suffix.
- Independent added-only chunks use full add background across text, trailing cells, and their right line numbers.
- Wedges soften the route edge and render in the leftmost cell of a number pane, never floating in the connector core.
- Deletions inside mixed views still use the compact deletion route: left-side delete background, left-docked delete triangle, right-origin underline, and no gutter overlap with neighboring blue routes.

## Three-Way Merge Result Pane

The merge view renders two pair diffs (local→result and remote→result) into one
shared center result buffer. Both pairs treat the result as their "new" side.

- The result content pane prioritizes the change diff: when one pair reads a
  result row as added while the other reads it as changed, the change band and
  word-level emphasis win the content area. The add presentation stays in that
  pair's own gutter — origin underline, wedges, and line numbers keep the add
  color there.
- Mechanically, shared-result add bands are range marks placed just below the
  change band priority; add line highlights are forbidden in the result buffer
  because line highlights beat range highlights regardless of priority.
- On shared-result change rows, appended-suffix text uses change emphasis, not
  add background — green marks never appear inside the result content pane.
- The red `▔` zero-range overlay (plus the `◤`/`◥` gutter markers) is reserved
  for an empty result document, where there is no content row it could hide.
  Zero-range conflict regions inside a non-empty result rely on the pair
  renderers' standard delete routes: wedges on the real outer rows and the
  delete-origin underline on the result boundary row.
- Side-only lines (content one branch has that the result lacks) keep the
  delete-family presentation in their own pane and gutter; change rows must
  never inherit red route glyphs from a neighboring zero-range region.

## Scroll-Clipped Routes

Scroll behavior uses the compact visual row model shared by the connector, not raw original line numbers or native Neovim `scrollbind`:

- Scrolling the left or right content pane scrolls its corresponding line-number pane. With the scroll lock on (the default) the opposite pair follows through the diff, holding at an added or deleted block's origin; with it off, the opposite pair remains independent.
- Scrolling a content pane sideways (`zl`, `zh`, or the cursor running past the edge) scrolls the other pane to the same columns when the horizontal scroll lock is on (the default). If the other pane's cursor line is too short to reach those columns, its cursor moves to the nearest visible line that is long enough. A pane with `'wrap'` never scrolls sideways.
- The connector pane is visual-only and non-interactive; it follows explicit navigation and viewport projection rather than user focus.
- DiffBandit's helper windows (number, connector, overview, header) must keep native `scrollbind` and `cursorbind` off, even after `:windo set scrollbind`; folds and inherited scroll offsets must not fight custom synchronization. Content panes keep a user's `scrollbind`.
- Triangles and wedges are connection glyphs, not viewport-edge markers. They appear only when their real underline/origin/destination connection row is visible or immediately adjacent.
- Scrolled-through middle rows show rails/background continuity without synthetic triangles or wedges at the viewport boundary.
- Scroll clipping must not change the transition-cell rules: add background starts after the add transition cell, delete background stops before the delete transition cell, and unrelated gutter regions must still not touch.
- Routes keep right-docked wedges only on their real connection rows; adds hide their wedge when the origin scrolls offscreen.
