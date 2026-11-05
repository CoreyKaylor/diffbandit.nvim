-- Scroll scenario: scroll-mixed (left_scroll_mixed.txt vs right_scroll_mixed.txt).
return require("helpers.scroll").set({
  scenario = "scroll-mixed",
  left = "left_scroll_mixed.txt",
  right = "right_scroll_mixed.txt",
  -- { phase, left_topline, right_topline, tall (120x40 instead of 120x16) }
  phases = {
    { "initial", 1, 1 },
    { "right-overlap-first", 1, 2 },
    { "right-overlap-exit", 1, 3 },
    { "right-overlap-past", 1, 4 },
    { "right-overlap-clipped", 1, 5 },
    { "right-overlap-middle", 1, 10 },
    { "right-tail-approach", 1, 47 },
    { "right-tail-aligned", 1, 49 },
    { "right-diverged", 1, 22 },
    { "left-diverged", 7, 1 },
    { "origin-offscreen", 12, 25 },
    { "clamped-end", 13, 56 },
  },
  -- { phase, focused side, j presses }
  keys = {
    { "right-j-scroll", "right", 25 },
    { "left-j-scroll", "left", 8 },
  },
})
