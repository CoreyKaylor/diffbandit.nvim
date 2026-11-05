-- Scroll scenario: scroll-additions (left_scroll_additions.txt vs right_scroll_additions.txt).
return require("helpers.scroll").set({
  scenario = "scroll-additions",
  left = "left_scroll_additions.txt",
  right = "right_scroll_additions.txt",
  -- { phase, left_topline, right_topline, tall (120x40 instead of 120x16) }
  phases = {
    { "initial", 1, 1 },
    { "target-above", 1, 58 },
    { "target-aligned", 1, 2 },
    { "target-flipped", 1, 3 },
    { "target-spanning", 1, 4 },
    { "lower-target-below", 1, 45 },
    { "lower-target-approach", 1, 50 },
    { "same-row-upper", 1, 51 },
    { "upper-target-exiting", 1, 52 },
    { "lower-target-entering", 1, 53 },
    { "pre-overlap-inner", 1, 54 },
    { "lower-target-anchor", 1, 55 },
    { "pre-collision-inner", 1, 59 },
    { "upper-target-clipped", 1, 60 },
    { "overlap-stepped", 1, 61 },
    { "hidden-overlap-inner", 1, 64 },
    { "origin-offscreen", 10, 25 },
    { "clamped-end", 13, 69 },
    { "overscroll-end", 20, 76 },
  },
  -- { phase, focused side, j presses }
  keys = {
    { "right-j-scroll", "right", 25 },
    { "right-j-scroll-line39", "right", 38 },
    { "right-j-scroll-line41", "right", 40 },
  },
})
