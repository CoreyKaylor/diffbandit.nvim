-- Scroll scenario: scroll-dense-mixed (left_dense_mixed.txt vs right_dense_mixed.txt).
return require("helpers.scroll").set({
  scenario = "scroll-dense-mixed",
  left = "left_dense_mixed.txt",
  right = "right_dense_mixed.txt",
  -- { phase, left_topline, right_topline, tall (120x40 instead of 120x16) }
  phases = {
    { "initial", 1, 1 },
    { "top-route-separation", 1, 4 },
    { "pre-conflict", 1, 38 },
    { "lower-route-separation", 1, 42 },
    { "lower-route-entering", 1, 43 },
    { "four-lane-conflict", 1, 46 },
    { "post-conflict", 1, 53 },
    { "lane-reuse", 8, 46 },
    { "initial-tall", 1, 1, true },
    { "top-route-separation-tall", 1, 4, true },
    { "lower-route-separation-tall", 1, 42, true },
    { "lower-route-entering-tall", 1, 43, true },
    { "lower-four-lane-tall", 1, 46, true },
  },
  -- { phase, focused side, j presses }
  keys = {
    { "right-j-scroll", "right", 45 },
    { "left-j-scroll", "left", 8 },
  },
})
