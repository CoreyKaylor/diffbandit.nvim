# Extreme Additions Test Case

## Purpose
Tests complex overlapping addition scenarios to verify lane assignment and vertical bar routing.

## Test Files
- **Left**: `left_extreme.txt` (12 lines: Alpha through Lima)
- **Right**: `right_extreme.txt` (34 lines: original content + additions after certain lines)

## Addition Blocks

| Origin (Left) | Additions | Display Rows | Triangle Row | Lane | Bar Rows |
|--------------|-----------|--------------|--------------|------|----------|
| Bravo (2)    | 2 lines   | 3-4          | 3            | 1    | none (adjacent) |
| Charlie (3)  | 3 lines   | 6-8          | 6            | 1    | 4-5 |
| Delta (4)    | 2 lines   | 10-11        | 10           | 2    | 5-9 |
| Foxtrot (6)  | 10 lines  | 14-23        | 14           | 3    | 7-13 |
| Golf (7)     | 3 lines   | 25-27        | 25           | 4    | 8-24 |
| Hotel (8)    | 2 lines   | 29-30        | 29           | 5    | 9-28 |

## Expected Visual Output (Gutter)

```
Row  │ Left#  Connector        Right# │ Notes
─────┼────────────────────────────────┼──────────────────────
  1  │   1                        1   │ Alpha - context
  2  │   2▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁   2   │ Bravo - origin, underline
  3  │   3▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  ◥3   │ Charlie origin + Bravo triangle
  4  │   4▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  │  4   │ Delta origin + bar
  5  │   5                 │ │  5   │ Echo - 2 bars active
  6  │   6▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  │  ◥6   │ Foxtrot origin + Charlie triangle
  7  │   7▁▁▁▁▁▁▁▁▁▁▁▁▁  │ │   7   │ Golf origin + 2 bars
  8  │   8▁▁▁▁▁▁▁▁▁▁▁  │ │ │   8   │ Hotel origin + 3 bars
  9  │   9           │ │ │ │▁▁ 9   │ India + 4 bars + tail underline
 10  │  10           │ │ │    ◥10  │ Delta triangle + 3 bars
 11  │  11           │ │ │     11  │ 3 bars continue
 12  │  12           │ │ │     12  │ Echo - 3 bars
 13  │               │ │ │▁▁▁▁ 13  │ Foxtrot + tail underline
 14  │               │ │      ◥14  │ Foxtrot triangle + 2 bars
...  │               │ │       ... │ (Foxtrot additions continue)
 24  │               │ │▁▁▁▁▁▁ 24  │ Golf + tail underline
 25  │               │        ◥25  │ Golf triangle + 1 bar
...  │               │         ... │ (Golf additions continue)
 28  │               │▁▁▁▁▁▁▁▁ 28  │ Hotel + tail underline
 29  │                       ◥29   │ Hotel triangle
...  │                        ...  │ (remaining content)
```

## Key Test Scenarios

### 1. First Overlap Group (Lines 2-4)
- Bravo → 2 additions, triangle adjacent (no bar needed)
- Charlie → 3 additions, lane 1 bar from row 4-5
- Delta → 2 additions, lane 2 bar (overlaps with Charlie's)
- **Tests**: 2-level nesting

### 2. Large Block with Deep Nesting (Lines 6-8)
- Foxtrot → 10 additions, lane 3 bar (long span)
- Golf → 3 additions, lane 4 bar (nested inside Foxtrot's span)
- Hotel → 2 additions, lane 5 bar (deepest nesting)
- **Tests**: 5-level deep nesting, long vertical bars

## Visual Requirements
- Underlines (`▁`) on origin rows extend to their lane's vertical bar position
- Vertical bars (`│`) maintain consistent column per lane across all rows
- Tail underlines appear on rows just before triangles (connecting bar to triangle)
- Triangles (`◥`) mark the first line of each addition block
- No visual collisions between bars in different lanes

## Run Test
```vim
:DiffBandit tests/files/left_extreme.txt tests/files/right_extreme.txt
```
