# Pure Additions Test Case - Expected Behavior

## Test Files
- **Left**: `left_additions.txt` (6 lines including blank)
- **Right**: `right_additions.txt` (12 lines including blank)

## File Contents

**Left (6 lines):**
```
1. Alpha
2. Beta
3. Gamma
4. Delta
5. Epsilon
6. (blank)
```

**Right (12 lines):**
```
1. Alpha
2. Beta
3. New line 1  ← added
4. New line 2  ← added
5. Gamma
6. Delta
7. New line 3  ← added
8. New line 4  ← added
9. New line 5  ← added
10. Epsilon
11. New line 6  ← added
12. (blank)
```

## Expected Visual Output

```
┌─────────────────────────┬────────────────────────┬─────────────────────┐
│   LEFT PANE             │   GUTTER PANE          │    RIGHT PANE       │
├─────────────────────────┼────────────────────────┼─────────────────────┤
│ Alpha                   │  1            1        │ Alpha               │
│ Beta▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ │  2▁▁▁▁▁▁▁▁▁▁▁ 2        │ Beta                │
│ Gamma                   │  3           ◥3        │ New line 1 [GRN BG] │
│ Delta▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ │  4▁▁▁▁▁▁▁▁▁▁  4        │ New line 2 [GRN BG] │
│ Epsilon▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ │  5▁▁▁▁▁▁▁▁  │ 5        │ Gamma               │
│                         │  6        │ │ 6        │ Delta               │
│ ~                       │           │  ◥7        │ New line 3 [GRN BG] │
│ ~                       │           │   8        │ New line 4 [GRN BG] │
│ ~                       │           │   9        │ New line 5 [GRN BG] │
│ ~                       │           │▁▁ 10       │ Epsilon             │
│ ~                       │              ◥11       │ New line 6 [GRN BG] │
│ ~                       │               12       │                     │
└─────────────────────────┴────────────────────────┴─────────────────────┘
```
**IMPORTANT** Visual output `▁` represents underline characters rendered via extmarks.

**Legend:**
- `▁` = Green underline extending from left pane into gutter (connects to vertical bar or triangle)
- `◥` = Triangle glyph marking start of addition block
- `│` = Vertical bar glyph (flow continuation between origin and triangle)
- `[GRN BG]` = Full-line green background on added lines
- `~` = Empty line indicator (left buffer has fewer lines than right)

## Key Requirements

### Left Pane (6 buffer lines)
- Contains exactly 6 lines from the original file
- Display rows 1-6 show actual content (Alpha, Beta, Gamma, Delta, Epsilon, blank)
- Display rows 7-12 show `~` (empty buffer indicator)
- Green underlines (`▁`) appear on origin rows where additions follow:
  - Row 2 (Beta) - underline connects to triangle at row 3
  - Row 4 (Delta) - underline connects to vertical bar leading to triangle at row 7
  - Row 5 (Epsilon) - underline connects to vertical bar leading to triangle at row 11

### Gutter Pane (12 display rows)

**Line Numbers:**
- Left side: 1,2,3,4,5,6 (appears on display rows 1-6, empty for rows 7-12)
- Right side: 1-12 (one per row, aligned to same column)

**Visual Connectors:**
- Triangles (◥) appear at: rows 3, 7, 11 (first line of each addition block)
- Vertical bars (│) connect origin underlines to distant triangles:
  - From row 4 origin → bar on rows 5-6 → triangle at row 7
  - From row 5 origin → bar on rows 6-10 → triangle at row 11
- Underlines (▁) appear on origin rows and as "tail" underlines before triangles

**Green Background:**
- Appears to the RIGHT of triangles on addition rows (3,4,7,8,9,11)
- Flows seamlessly into the right pane green backgrounds

### Right Pane (12 buffer lines)
- All 12 lines displayed with proper content
- Full-line green backgrounds on rows 3,4,7,8,9,11 (the added lines)
- Context lines (1,2,5,6,10,12) have normal background

## Lane Assignment Logic

### Purpose
When multiple addition regions overlap (their vertical bars would collide), each path is assigned to a different "lane" - a distinct column position for its vertical bar.

### Rules
1. **Lane 1**: Rightmost position (closest to right line numbers)
2. **Higher lanes**: Move progressively left as nesting increases
3. **Lane reuse**: When a path's bar ends (reaches its triangle), that lane becomes available

### Example from Test Case

**First Addition Block (rows 3-4, from Beta):**
- Triangle at row 3, no vertical bar needed (adjacent to origin)
- Second line at row 4 continues the addition

**Second Addition Block (rows 7-9, from Delta):**
- Origin at row 4, triangle at row 7
- Vertical bar spans rows 5-6 in lane 1
- The bar from Epsilon (row 5) needs lane 2 since lane 1 is occupied

**Third Addition Block (row 11, from Epsilon):**
- Origin at row 5, triangle at row 11
- Vertical bar spans rows 6-10 in lane 2 (avoiding Delta's bar)

### Visual Flow Interpretation
The lane system tells a story: "multiple expansions from the left side flow into the right, and when they overlap visually, each gets its own vertical track to maintain clarity."

## Color Specifications

### Green Underlines (Left Pane)
- Applied to rows 2, 4, 5
- Extends from text to right edge of left pane
- Continues into gutter area
- Should use the "add" color from colorscheme (typically green)

### Green Backgrounds (Right Pane)
- Full-line backgrounds on rows 3,4,7,8,9,11
- Should match DiffAdd highlight color
- Extends to full window width

### Green Gutter Flow (Gutter Pane)
- Background color to the RIGHT of glyphs on addition rows
- Creates seamless color flow from gutter to right pane
- Should match the same green as right pane backgrounds

## Testing

Use tmux for interactive sessions and capture-pane -e to ensure colors are captured as well.
