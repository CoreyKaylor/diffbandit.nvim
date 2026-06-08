# Pure Deletions Test Case - Expected Behavior

## Test Files
- **Left**: `left_deletions.txt` (11 lines)
- **Right**: `right_deletions.txt` (6 lines)

## File Contents

**Left (11 lines):**
```
1. First line
2. Second line
3. Line to delete 1  <- deleted
4. Line to delete 2  <- deleted
5. Line to delete 3  <- deleted
6. Third line
7. Fourth line
8. Line to delete 4  <- deleted
9. Line to delete 5  <- deleted
10. Fifth line
11. Sixth line
```

**Right (6 lines):**
```
1. First line
2. Second line
3. Third line
4. Fourth line
5. Fifth line
6. Sixth line
```

## Expected Visual Output

The plugin uses an architecture where buffers contain only real content (no filler lines).
Visual alignment is communicated through underlines, triangles, and gutter line numbers.

```
+--------------------------+----------------------+-------------------------+
|   LEFT PANE (buffer)     |   GUTTER             |    RIGHT PANE (buffer)  |
+--------------------------+----------------------+-------------------------+
| First line               |  1          1        | First line              |
| Second line              |  2     ^^^^ 2        | Second line^^^^^^^^^^^^^|
| Line to delete 1 [TAN]   |  3<                  | Third line              |
| Line to delete 2 [TAN]   |  4                   | Fourth line^^^^^^^^^^^^^|
| Line to delete 3 [TAN]   |  5                   | Fifth line              |
| Third line               |  6          3        | Sixth line              |
| Fourth line              |  7     ^^^^ 4        | ~                       |
| Line to delete 4 [TAN]   |  8<                  | ~                       |
| Line to delete 5 [TAN]   |  9                   | ~                       |
| Fifth line               | 10          5        | ~                       |
| Sixth line               | 11          6        | ~                       |
+--------------------------+----------------------+-------------------------+
```

**Architecture Note**: Right pane shows sequential buffer content. The gutter line numbers
indicate where content aligns logically:
- Display row 3 has left line 3 (deleted content) but no right line number
- Display row 6 has left line 6 and right line 3 (Third line)

The visual indicators (underlines, triangles) tell the alignment story without filler rows.

**IMPORTANT** Diagrams use `^`/`▁` as notation for separator underlines. The implementation renders these as native underlined spaces via extmarks, not literal buffer text.

**Legend:**
- `^` (▁) = Beige native underline extending from right pane LEFTWARD into gutter (connects to vertical bar or triangle)
- `<` (◤) = Triangle glyph pointing left, marking start of deletion block (docks to LEFT side of gutter)
- `|` (│) = Vertical bar glyph (flow continuation between origin and triangle)
- `[TAN]` = Full-line beige/tan background on deleted lines in left pane
- `~` = Empty line indicator (right buffer has fewer lines than display rows)

## Key Requirements

### Left Pane (11 buffer lines)
- Contains all 11 lines from the left file
- Display rows 1-11 show actual content
- Beige/tan backgrounds on deleted lines:
  - Rows 3-5 (Line to delete 1/2/3)
  - Rows 8-9 (Line to delete 4/5)

### Right Pane (6 buffer lines)
- Contains 6 lines from the right file
- Buffer lines 1-6 contain real content, display rows 7-11 show `~` (empty buffer indicator)
- Beige native underlines appear on origin rows where deletions follow:
  - Buffer row 2 (Second line) - underline before first deletion block
  - Buffer row 4 (Fourth line) - underline before second deletion block

### Gutter Pane (11 display rows)

**Line Numbers:**
- Left side: 1-11 (one per row, all rows have left content)
- Right side: 1-6 (shows where right content aligns with left content)

**Visual Connectors:**
- Triangles (◤) appear at: display rows 3, 8 (first line of each deletion block)
- Triangles dock to LEFT side of gutter (near left line numbers)
- Native underlines appear on origin rows in gutter extending toward triangles

**Beige Background:**
- Appears to the LEFT of triangles on deletion rows (3,4,5,8,9)
- Creates visual flow from left pane backgrounds into gutter

## Lane Assignment Logic

### Purpose
When multiple deletion regions overlap (their vertical bars would collide), each path is assigned to a different "lane" - a distinct column position for its vertical bar.

### Rules (Mirror of Additions)
1. **Lane 1**: Leftmost position (closest to left line numbers) - for deletions
2. **Higher lanes**: Move progressively right as nesting increases
3. **Lane reuse**: When a path's bar ends (reaches its triangle), that lane becomes available

### Example from Test Case

**First Deletion Block (rows 3-5, from Second line origin):**
- Origin at row 2 (display), triangle at row 3
- No vertical bar needed (adjacent to origin)

**Second Deletion Block (rows 8-9, from Fourth line origin):**
- Origin at row 7 (display), triangle at row 8
- Need to check if bar is needed based on distance

## Color Specifications

### Beige Underlines (Right Pane)
- Applied to origin rows (rows where deletion follows)
- Extends from text to left edge of right pane
- Continues into gutter area toward triangle
- Should use the "delete" color from colorscheme (typically beige/tan)

### Beige Backgrounds (Left Pane)
- Full-line backgrounds on rows 3,4,5,8,9
- Should match DiffDelete highlight color
- Extends to full window width

### Beige Gutter Flow (Gutter Pane)
- Background color to the LEFT of glyphs on deletion rows
- Creates seamless color flow from left pane to gutter
- Should match the same beige as left pane backgrounds

## Visual Flow Interpretation
The deletion visual tells a story: "content on the left was removed, leaving a gap on the right. The underline shows where the gap is, and the triangle/connector points back to where the deleted content exists."

## Testing

Use tmux for interactive sessions and capture-pane -e to ensure colors are captured as well.
