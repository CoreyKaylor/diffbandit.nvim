# Dense Mixed Conflict Fixture

This fixture is intentionally synthetic. It protects connector routing when mixed change, add, and delete regions are close enough that independently scrolling one side can project several routes into the same connector rows.

## Inputs

- `tests/files/left_dense_mixed.txt`
- `tests/files/right_dense_mixed.txt`

The diff includes:

- A top two-line change.
- A nearby top deletion.
- Two standalone insertion blocks.
- A lower mixed change/add envelope.
- A lower deletion that can overlap the lower mixed route after scrolling.

## Required Behavior

- The connector core width is calculated before first render from potential projected lane pressure.
- The default connector width remains `12` for one-, two-, and three-lane projections.
- Spacer lanes are reserved between overlapping same-direction change/delete routes so adjacent routes do not visually touch.
- A seven-lane projected conflict expands the connector core to `22` and does not resize while scrolling.
- Connector rail visibility is capped at eight competing vertical routes; larger conflicts prune the farthest offscreen continuation routes before widening beyond the eight-route width.
- Add, delete, and change routes share collision detection. No route may overlap or touch another route in the connector core.
- Lane reuse is allowed only after a route no longer overlaps the candidate route's occupied range.

## Protected Viewports

- Initial: `left_top=1`, `right_top=1`; the connector core is already the final stable width.
- Pre-conflict: `left_top=1`, `right_top=38`; lower mixed/add routes approach the conflict region.
- Dense conflict: `left_top=1`, `right_top=46`; the connector uses distinct rail columns without visual touching.
- Post-conflict: `left_top=1`, `right_top=53`; routes clip or terminate without shrinking the core.
- Lane reuse: `left_top=8`, `right_top=46`; previously conflicting space can be reused only when ranges no longer overlap.
