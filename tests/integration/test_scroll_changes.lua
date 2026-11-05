-- Scroll scenario: scroll-changes (left_scroll_changes.txt vs right_scroll_changes.txt).
return require("helpers.scroll").set({
  scenario = "scroll-changes",
  left = "left_scroll_changes.txt",
  right = "right_scroll_changes.txt",
  -- { phase, left_topline, right_topline, tall (120x40 instead of 120x16) }
  phases = {
    { "initial", 1, 1 },
    { "right-diverged", 1, 5 },
    { "left-diverged", 5, 1 },
    { "both-diverged", 4, 6 },
    { "clamped-end", 20, 20 },
  },
  -- { phase, focused side, j presses }
  keys = {
    { "right-j-scroll", "right", 12 },
    { "left-j-scroll", "left", 12 },
  },
})
