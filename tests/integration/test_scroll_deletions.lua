-- Scroll scenario: scroll-deletions (left_scroll_deletions.txt vs right_scroll_deletions.txt).
return require("helpers.scroll").set({
  scenario = "scroll-deletions",
  left = "left_scroll_deletions.txt",
  right = "right_scroll_deletions.txt",
  -- { phase, left_topline, right_topline, tall (120x40 instead of 120x16) }
  phases = {
    { "initial", 1, 1 },
    { "target-aligned", 2, 1 },
    { "target-flipped", 3, 1 },
    { "target-spanning", 4, 1 },
    { "lower-target-below", 50, 1 },
    { "lower-target-approach", 52, 1 },
    { "same-row-upper", 53, 1 },
    { "upper-target-exiting", 54, 1 },
    { "lower-target-entering", 55, 1 },
    { "pre-overlap-inner", 56, 1 },
    { "pre-collision-inner", 57, 1 },
    { "target-above", 58, 1 },
    { "upper-target-clipped", 59, 1 },
    { "overlap-stepped", 60, 1 },
    { "hidden-overlap-inner", 63, 1 },
    { "origin-offscreen", 25, 10 },
    { "clamped-end", 69, 13 },
  },
  -- { phase, focused side, j presses }
  keys = {
    { "left-j-scroll", "left", 25 },
    { "left-j-scroll-line39", "left", 38 },
    { "left-j-scroll-line41", "left", 40 },
  },
})
