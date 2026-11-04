-- Kitty graphics image connector: protocol encoders, IntelliJ-style ribbon
-- geometry, rasterizer, capability detection, 2-way / merge integration, and
-- the cells fallback. Wrapped in one block so its locals stay out of the
-- shared runner chunk's top-level scope.
do
  local protocol = require("diffbandit.kitty.protocol")
  local curves = require("diffbandit.connector.curves")
  local raster = require("diffbandit.kitty.raster")
  local detect = require("diffbandit.kitty.detect")
  local kitty_canvas = require("diffbandit.kitty.canvas")
  local nvim_util = require("diffbandit.util.nvim")
  -- These specs exercise the raw (non-tmux) transport; the tmux transport
  -- has its own spec. Do not inherit the developer's $TMUX.
  local saved_tmux_env = vim.env.TMUX
  vim.env.TMUX = nil

  local function nr(cp)
    return vim.fn.nr2char(cp)
  end

  local function wait_for(pred, ms)
    return vim.wait(ms or 500, pred, 5)
  end

  -- Capture everything the integration would write to the terminal.
  local sent = {}
  local function reset_detect()
    detect._reset()
    detect._set_env(nil)
    sent = {}
    detect._set_sink(function(data)
      sent[#sent + 1] = data
    end)
  end

  local function count_matching(pattern)
    local n = 0
    for _, s in ipairs(sent) do
      if s:find(pattern, 1, true) then
        n = n + 1
      end
    end
    return n
  end

  -- ------------------------------------------------------------------
  -- protocol
  -- ------------------------------------------------------------------
  do
    assert_eq(#protocol.DIACRITICS, 297, "kitty diacritic table has 297 entries")
    assert_eq(protocol.MAX_INDEX, 296, "max addressable placeholder index")
    assert_eq(protocol.DIACRITICS[1], 0x0305, "row/col 0 diacritic")
    assert_eq(protocol.DIACRITICS[297], 0x1D244, "row/col 296 diacritic")

    for _, cp in ipairs({ 0x41, 0x0305, 0x20D0, 0xFE20, 0x10EEEE, 0x1D244 }) do
      assert_eq(protocol.utf8_char(cp), nr(cp), "utf8 encoding matches nr2char for " .. cp)
    end

    assert_eq(protocol.placeholder(0, 0), nr(0x10EEEE) .. nr(0x0305) .. nr(0x0305),
      "placeholder (0,0) = U+10EEEE + row diacritic + column diacritic")
    assert_eq(protocol.placeholder(1, 296), nr(0x10EEEE) .. nr(0x030D) .. nr(0x1D244),
      "placeholder (1,296) uses the second and last diacritics")
    assert_eq(protocol.placeholder(297, 0), nil, "row beyond the table is unaddressable")
    assert_eq(protocol.placeholder_run(2, 3, 2), protocol.placeholder(2, 3) .. protocol.placeholder(2, 4),
      "placeholder_run concatenates consecutive columns")
    assert_eq(vim.fn.strwidth(protocol.placeholder_run(0, 0, 9)), 9,
      "each placeholder cell (with diacritics) is one display cell")

    assert_eq(protocol.id_to_hex(0xDB0001), "#db0001", "image id encodes as 24-bit fg")
    assert_eq(protocol.hex_to_id("#db0001"), 0xDB0001, "fg hex decodes back to the id")

    for _, s in ipairs({ "", "a", "ab", "abc", "abcd", "\0\255\1\128\7" }) do
      assert_eq(protocol._base64_fallback(s), vim.base64.encode(s), "base64 fallback matches vim.base64")
    end

    local direct = protocol.transmit({ id = 7, width = 1, height = 1, cols = 2, rows = 3, data = "\1\2\3\4" })
    assert_eq(#direct, 1, "small payload is a single command")
    assert_eq(direct[1], "\27_Ga=T,U=1,f=32,i=7,s=1,v=1,c=2,r=3,q=2;" .. vim.base64.encode("\1\2\3\4") .. "\27\\",
      "direct transmit + virtual placement golden")

    local chunked = protocol.transmit({ id = 7, width = 2, height = 1, cols = 1, rows = 1, data = "\1\2\3\4\5\6\7\8", chunk_size = 4 })
    local b64 = vim.base64.encode("\1\2\3\4\5\6\7\8") -- 12 chars -> 3 chunks
    assert_eq(#chunked, 3, "payload splits into chunk_size pieces")
    assert_eq(chunked[1], "\27_Ga=T,U=1,f=32,i=7,s=2,v=1,c=1,r=1,q=2,m=1;" .. b64:sub(1, 4) .. "\27\\",
      "first chunk carries all keys and m=1")
    assert_eq(chunked[2], "\27_Gm=1,q=2;" .. b64:sub(5, 8) .. "\27\\", "middle chunk only m=1")
    assert_eq(chunked[3], "\27_Gm=0,q=2;" .. b64:sub(9, 12) .. "\27\\", "last chunk m=0 commits")

    local file = protocol.transmit({ id = 9, width = 4, height = 2, cols = 1, rows = 1, medium = "t", path = "/tmp/x", quiet = 1 })
    assert_eq(file[1], "\27_Ga=T,U=1,f=32,i=9,s=4,v=2,c=1,r=1,t=t,q=1;" .. vim.base64.encode("/tmp/x") .. "\27\\",
      "temp-file transmit golden")

    local z = protocol.transmit({ id = 7, width = 1, height = 1, cols = 1, rows = 1, data = "zz", compressed = true })
    assert_eq(z[1]:find("\27_Ga=T,U=1,f=32,o=z,i=7,", 1, true), 1, "compressed payload declares o=z")

    local zlib = require("diffbandit.kitty.zlib")
    if zlib.available() then
      local pixels = string.rep("\0\0\0\0", 5000) .. string.rep("\10\20\30\255", 200)
      local packed = zlib.compress(pixels, 1)
      assert_eq(#packed < #pixels / 10, true, "transparent-heavy RGBA compresses well")
      assert_eq(zlib.uncompress(packed, #pixels), pixels, "zlib payload round-trips")
    end

    assert_eq(protocol.query(5, "d"),"\27_Gi=5,s=1,v=1,a=q,U=1,t=d,f=24;AAAA\27\\", "query golden (asks about Unicode placeholders)")
    assert_eq(protocol.query(6, "t", "/tmp/p"), "\27_Gi=6,s=1,v=1,a=q,U=1,t=t,f=24;" .. vim.base64.encode("/tmp/p") .. "\27\\",
      "temp-file query golden")
    assert_eq(protocol.delete(5), "\27_Ga=d,d=I,i=5,q=2\27\\", "delete golden")

    local ok_reply = protocol.parse_response("\27_Gi=31;OK\27\\")
    assert_eq(ok_reply.id, 31, "reply id parsed")
    assert_eq(ok_reply.ok, true, "OK reply")
    local err_reply = protocol.parse_response("_Gi=31;ENOENT:file missing")
    assert_eq(err_reply.ok, false, "error reply")
    assert_eq(err_reply.message, "ENOENT:file missing", "error message kept")
    assert_eq(protocol.parse_response("\27]11;rgb:0/0/0\7"), nil, "non-graphics reply ignored")
    assert_eq(protocol.is_da1("\27[?62;22c"), true, "DA1 reply recognised")
    assert_eq(protocol.is_da1("\27_Gi=1;OK\27\\"), false, "graphics reply is not DA1")
  end

  -- ------------------------------------------------------------------
  -- curves (IntelliJ divider geometry)
  -- ------------------------------------------------------------------
  do
    local change = { kind = "change", chunk = 1, start_left_index = 5, end_left_index = 7, start_right_index = 10, end_right_index = 10 }
    local add = { kind = "add", chunk = 2, origin_left_index = 3, target_start_index = 4, target_end_index = 5 }
    local top_add = { kind = "add", chunk = 3, origin_left_index = nil, target_start_index = 1, target_end_index = 1 }
    local delete = { kind = "delete", chunk = 4, origin_right_index = 8, target_start_index = 9, target_end_index = 9 }
    local embedded = { kind = "add", chunk = 1, embedded_in_change = true, origin_left_index = 5, target_start_index = 10, target_end_index = 10 }
    local view0 = { left_topline = 1, right_topline = 1, rows = 20 }

    local function by_chunk(list)
      local out = {}
      for _, r in ipairs(list) do
        out[r.chunk] = r
      end
      return out
    end

    local r = by_chunk(curves.ribbons({ change, add, top_add, delete, embedded }, view0))
    assert_eq(r[1].lt, 4, "change left top = start_left_index - topline")
    assert_eq(r[1].lb, 7, "change left bottom is exclusive (end + 1)")
    assert_eq(r[1].rt, 9, "change right top")
    assert_eq(r[1].rb, 10, "change right bottom")
    assert_eq(r[2].lt, 3, "add tapers to the boundary below its origin row")
    assert_eq(r[2].lb, 3, "add insertion side is empty (zero height)")
    assert_eq(r[2].rt .. "," .. r[2].rb, "3,5", "add target extent on the right")
    assert_eq(r[3].lt .. "," .. r[3].lb, "0,0", "top-of-file add tapers to row 0")
    assert_eq(r[4].lt .. "," .. r[4].lb, "8,9", "delete block on the left")
    assert_eq(r[4].rt .. "," .. r[4].rb, "8,8", "delete insertion boundary on the right")
    local n = 0
    for _ in pairs(r) do
      n = n + 1
    end
    assert_eq(n, 4, "embedded adds are absorbed into their change band (no own ribbon)")

    -- Independent scroll: the right pane far down keeps a visible left end and
    -- a true (negative) offscreen right end — never clamped.
    local scrolled = curves.ribbons({ change }, { left_topline = 1, right_topline = 30, rows = 20 })
    assert_eq(#scrolled, 1, "one visible end keeps the ribbon")
    assert_eq(scrolled[1].rt, -20, "offscreen right top keeps its true row")
    assert_eq(scrolled[1].rb, -19, "offscreen right bottom keeps its true row")
    assert_ne(curves.geometry_key(scrolled, 20), curves.geometry_key(curves.ribbons({ change }, view0), 20),
      "independent right scroll changes the image geometry")

    assert_eq(#curves.ribbons({ change }, { left_topline = 50, right_topline = 50, rows = 20 }), 0,
      "both ends above the viewport are culled (IntelliJ visibility rule)")
    assert_eq(#curves.ribbons({ change }, { left_topline = 1, right_topline = 1, rows = 3 }), 0,
      "both ends below the viewport are culled")

    local mirrored = curves.ribbons({ change }, { left_topline = 1, right_topline = 1, rows = 20, mirror = true })
    assert_eq(mirrored[1].lt .. "," .. mirrored[1].lb, "9,10", "mirror puts the pair's right extent on the screen-left edge")
    assert_eq(mirrored[1].rt .. "," .. mirrored[1].rb, "4,7", "mirror puts the pair's left extent on the screen-right edge")

    local ordered = curves.ribbons({ change, add }, { left_topline = 1, right_topline = 1, rows = 20, active_chunk = 1 })
    assert_eq(ordered[#ordered].chunk, 1, "active chunk paints last (on top)")
    assert_eq(ordered[#ordered].active, true, "active flag set on the navigated chunk")
    assert_eq(ordered[1].active, false, "other chunks are inactive")

    -- Real pipeline paths produce ribbons too.
    local left, right = {}, {}
    for i = 1, 20 do
      left[i] = "line " .. i
      right[i] = "line " .. i
    end
    right[5] = "changed five"
    table.insert(right, 10, "inserted")
    local hunks = assert((diff.compute_hunks(to_text(left), to_text(right), config.diff)))
    local v = view.build(left, right, hunks, config)
    local real = curves.ribbons(connector.compute_paths(v.chunks, v.line_meta), view0)
    local kinds = {}
    for _, rb in ipairs(real) do
      kinds[rb.kind] = true
    end
    assert_eq(kinds.change and kinds.add, true, "pipeline paths yield change and add ribbons")
  end

  -- ------------------------------------------------------------------
  -- raster
  -- ------------------------------------------------------------------
  do
    local palette = {
      change = { fill = { 10, 20, 30 }, border = { 200, 210, 220 } },
      add = { fill = { 0, 128, 0 }, border = { 0, 255, 0 } },
      delete = { fill = { 128, 0, 0 }, border = { 255, 0, 0 } },
    }
    local function px(bytes, w, x, y)
      local i = (y * w + x) * 4 + 1
      return bytes:byte(i), bytes:byte(i + 1), bytes:byte(i + 2), bytes:byte(i + 3)
    end
    local spec = { cols = 4, rows = 5, cell_w = 10, cell_h = 20, palette = palette }

    local shape = raster.shape(40)
    assert_eq(shape.S[0] < 0.01, true, "curve starts flat at the left edge")
    assert_eq(shape.S[shape.n - 1] > 0.99, true, "curve ends at the right height")
    assert_eq(math.abs(shape.S[shape.n / 2] - 0.5) < 0.02, true, "symmetric curve crosses midway at the centre")

    local flat = { { kind = "change", chunk = 1, active = false, lt = 1, lb = 3, rt = 1, rb = 3 } }
    local bytes, w, h = raster.render(flat, spec)
    assert_eq(w .. "x" .. h, "40x100", "image is cols*cell_w x rows*cell_h")
    assert_eq(#bytes, w * h * 4, "RGBA byte count")
    local r, g, b, a = px(bytes, w, 20, 40)
    assert_eq(table.concat({ r, g, b, a }, ","), "10,20,30,255", "band interior is opaque fill")
    local _, _, _, a_out = px(bytes, w, 20, 10)
    assert_eq(a_out, 0, "outside the band is transparent")
    local _, _, _, a_edge_above = px(bytes, w, 20, 19)
    local _, _, _, a_edge_top = px(bytes, w, 20, 20)
    assert_eq(a_edge_above .. "," .. a_edge_top, "0,255", "row-aligned band edge is crisp")

    local half = { { kind = "change", chunk = 1, active = false, lt = 20.5 / 20, lb = 3, rt = 20.5 / 20, rb = 3 } }
    local hb = raster.render(half, spec)
    local _, _, _, a_half = px(hb, w, 20, 20)
    assert_eq(a_half > 100 and a_half < 160, true, "half-covered edge pixel is anti-aliased (" .. a_half .. ")")

    local active = { { kind = "change", chunk = 1, active = true, lt = 1, lb = 3, rt = 1, rb = 3 } }
    local ab = raster.render(active, spec)
    local br, bg, bb, ba = px(ab, w, 20, 19)
    assert_eq(br .. "," .. bg .. "," .. bb, "200,210,220", "active chunk strokes its edge with the border color")
    assert_eq(ba > 150, true, "active stroke straddles the band edge")
    local _, _, _, inactive_a = px(bytes, w, 20, 19)
    assert_eq(inactive_a, 0, "inactive chunks have no border stroke")

    -- Empty (insertion) side keeps a minimum thickness so it reads as a line.
    local taper = { { kind = "add", chunk = 2, active = false, lt = 2, lb = 2, rt = 1, rb = 4 } }
    local tb = raster.render(taper, spec)
    -- Insertion line sits where the terminal underline does: ~1px, its
    -- bottom ~1px above the boundary (y = 40 at 20px rows).
    local _, _, _, a_line = px(tb, w, 0, 38)
    local _, _, _, a_below = px(tb, w, 0, 40)
    local _, _, _, a_taper_far = px(tb, w, 0, 30)
    assert_eq(a_line > 0, true, "zero-height side paints the insertion line above the boundary")
    assert_eq(a_below, 0, "insertion line does not straddle into the next row")
    assert_eq(a_taper_far, 0, "taper stays thin at the insertion side")
    local tuned = raster.render(taper, vim.tbl_extend("force", spec, { insertion_line = { thickness = 0.1, offset = 0 } }))
    local _, _, _, a_tuned = px(tuned, w, 0, 39)
    assert_eq(a_tuned, 255, "insertion_line offset/thickness are configurable")

    -- Sloped ribbon: the band centre moves monotonically from left to right
    -- heights (flat near both edges, steepest mid-way).
    local slope = { { kind = "delete", chunk = 3, active = false, lt = 0, lb = 1, rt = 3, rb = 4 } }
    local sb = raster.render(slope, spec)
    local function centre(x)
      local sum, weight = 0, 0
      for y = 0, h - 1 do
        local _, _, _, al = px(sb, w, x, y)
        sum = sum + (y + 0.5) * al
        weight = weight + al
      end
      return sum / weight
    end
    local c0, c1, c2 = centre(1), centre(20), centre(38)
    assert_eq(c0 < c1 and c1 < c2, true, "curve descends monotonically")
    assert_eq(math.abs(c0 - 10) < 2, true, "left end sits at the left extent (" .. c0 .. ")")
    assert_eq(math.abs(c2 - 70) < 2, true, "right end sits at the right extent (" .. c2 .. ")")
    assert_eq(math.abs(c1 - 40) < 2, true, "midpoint halfway between extents (" .. c1 .. ")")

    assert_eq(raster.render(slope, spec), sb, "rasterization is deterministic")
    if raster.has_ffi then
      local table_spec = vim.tbl_extend("force", spec, { use_ffi = false })
      assert_eq(raster.render(slope, table_spec), sb, "ffi and table paths are byte-identical")
      assert_eq(raster.render(active, table_spec), ab, "ffi and table paths agree on strokes")
    end

    -- IntelliJ layout: flat band across the edge columns, curve only over the
    -- divider-wide middle (x0..x0+cw).
    local inset = raster.shape(50, 10, 30)
    assert_eq(inset.S[10 * 4 - 1], 0, "band is flat left of the divider")
    assert_eq(inset.S[40 * 4], 1, "band is flat right of the divider")
    assert_eq(math.abs(inset.S[25 * 4] - 0.5) < 0.02, true, "curve midpoint is centred in the divider")
    local step = { { kind = "change", chunk = 1, active = false, lt = 0, lb = 1, rt = 3, rb = 4 } }
    local ispec = { cols = 5, rows = 5, cell_w = 10, cell_h = 20, palette = palette, curve_x0 = 10, curve_w = 30 }
    local ib, iw = raster.render(step, ispec)
    local _, _, _, a_in = px(ib, iw, 5, 10)
    local _, _, _, a_low = px(ib, iw, 5, 70)
    assert_eq(a_in == 255 and a_low == 0, true, "left edge column carries the left block, unbent")
    local _, _, _, b_in = px(ib, iw, 45, 70)
    assert_eq(b_in, 255, "right edge column carries the right block, unbent")
  end

  -- ------------------------------------------------------------------
  -- detection
  -- ------------------------------------------------------------------
  do
    reset_detect()
    local cells_cfg = { ui = { connector_renderer = "cells" } }
    assert_eq(detect.requested_mode(cells_cfg), "cells", "config mode respected")
    vim.g.diffbandit_connector_renderer = "kitty"
    assert_eq(detect.requested_mode(cells_cfg), "kitty", "vim.g override wins over config")
    vim.g.diffbandit_connector_renderer = nil
    assert_eq(detect.requested_mode({ ui = { connector_renderer = "bogus" } }), "auto", "unknown modes mean auto")

    assert_eq(detect.resolve(cells_cfg), "cells", "cells mode resolves to cells")
    assert_eq(#sent, 0, "cells mode never probes the terminal")

    -- Real headless environment: no TTY UI, so auto falls back without probing.
    assert_eq(detect.resolve({ ui = { connector_renderer = "auto" } }), "cells", "headless auto resolves to cells")
    assert_eq(#sent, 0, "no TUI: nothing written to the terminal")

    local function probe_env()
      reset_detect()
      detect._set_env({ has_ui_send = true, has_tty_ui = true, termguicolors = true, tmux = false })
    end

    probe_env()
    detect._set_env({ has_ui_send = false, has_tty_ui = true, termguicolors = true })
    assert_eq(detect.resolve({ ui = {} }), "cells", "Neovim without nvim_ui_send falls back")
    local _, why = detect.status()
    assert_eq(why:find("nvim_ui_send", 1, true) ~= nil, true, "fallback reason recorded")

    probe_env()
    detect._set_env({ has_ui_send = true, has_tty_ui = true, termguicolors = false })
    assert_eq(detect.resolve({ ui = {} }), "cells", "termguicolors off falls back (image id rides the fg color)")

    -- Probe success: graphics OK (direct + temp file) before the DA1 sentinel.
    probe_env()
    local notified = {}
    detect.on_change(function(status)
      notified[#notified + 1] = status
    end)
    assert_eq(detect.resolve({ ui = {} }), "cells", "auto renders cells while the probe is in flight")
    assert_eq(detect.status(), "probing", "probe started")
    assert_eq(#sent, 1, "one probe write")
    assert_eq(sent[1]:find(protocol.query(detect.QUERY_ID, "d"), 1, true) == 1, true, "direct query first")
    assert_eq(sent[1]:find("a=q,U=1,t=t", 1, true) ~= nil, true, "temp-file query included")
    assert_eq(sent[1]:sub(-#protocol.DA1), protocol.DA1, "DA1 sentinel last")
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. detect.QUERY_ID .. ";OK\27\\" } })
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. (detect.QUERY_ID + 1) .. ";OK\27\\" } })
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[?62;22c" } })
    assert_eq(wait_for(function()
      return detect.status() == "kitty"
    end), true, "graphics OK before DA1 resolves to kitty")
    assert_eq(notified[1], "kitty", "subscribers notified of the flip")
    assert_eq(detect.transmission({ ui = {} }), "file", "temp-file OK selects file transmission")
    assert_eq(detect.transmission({ ui = { kitty = { transmission = "direct" } } }), "direct", "config overrides medium")
    assert_eq(detect.resolve({ ui = {} }), "kitty", "result is cached for later hosts")

    -- A later temp-file failure falls back to direct transmission (and asks
    -- hosts to re-send) instead of downgrading to cells; late errors for
    -- transmissions already in flight are ignored for a short grace window.
    local retransmits = 0
    detect.on_retransmit(function()
      retransmits = retransmits + 1
    end)
    detect.register_id(4300)
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=4300;ENOENT:file gone\27\\" } })
    assert_eq(wait_for(function()
      return retransmits == 1
    end), true, "file error requests a re-send")
    assert_eq(detect.transmission({ ui = {} }), "direct", "file error switches to direct transmission")
    assert_eq(detect.failed(), false, "file error does not downgrade to cells")
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=4300;ENOENT:file gone\27\\" } })
    vim.wait(30)
    assert_eq(detect.failed(), false, "in-flight file errors inside the grace window are ignored")
    vim.wait(550)
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=4300;EINVAL:bad\27\\" } })
    assert_eq(wait_for(function()
      return detect.failed()
    end), true, "a direct-transmission error still downgrades to cells")

    -- Launcher startup: no TUI attached yet. The answer is NOT cached; the
    -- probe runs once a UI attaches and subscribed hosts flip.
    reset_detect()
    detect._set_env({ has_ui_send = true, has_tty_ui = false, termguicolors = true })
    local late = {}
    detect.on_change(function(status)
      late[#late + 1] = status
    end)
    assert_eq(detect.resolve({ ui = {} }), "cells", "no UI yet: render cells for now")
    assert_eq(detect.status(), "unknown", "missing UI is not cached as a verdict")
    assert_eq(#sent, 0, "no probe without a terminal")
    detect._set_env({ has_ui_send = true, has_tty_ui = true, termguicolors = true })
    detect._reprobe_for_test()
    assert_eq(wait_for(function()
      return detect.status() == "probing"
    end), true, "UI attach starts the probe")
    assert_eq(#sent, 1, "probe written once the UI is attached")
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. detect.QUERY_ID .. ";OK\27\\" } })
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[?62;22c" } })
    assert_eq(wait_for(function()
      return late[1] == "kitty"
    end), true, "hosts opened before the UI attached flip to kitty")

    -- A stray DA1 (Neovim's own startup query) ahead of our graphics reply
    -- must not cause a false negative.
    probe_env()
    detect.resolve({ ui = {} })
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[?62;22c" } })
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. detect.QUERY_ID .. ";OK\27\\" } })
    assert_eq(wait_for(function()
      return detect.status() ~= "probing"
    end), true, "probe settles")
    assert_eq(detect.status(), "kitty", "graphics OK within the DA1 grace window still wins")

    -- DA1 first: terminal (or multiplexer) ignored the graphics query.
    probe_env()
    detect.resolve({ ui = {} })
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[?62;22c" } })
    assert_eq(wait_for(function()
      return detect.status() == "cells"
    end), true, "DA1 without a graphics reply resolves to cells")
    assert_eq(detect.transmission({ ui = {} }), "direct", "no file reply keeps direct transmission")

    -- Kitty graphics without Unicode placeholders (Zellij 0.45 answers the
    -- U=1 query with an error before its DA1): cells, with the reason.
    probe_env()
    detect.resolve({ ui = {} })
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. detect.QUERY_ID
      .. ";ENOTSUPPORTED:unicode placeholders are not supported\27\\" } })
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[?62;52c" } })
    assert_eq(wait_for(function()
      return detect.status() == "cells"
    end), true, "placeholder rejection resolves to cells")
    local _, rejected = detect.status()
    assert_eq(rejected:find("ENOTSUPPORTED:unicode placeholders", 1, true) ~= nil, true,
      "the terminal's rejection is the recorded reason")

    -- No reply at all: the timeout resolves to cells.
    probe_env()
    detect.resolve({ ui = { kitty = { probe_timeout_ms = 20 } } })
    assert_eq(wait_for(function()
      return detect.status() == "cells"
    end), true, "silent terminal times out to cells")
    local _, timeout_reason = detect.status()
    assert_eq(timeout_reason, "probe timed out", "timeout reason recorded")

    -- Runtime error for one of our image ids downgrades everything.
    probe_env()
    detect.resolve({ ui = { connector_renderer = "kitty" } })
    detect.register_id(4242)
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=4242;ENOSPC:no space\27\\" } })
    assert_eq(wait_for(function()
      return detect.failed()
    end), true, "error reply for an owned id fails the renderer")
    assert_eq(detect.status(), "cells", "runtime failure resolves to cells")
    reset_detect()
    detect.register_id(4243)
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=777;ENOENT:other app\27\\" } })
    vim.wait(30)
    assert_eq(detect.failed(), false, "errors for images we do not own are ignored")

    assert_eq(detect.cell_size({ ui = { kitty = { cell_px = { 9, 19 } } } }).h, 19, "cell_px override")

    -- Startup race (Ghostty reports 1x1 px until the window settles): the
    -- estimate is never cached, so the real size wins as soon as it appears.
    local measured = nil
    detect._set_measure(function()
      return measured
    end)
    assert_eq(detect.cell_size({}).estimated, true, "no pixel size yet: estimate")
    measured = { w = 17, h = 37 }
    local real = detect.cell_size({})
    assert_eq(real.w .. "x" .. real.h, "17x37", "real size replaces the estimate without a reset")
    measured = { w = 21, h = 45 }
    assert_eq(detect.cell_size({}).w, 17, "a real measurement is cached")
    assert_eq(detect.remeasure({}), true, "font size change is detected on remeasure")
    assert_eq(detect.cell_size({}).w, 21, "remeasure picks up the new size")
    assert_eq(detect.remeasure({}), false, "unchanged size reports no change")
    assert_eq(detect.remeasure({ ui = { kitty = { cell_px = { 9, 19 } } } }), false, "cell_px override never remeasures")
    detect._set_measure(nil)
    reset_detect()
  end

  -- ------------------------------------------------------------------
  -- Image colour space: Ghostty/macOS shows image pixels as Display P3
  -- but converts text colours from sRGB, so the palette is pre-converted.
  -- ------------------------------------------------------------------
  do
    local color = require("diffbandit.kitty.color")
    assert_eq(table.concat(color.srgb_to_display_p3({ 18, 61, 43 }), ","), "30,60,44",
      "sRGB #123d2b in Display P3 (what Ghostty shows for the text colour)")
    assert_eq(table.concat(color.srgb_to_display_p3({ 255, 255, 255 }), ","), "255,255,255", "white is white")
    assert_eq(table.concat(color.srgb_to_display_p3({ 0, 0, 0 }), ","), "0,0,0", "black is black")
    assert_eq(color.image_colorspace({}, { ghostty = true, mac = true, ssh = false }), "display-p3", "Ghostty on macOS")
    assert_eq(color.image_colorspace({}, { ghostty = true, mac = true, ssh = true }), "srgb", "remote: unknown display")
    assert_eq(color.image_colorspace({}, { ghostty = false, mac = true, ssh = false }), "srgb", "other terminals")
    assert_eq(color.image_colorspace({}, { ghostty = true, mac = false, ssh = false }), "srgb", "Ghostty on Linux")
    assert_eq(color.image_colorspace({ ui = { kitty = { image_colorspace = "srgb" } } },
      { ghostty = true, mac = true, ssh = false }), "srgb", "config override")
  end

  -- ------------------------------------------------------------------
  -- IntelliJ-sized divider: 24px beside a ~16.5px line ≈ 1.45 line heights
  -- ------------------------------------------------------------------
  do
    local width_mod = require("diffbandit.connector.width")
    assert_eq(width_mod.kitty_core({}, { w = 10, h = 20 }), 1, "2:1 cells: 29px curve fits sep+1+sep")
    assert_eq(width_mod.kitty_core({}, { w = 8, h = 20 }), 2, "narrow cells: 29px needs four cells")
    assert_eq(width_mod.kitty_core({ ui = { kitty = { divider_width = 3 } } }, { w = 10, h = 20 }), 4,
      "divider_width (line heights) widens the core")
    assert_eq(math.abs(width_mod.kitty_divider_px({}, { w = 10, h = 20 }) - 29) < 1e-9, true, "divider px")
  end

  -- ------------------------------------------------------------------
  -- 2-way session integration (forced kitty, captured terminal writes)
  -- ------------------------------------------------------------------
  local function kitty_config()
    local cfg = vim.deepcopy(config)
    cfg.ui.connector_renderer = "kitty"
    cfg.ui.kitty.cell_px = { 10, 20 }
    cfg.ui.perf = { enabled = true, log = false, budget_warn_ms = 1e9 }
    return cfg
  end

  local function fixture_lines()
    local left, right = {}, {}
    for i = 1, 300 do
      left[i] = "line " .. i
      right[i] = "line " .. i
    end
    right[5] = "changed five"
    table.insert(right, 20, "added a")
    table.insert(right, 21, "added b")
    table.remove(left, 60)
    right[150] = "changed 150"
    return left, right
  end

  local PLACEHOLDER = nr(0x10EEEE)
  local WEDGES = { "◢", "◣", "◤", "◥", "│" }

  local function path_marks(buf, ns)
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  end

  local function mark_text(mark)
    local vt = (mark[4] or {}).virt_text
    return vt and vt[1] and vt[1][1] or ""
  end

  local function has_glyph(marks)
    for _, m in ipairs(marks) do
      local t = mark_text(m)
      for _, g in ipairs(WEDGES) do
        if t:find(g, 1, true) then
          return true
        end
      end
    end
    return false
  end

  local function start_session(cfg)
    local left, right = fixture_lines()
    return assert((Session.start({
      left = source_mod.from_lines(left, nil, "left"),
      right = source_mod.from_lines(right, nil, "right"),
    }, cfg, {})))
  end

  do
    reset_detect()
    local saved_winborder = vim.o.winborder
    vim.o.winborder = "rounded" -- user configs often set a global float border
    local session = start_session(kitty_config())
    session:render()
    local st = session.kitty_state
    local fb = vim.api.nvim_win_get_config(st.float_win).border
    assert_eq(fb == nil or fb == "none" or fb == "", true, "canvas float ignores a global winborder")
    vim.o.winborder = saved_winborder
    assert_eq(session.connector_renderer, "kitty", "forced kitty mode")
    assert_eq(st ~= nil, true, "session owns a canvas state")
    assert_eq(count_matching(",i=" .. st.id .. ","), st.transmits, "every transmit targets our image id")
    assert_eq(count_matching("\27_Ga=T,U=1,f=32,"), st.transmits, "every transmit is a virtual (placeholder) placement")
    assert_eq(st.transmits >= 1, true, "image transmitted")
    if require("diffbandit.kitty.zlib").available() then
      assert_eq(count_matching(",o=z,"), st.transmits, "direct transmissions are zlib-compressed")
    end
    local hl = vim.api.nvim_get_hl(0, { name = st.hl, link = false })
    assert_eq(hl.fg, st.id, "placeholder highlight fg encodes the image id")

    assert_eq(session.connector_core_width, 1, "kitty core is IntelliJ divider-sized (10x20 cells)")
    if session.center_header_win and vim.api.nvim_win_is_valid(session.center_header_win) then
      local lines = require("diffbandit.util.status").build(session)
      assert_eq(vim.api.nvim_win_get_width(session.center_header_win) >= vim.fn.strdisplaywidth(lines.center_compact) + 2,
        true, "center header keeps room for the compact status")
    end
    local layout = st.last_layout
    -- Placeholders live in a static, non-focusable canvas float laid over
    -- wedge column .. wedge column (both window separators covered).
    local fwin = st.float_win
    assert_eq(fwin ~= nil and vim.api.nvim_win_is_valid(fwin), true, "canvas float opened")
    local fcfg = vim.api.nvim_win_get_config(fwin)
    assert_eq(fcfg.relative ~= "", true, "canvas is a floating window")
    assert_eq(fcfg.focusable, false, "canvas float is not focusable")
    local lpos = vim.api.nvim_win_get_position(session.left_num_win)
    local rpos = vim.api.nvim_win_get_position(session.right_num_win)
    local cpos = vim.api.nvim_win_get_position(session.connector_win)
    local fpos = vim.api.nvim_win_get_position(fwin)
    assert_eq(fpos[1], cpos[1], "canvas float starts on the connector's first screen row")
    assert_eq(fpos[2], lpos[2] + session:left_triangle_col(), "canvas float starts at the left wedge column")
    assert_eq(fpos[2] + vim.api.nvim_win_get_width(fwin) - 1, rpos[2] + session:right_triangle_col(),
      "canvas float ends at the right wedge column")
    assert_eq(layout.core_start, cpos[2] - fpos[2], "image columns include the separator before the core")
    assert_eq(vim.api.nvim_win_get_height(fwin), vim.api.nvim_win_get_height(session.connector_win),
      "canvas float covers every connector row")
    assert_eq(vim.wo[fwin].winhighlight:find("NormalFloat:" .. st.hl, 1, true) ~= nil, true,
      "canvas cells carry the image highlight")
    local canvas_lines = vim.api.nvim_buf_get_lines(st.float_buf, 0, -1, false)
    assert_eq(#canvas_lines, layout.rows, "one placeholder line per screen row")
    assert_eq(canvas_lines[1], protocol.placeholder_run(0, 0, layout.cols), "row 0 addresses image row 0, every column")
    assert_eq(canvas_lines[layout.rows], protocol.placeholder_run(layout.rows - 1, 0, layout.cols),
      "last row addresses the last image row")
    assert_eq(vim.fn.strwidth(canvas_lines[1]), layout.cols, "each placeholder is one display cell")

    -- Document-edge bridges: one-column floats over the separators between
    -- each number pane and its document keep the glyph on context rows and
    -- carry the band colour on band rows, so bands run through unbroken.
    local edge_ns = vim.api.nvim_create_namespace("DiffBanditKittyEdges")
    local function edge_rows(edge)
      local rows = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(edge.buf, edge_ns, 0, -1, { details = true })) do
        rows[m[2]] = m[4].virt_text[1][2]
      end
      return rows
    end
    local le, re = st.edges.left, st.edges.right
    local le_win, re_win = le.win, re.win
    assert_eq(le.win ~= nil and re.win ~= nil and vim.api.nvim_win_is_valid(le.win) and vim.api.nvim_win_is_valid(re.win),
      true, "both document-edge bridges are open")
    assert_eq(vim.api.nvim_win_get_position(le.win)[2], lpos[2] - 1, "left bridge covers the left document separator")
    assert_eq(vim.api.nvim_win_get_position(re.win)[2], rpos[2] + vim.api.nvim_win_get_width(session.right_num_win),
      "right bridge covers the right document separator")
    assert_eq(vim.api.nvim_win_get_config(le.win).focusable, false, "bridges are not focusable")
    assert_eq(vim.api.nvim_buf_get_lines(le.buf, 0, 1, false)[1], "│", "context rows keep the separator glyph")
    local lrows, rrows = edge_rows(le), edge_rows(re)
    local saw_band = false
    for _, rb in ipairs(st.last_ribbons) do
      if rb.lb > rb.lt and rb.lt >= 0 and rb.lt < layout.rows then
        saw_band = true
        assert_eq(lrows[math.floor(rb.lt)], "DiffBanditConnector" .. rb.kind:sub(1, 1):upper() .. rb.kind:sub(2),
          "left bridge carries the band colour on the band's first row")
      end
      if rb.rb > rb.rt and rb.rt >= 0 and rb.rt < layout.rows then
        assert_eq(rrows[math.floor(rb.rt)] ~= nil, true, "right bridge carries the band on its first row")
      end
    end
    assert_eq(saw_band, true, "fixture has a visible left band")
    local banded = 0
    for _ in pairs(lrows) do
      banded = banded + 1
    end
    assert_eq(banded < layout.rows, true, "context rows are not bridged")

    local conn_marks = path_marks(session.connector_buf, session.path_ns)
    local lnum = path_marks(session.left_num_buf, session.path_ns)
    local rnum = path_marks(session.right_num_buf, session.path_ns)
    assert_eq(has_glyph(conn_marks), false, "no rail glyphs in kitty mode")
    assert_eq(has_glyph(lnum) or has_glyph(rnum), false, "wedge glyphs are replaced by the curve")

    for _, m in ipairs(path_marks(session.connector_buf, session.ns)) do
      assert_eq((m[4] or {}).hl_group == "DiffBanditConnectorChange", false, "image paints the core band, not hl_eol marks")
    end

    local perf = session._last_render_perf or {}
    assert_eq(perf.kitty_curves ~= nil and perf.kitty_raster ~= nil and perf.kitty_transmit ~= nil, true,
      "kitty stages reported in perf timings")

    -- The rail solver never runs in kitty mode.
    local calls = 0
    local original = connector.plan_routes
    connector.plan_routes = function(...)
      calls = calls + 1
      return original(...)
    end
    session.route_plan_cache = nil
    session:render()
    connector.plan_routes = original
    assert_eq(calls, 0, "plan_routes is skipped for image connectors")

    -- Identical repaint: placeholders re-placed, image not re-sent.
    local before = st.transmits
    session:render()
    assert_eq(st.transmits, before, "unchanged geometry does not retransmit")

    -- Scroll ONLY the right pane: the curves re-project and the image updates.
    local left_top = nvim_util.get_win_view_topline(session.left_win)
    local key_before = st.last_key
    nvim_util.set_win_view_topline(session.right_win, 4)
    session.last_viewport_render_key = nil
    session:rerender_for_viewport()
    assert_eq(nvim_util.get_win_view_topline(session.left_win), left_top, "left pane did not move")
    assert_eq(st.transmits, before + 1, "independent right scroll retransmits once")
    assert_ne(st.last_key, key_before, "image geometry follows the right pane")
    local right_add_rt
    for _, rb in ipairs(st.last_ribbons) do
      if rb.kind == "add" then
        right_add_rt = rb.rt
      end
    end
    assert_eq(right_add_rt, 20 - 4, "add ribbon right edge tracks the right topline")
    assert_eq(edge_rows(st.edges.right)[16] ~= nil, true, "right bridge follows an independent right scroll")

    -- Dedupe through the viewport path too.
    session:rerender_for_viewport()
    assert_eq(st.transmits, before + 1, "identical viewport event is a no-op")

    -- Scroll the left pane far: the canvas text never changes (no
    -- placeholder churn); only the image content follows the panes.
    local tick = vim.api.nvim_buf_get_changedtick(st.float_buf)
    local fwin_before = st.float_win
    nvim_util.set_win_view_topline(session.left_win, 100)
    nvim_util.set_win_view_topline(session.left_num_win, 100)
    nvim_util.set_win_view_topline(session.connector_win, 100)
    session.last_viewport_render_key = nil
    session:rerender_for_viewport()
    assert_eq(vim.api.nvim_buf_get_changedtick(st.float_buf), tick, "scrolling never rewrites the canvas")
    assert_eq(st.float_win, fwin_before, "scrolling keeps the same canvas float")

    -- Resize: the float follows the connector height and rewrites its rows.
    vim.o.lines = vim.o.lines - 4
    session:render()
    assert_eq(vim.api.nvim_win_get_height(st.float_win), vim.api.nvim_win_get_height(session.connector_win),
      "canvas float follows a terminal resize")
    assert_eq(#vim.api.nvim_buf_get_lines(st.float_buf, 0, -1, false), st.last_layout.rows,
      "resize rewrites the canvas rows")
    vim.o.lines = vim.o.lines + 4

    -- A layout shift with no diffbandit render (split resize) moves the float.
    vim.api.nvim_win_set_width(session.left_win, vim.api.nvim_win_get_width(session.left_win) - 6)
    vim.cmd("redraw")
    assert_eq(wait_for(function()
      local want = vim.api.nvim_win_get_position(session.left_num_win)[2] + session:left_triangle_col()
      return vim.api.nvim_win_get_position(st.float_win)[2] == want
    end), true, "canvas float follows a split resize")

    -- A paint while another tab is current never opens the float there.
    local diff_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_win_close(st.float_win, true)
    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    session:render()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(other_tab)) do
      assert_eq(vim.api.nvim_win_get_config(w).relative, "", "no canvas float leaks into another tab")
    end
    vim.cmd("tabclose")
    vim.api.nvim_set_current_tabpage(diff_tab)
    assert_eq(wait_for(function()
      return st.float_win ~= nil and vim.api.nvim_win_is_valid(st.float_win)
        and vim.api.nvim_win_get_tabpage(st.float_win) == diff_tab
    end), true, "returning to the diff tab re-opens its canvas float")

    -- Theme change: palette re-read and image re-sent.
    local themed = st.transmits
    vim.cmd("doautocmd ColorScheme")
    assert_eq(wait_for(function()
      return st.transmits > themed
    end), true, "ColorScheme refresh retransmits the image")

    -- Runtime terminal error downgrades the live session to cells glyphs.
    detect.fail("test: terminal rejected image")
    assert_eq(wait_for(function()
      return session.connector_renderer == "cells"
    end), true, "runtime failure flips the session to cells")
    assert_eq(count_matching(protocol.delete(st.id)) >= 1, true, "downgrade deletes the terminal image")
    assert_eq(session.kitty_state, nil, "canvas state released")
    assert_eq(vim.api.nvim_win_is_valid(fwin), false, "downgrade closes the canvas float")
    assert_eq(vim.api.nvim_win_is_valid(le_win) or vim.api.nvim_win_is_valid(re_win), false,
      "downgrade closes the document-edge bridges")
    local cell_marks = path_marks(session.connector_buf, session.path_ns)
    local saw_placeholder = false
    for _, m in ipairs(cell_marks) do
      if mark_text(m):find(PLACEHOLDER, 1, true) then
        saw_placeholder = true
      end
    end
    assert_eq(saw_placeholder, false, "cells repaint removed every placeholder")
    session:close()
    reset_detect()
  end

  do
    -- Issue #14: under a winbar the canvas starts at the connector's first
    -- TEXT row (below the bar) and is as tall as the text area, not one row
    -- above the code it connects.
    reset_detect()
    local saved = vim.go.winbar
    vim.go.winbar = "%f"
    local session = start_session(kitty_config())
    session:render()
    local st = session.kitty_state
    local cwin = session.connector_win
    assert_eq(require("diffbandit.util.winbar").rows(cwin), 1, "connector shows the (blank) bar row")
    local text_row = vim.api.nvim_win_get_position(cwin)[1] + 1
    assert_eq(vim.api.nvim_win_get_position(st.float_win)[1], text_row, "canvas starts below the winbar")
    assert_eq(vim.api.nvim_win_get_height(st.float_win), vim.fn.winheight(cwin), "canvas spans the text rows only")
    session:close()
    vim.go.winbar = saved
    reset_detect()
  end

  do
    -- Insertion points: scroll the add (right 20-21, left origin 19) on screen.
    reset_detect()
    local session = start_session(kitty_config())
    session:render()
    for _, w in ipairs({ session.left_win, session.left_num_win, session.connector_win, session.right_win, session.right_num_win }) do
      nvim_util.set_win_view_topline(w, 12)
    end
    session.last_viewport_render_key = nil
    session:rerender_for_viewport()
    local st = session.kitty_state
    local layout = st.last_layout
    local edge_ns = vim.api.nvim_create_namespace("DiffBanditKittyEdges")
    local function edge_rows(edge)
      local rows = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(edge.buf, edge_ns, 0, -1, { details = true })) do
        rows[m[2]] = m[4].virt_text[1][2]
      end
      return rows
    end
    -- Insertion side (empty range): the origin row's underline runs through
    -- the bridge instead of stopping at the separator.
    local saw_underline = false
    for _, rb in ipairs(st.last_ribbons) do
      if rb.kind == "add" and rb.lb == rb.lt and rb.lt >= 1 and rb.lt <= layout.rows then
        saw_underline = true
        local hl = edge_rows(st.edges.left)[rb.lt - 1]
        assert_eq(hl, "DiffBanditKittyEdgeUnderlineAdd", "left bridge underlines the add origin row")
        local def = vim.api.nvim_get_hl(0, { name = hl, link = false })
        assert_eq(def.underline == true and def.sp == vim.api.nvim_get_hl(0, { name = "DiffBanditConnectorAdd" }).bg, true,
          "bridge underline uses the add colour")
      end
    end
    assert_eq(saw_underline, true, "fixture has a visible add insertion point: " .. vim.inspect(st.last_ribbons))
    session:close()
    reset_detect()
  end

  do
    -- Font size change (VimResized with a new measured cell): the core is
    -- re-sized to the IntelliJ divider width and the image re-sent.
    reset_detect()
    local cell = { w = 10, h = 20 }
    detect._set_measure(function()
      return cell
    end)
    local cfg = kitty_config()
    cfg.ui.kitty.cell_px = nil
    local session = start_session(cfg)
    session:render()
    assert_eq(session.connector_core_width, 1, "10x20 cells: one-cell core")
    local before = session.kitty_state.transmits
    cell = { w = 8, h = 24 }
    vim.cmd("doautocmd VimResized")
    assert_eq(wait_for(function()
      return session.connector_core_width == 3
    end), true, "narrower, taller cells widen the core (1.45*24/8 -> 5 cells)")
    assert_eq(wait_for(function()
      return session.kitty_state.transmits > before
    end), true, "new cell size re-rasters the image")
    session:close()
    detect._set_measure(nil)
    reset_detect()
  end

  do
    -- Close deletes the image.
    reset_detect()
    local session = start_session(kitty_config())
    local id = session.kitty_state.id
    local fwin = session.kitty_state.float_win
    session:close()
    assert_eq(sent[#sent], protocol.delete(id), "closing the session deletes its image")
    assert_eq(fwin ~= nil and vim.api.nvim_win_is_valid(fwin), false, "closing the session closes the canvas float")
    reset_detect()
  end

  do
    -- Cells fallback: default auto in a headless (no TUI) Neovim is today's
    -- renderer, untouched — glyphs present, nothing written to a terminal.
    reset_detect()
    local cfg = vim.deepcopy(config)
    local session = start_session(cfg)
    session:render()
    assert_eq(session.connector_renderer, "cells", "headless auto falls back to cells")
    assert_eq(session.kitty_state, nil, "no canvas in cells mode")
    assert_eq(#sent, 0, "cells mode writes nothing to the terminal")
    local route_marks = 0
    local placeholders = 0
    for _, buf in ipairs({ session.connector_buf, session.left_num_buf, session.right_num_buf }) do
      for _, m in ipairs(path_marks(buf, session.path_ns)) do
        route_marks = route_marks + 1
        if mark_text(m):find(PLACEHOLDER, 1, true) then
          placeholders = placeholders + 1
        end
      end
    end
    assert_eq(route_marks > 0, true, "cells mode still paints its route cells")
    assert_eq(placeholders, 0, "cells mode paints no image placeholders")
    session:close()
    reset_detect()
  end

  -- ------------------------------------------------------------------
  -- merge: one image per pair, mirrored RemoteResult
  -- ------------------------------------------------------------------
  do
    reset_detect()
    local m = assert((merge_mod.start({
      root = vim.fn.getcwd(),
      path = "kitty_merge.txt",
      base_lines = { "a", "b", "c", "d" },
      local_lines = { "a", "L", "c", "d" },
      remote_lines = { "a", "b", "c", "R1", "R2", "R3" },
      result_lines = { "a", "b", "c", "d" },
      conflicts = {},
    }, kitty_config(), {})))
    assert_eq(m.connector_renderer, "kitty", "merge resolves kitty")
    assert_eq(m.connector_width, 1, "merge connectors are IntelliJ divider-sized")
    local lr = m.kitty_states.LocalResult
    local rr = m.kitty_states.RemoteResult
    assert_eq(lr ~= nil and rr ~= nil, true, "each pair owns a canvas")
    assert_ne(lr.id, rr.id, "pairs use distinct image ids")
    assert_eq(lr.float_win ~= nil and rr.float_win ~= nil and lr.float_win ~= rr.float_win, true,
      "each pair has its own canvas float")
    assert_eq(lr.transmits >= 1 and rr.transmits >= 1, true, "both connectors transmitted")
    assert_eq(m.local_result_session.kitty_state, lr, "pair renderer reuses the host slot")

    -- RemoteResult is mirrored (remote pane on the screen-right). Its extra
    -- remote rows are a pair "delete": the block must sit on the screen-right
    -- edge and the insertion taper on the screen-left (result) edge.
    local delete_ribbon
    for _, rb in ipairs(rr.last_ribbons) do
      if rb.kind == "delete" then
        delete_ribbon = rb
      end
    end
    assert_eq(delete_ribbon ~= nil, true, "remote-only rows produce a ribbon")
    assert_eq(delete_ribbon.lb - delete_ribbon.lt, 0, "mirrored pair: insertion taper on the screen-left edge")
    assert_eq(delete_ribbon.rb - delete_ribbon.rt, 2, "mirrored pair: remote block on the screen-right edge")
    local lr_ribbon = lr.last_ribbons[1]
    assert_eq(lr_ribbon.kind, "change", "unmirrored local pair keeps its change ribbon")

    local before = lr.transmits
    m:render({ force_pair_rebuild = true })
    assert_eq(m.kitty_states.LocalResult, lr, "pair rebuild keeps the image slot")
    assert_eq(lr.transmits, before, "rebuild with unchanged geometry does not retransmit")

    -- Hiding a pane closes its pair's canvas float; showing it re-opens one.
    local lr_float = lr.float_win
    m:hide_pane("local")
    assert_eq(wait_for(function()
      return not vim.api.nvim_win_is_valid(lr_float)
    end), true, "hiding the local pane closes its canvas float")
    assert_eq(rr.float_win ~= nil and vim.api.nvim_win_is_valid(rr.float_win), true, "remote pair canvas stays")
    m:show_pane("local")
    assert_eq(lr.float_win ~= nil and vim.api.nvim_win_is_valid(lr.float_win), true,
      "showing the local pane re-opens its canvas float")

    m:close()
    assert_eq(count_matching(protocol.delete(lr.id)), 1, "merge close deletes the local pair image")
    assert_eq(count_matching(protocol.delete(rr.id)), 1, "merge close deletes the remote pair image")
    reset_detect()
  end

  detect._set_sink(nil)
  vim.env.TMUX = saved_tmux_env
  kitty_canvas = nil
end
