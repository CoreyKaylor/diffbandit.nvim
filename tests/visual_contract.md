# DiffBandit Visual Contract

This contract records the IntelliJ-inspired behavior that the focused specs and tmux integration tests should preserve. Future specs should describe both the semantic diff and the terminal rendering details that make the visual mapping readable.

## Shared Principles

- Line numbers always represent real line numbers from their side of the diff. Alignment gaps are communicated by connector geometry, not by inserting filler text into source buffers.
- The gutter is split into three visual-only panes: left line numbers, connector core, and right line numbers. Source-number panes scroll with their owner source buffers; the connector core owns only route lines, underlines, and connector backgrounds.
- Connector shapes tell where a change originates and where it expands. Underlines mark the origin row, vertical bars carry distant paths, and triangle glyphs create the transition into the affected region.
- Triangle cells are transition cells. The affected background starts after the triangle for additions, and deletion gutter fill stops before the triangle so the glyph remains visually distinct.
- Triangle and wedge glyphs must be rendered in the relevant line-number pane and edge-docked to the connector side they connect with. They should not float in the middle of the connector core; middle-gutter space is reserved for rails, underlines, and lane separation.
- Triangle orientation is path-directional, not fixed only by diff kind. The glyph must flip when the connector rail approaches from the opposite vertical direction so the rail/underline visually touches the triangle's point or open edge.
- Adjacent or overlapping change regions must not touch in the gutter. When paths are close, lanes must stay compact and leave at least one clear transition cell between unrelated regions.
- Native terminal underline is the required representation for separator spans. Diagrams may use `▁`, but implementation and integration tests should inspect ANSI underline (`SGR 4`) rather than literal underline characters.
- ANSI captures are part of the spec. Plain captures verify glyph geometry and text placement; `capture-pane -e` verifies color backgrounds, underline spans, and token-level emphasis.
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

- A replacement followed by adjacent added-only rows is rendered as one mixed change/add envelope in the gutter, not as a separate add route.
- The replacement row keeps change background, while a truly appended suffix on the right can use add background for just the added suffix.
- Embedded added-only rows keep add background on their text, then return to the surrounding change envelope after the added text ends.
- Mixed envelope wedges soften the route edge and render in the leftmost cell of the right number pane. Background should begin after the top wedge, continue through the right line number, and return after the terminal added text.
- Deletions inside mixed views still use the compact deletion route: left-side delete background, left-docked delete triangle, right-origin underline, and no gutter overlap with neighboring blue routes.

## Scroll-Clipped Routes

Scroll behavior uses the compact visual row model shared by the connector, not raw original line numbers or native Neovim `scrollbind`:

- Scrolling the left or right content pane scrolls only that content pane and its corresponding line-number pane. The opposite content/number pair remains independent.
- The connector pane is visual-only and non-interactive; it follows explicit navigation and viewport projection rather than user focus.
- DiffBandit windows must disable native `scrollbind`, `cursorbind`, folds, and inherited scroll offsets that would fight custom synchronization.
- Triangles and wedges are connection glyphs, not viewport-edge markers. They appear only when their real underline/origin/destination connection row is visible or immediately adjacent.
- Scrolled-through middle rows show rails/background continuity without synthetic triangles or wedges at the viewport boundary.
- Scroll clipping must not change the transition-cell rules: add background starts after the add transition cell, delete background stops before the delete transition cell, and unrelated gutter regions must still not touch.
- Mixed change/add envelopes keep right-docked wedges only at the real envelope edge rows.

## Future Spec Checklist

Every new visual spec should include:

- The input files and the semantic diff being exercised.
- Expected pane backgrounds for context, add, delete, change, and word-level emphasis.
- Expected connector glyphs, their display rows, and whether each glyph is a transition cell or a filled cell.
- Expected connector approach direction for triangle glyphs, including whether the glyph should flip for from-above, from-below, or scroll-clipped paths.
- Origin underline rows and whether they must reach a pane or gutter edge.
- Lane assignment expectations when multiple paths overlap.
- ANSI integration checks for background starts/stops, underline spans, and token-level color splits.
