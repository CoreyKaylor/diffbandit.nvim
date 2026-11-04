-- Kitty graphics under tmux: DCS passthrough escaping, out-of-band
-- detection through `tmux display-message` (tmux swallows the outer
-- terminal's replies), renderer selection, bounded timeouts and fallbacks,
-- wrapped image I/O, per-view cleanup, and client / visibility tracking.
do
  local protocol = require("diffbandit.kitty.protocol")
  local detect = require("diffbandit.kitty.detect")
  local tmux = require("diffbandit.kitty.tmux")
  local kitty_canvas = require("diffbandit.kitty.canvas")

  local saved_tmux_env = vim.env.TMUX
  vim.env.TMUX = nil

  local function wait_for(pred, ms)
    return vim.wait(ms or 1000, pred, 5)
  end

  local sent = {}
  local queries = 0 -- display-message calls
  local reply = nil -- function() -> code, stdout | nil (never answers)
  local tmux_cmds = {} -- other tmux commands (show-options / set-option)
  local pane_local = "" -- fake pane-local allow-passthrough
  local set_code = 0 -- exit code for set-option
  local hold_set = false -- apply set-option but never report completion
  local delay_set_ms = nil -- apply and complete set-option only after this
  local delay_show_ms = nil -- answer show-options only after this

  local FIELD_ORDER = {
    "version", "passthrough", "termname", "termtype", "features", "pid",
    "cw", "ch", "attached", "window_active", "zoomed", "pane_active", "pane_tty", "last_attached",
  }
  local answer_defaults = {}
  local function info_line(over)
    local v = vim.tbl_extend("force", {
      version = "3.8", passthrough = "on", termname = "xterm-ghostty", termtype = "ghostty 1.4.0",
      features = "256,RGB,sync,focus", pid = "842", cw = "16", ch = "34",
      attached = "1", window_active = "1", zoomed = "0", pane_active = "1", pane_tty = "", last_attached = "100",
    }, answer_defaults, over or {})
    local parts = {}
    for i, k in ipairs(FIELD_ORDER) do
      parts[i] = v[k]
    end
    return table.concat(parts, "\t") .. "\n"
  end

  local function answer(over)
    reply = function()
      return 0, info_line(over)
    end
  end

  local TMUX_ENV = { has_ui_send = true, has_tty_ui = true, termguicolors = true, tmux = true }

  local function reset_tmux(env)
    detect._reset()
    detect._set_env(env or TMUX_ENV)
    sent = {}
    queries = 0
    answer_defaults = {}
    answer()
    detect._set_sink(function(data)
      sent[#sent + 1] = data
    end)
    tmux_cmds = {}
    pane_local = ""
    set_code = 0
    hold_set = false
    delay_set_ms = nil
    delay_show_ms = nil
    tmux._set_runner(function(args, on_exit)
      assert_eq(args[1], "tmux", "only tmux is run, never a terminal query")
      if args[2] ~= "display-message" then
        local line = table.concat(args, " ")
        tmux_cmds[#tmux_cmds + 1] = line
        local code, out = 0, ""
        if args[2] == "show-options" and delay_show_ms then
          vim.defer_fn(function()
            on_exit(0, pane_local .. "\n")
          end, delay_show_ms)
          return
        elseif args[2] == "show-options" then
          out = pane_local .. "\n"
        elseif args[2] == "set-option" and delay_set_ms and line:find("allow%-passthrough all$") then
          vim.defer_fn(function()
            pane_local = "all"
            answer_defaults.passthrough = "all"
            on_exit(set_code, "")
          end, delay_set_ms)
          return
        elseif args[2] == "set-option" then
          code = set_code
          -- 124 = vim.system timeout: the change may have been applied.
          if (code == 0 or code == 124) and line:find("allow%-passthrough all$") then
            answer_defaults.passthrough = "all"
            pane_local = "all"
          elseif code == 0 and line:find(" %-u ") then
            pane_local = ""
          end
          if hold_set and line:find("allow%-passthrough all$") then
            return -- applied by tmux, completion not yet processed
          end
        end
        vim.schedule(function()
          on_exit(code, out)
        end)
        return
      end
      queries = queries + 1
      local r = reply
      if not r then
        return -- never answers: exercises the timeout
      end
      local code, out = r()
      vim.schedule(function()
        on_exit(code, out)
      end)
    end)
  end

  -- Strip passthrough wrappers; returns the inner commands, or nil when any
  -- byte sits outside a well-formed wrapper.
  local function unwrap(wire)
    local out = {}
    local pos = 1
    while pos <= #wire do
      if wire:sub(pos, pos + 6) ~= "\27Ptmux;" then
        return nil
      end
      local i = pos + 7
      local inner = {}
      while true do
        local c = wire:sub(i, i)
        if c == "" then
          return nil
        end
        if c == "\27" then
          local n = wire:sub(i + 1, i + 1)
          if n == "\27" then
            inner[#inner + 1] = "\27"
            i = i + 2
          elseif n == "\\" then
            i = i + 2
            break
          else
            return nil -- a lone ESC would end tmux's DCS early
          end
        else
          inner[#inner + 1] = c
          i = i + 1
        end
      end
      out[#out + 1] = table.concat(inner)
      pos = i
    end
    return out
  end

  -- ------------------------------------------------------------------
  -- passthrough escaping
  -- ------------------------------------------------------------------
  do
    local del = protocol.delete(5)
    assert_eq(tmux.wrap(del), "\27Ptmux;\27\27_Ga=d,d=I,i=5,q=2\27\27\\\27\\",
      "wrap doubles every ESC (including the inner ST) and terminates the DCS")
    assert_eq(tmux.wrap("plain"), "\27Ptmux;plain\27\\", "payload without ESC is untouched")
    local chunks = protocol.transmit({ id = 7, width = 2, height = 1, cols = 1, rows = 1, data = "\1\2\3\4\5\6\7\8", chunk_size = 4 })
    local wire = tmux.wrap_all(chunks)
    local inner = unwrap(wire)
    assert_eq(inner ~= nil, true, "wrapped stream is well formed")
    assert_eq(#inner, #chunks, "each chunk gets its own passthrough wrapper")
    for i, c in ipairs(chunks) do
      assert_eq(inner[i], c, "chunk " .. i .. " round-trips through the wrapper")
    end
    assert_eq(unwrap(tmux.wrap("\27_Gx\27\\") .. "\27_G"), nil, "unwrap rejects bytes outside a wrapper")
  end

  -- ------------------------------------------------------------------
  -- tmux info parsing and evaluation
  -- ------------------------------------------------------------------
  do
    assert_eq(table.concat(tmux.parse_version("3.3a"), "."), "3.3", "letter suffix")
    assert_eq(table.concat(tmux.parse_version("next-3.6"), "."), "3.6", "next- prefix")
    assert_eq(tmux.parse_version("master"), nil, "unparseable version")

    local info = tmux.parse(info_line())
    assert_eq(info.passthrough, "on", "passthrough value parsed")
    assert_eq(info.features.RGB, true, "features parsed")
    assert_eq(info.cell.w .. "x" .. info.cell.h, "16x34", "client cell size parsed")
    assert_eq(info.visible, true, "active pane of the active window is visible")
    assert_eq(tmux.parse(info_line({ window_active = "0" })).visible, false, "other window hidden")
    assert_eq(tmux.parse(info_line({ zoomed = "1", pane_active = "0" })).visible, false, "pane hidden behind a zoom")
    assert_eq(tmux.parse(info_line({ zoomed = "1", pane_active = "1" })).visible, true, "zoomed pane itself visible")
    assert_eq(tmux.parse(info_line({ attached = "0" })).visible, false, "detached session hidden")
    assert_eq(tmux.parse(info_line({ cw = "", ch = "" })).cell, nil, "old tmux: no cell size")
    assert_eq(tmux.parse("3.8\ton\n"), nil, "short reply rejected")

    local function verdict(over, cfg)
      local ok, why = tmux.evaluate(tmux.parse(info_line(over)), cfg)
      return ok, why or ""
    end
    assert_eq((verdict()), true, "Ghostty + passthrough + RGB is supported")
    assert_eq((verdict({ termtype = "", termname = "xterm-kitty" })), true, "kitty by TERM name")
    local ok, why = verdict({ passthrough = "off" })
    assert_eq(ok, false, "passthrough off is unsupported")
    assert_eq(why:find("allow-passthrough", 1, true) ~= nil, true, "reason names the option")
    assert_eq((verdict({ passthrough = "all" })), true, "passthrough all is supported")
    ok, why = verdict({ version = "3.2a", passthrough = "" })
    assert_eq(ok, false, "tmux < 3.3 is unsupported")
    assert_eq(why:find("too old", 1, true) ~= nil, true, "reason names the version")
    ok, why = verdict({ termtype = "iTerm2 3.5", termname = "xterm-256color" })
    assert_eq(ok, false, "unknown client terminal is unsupported")
    assert_eq((verdict({ termtype = "Rex 1.0", termname = "xterm-256color" },
      { ui = { kitty = { tmux_terminals = { "rex" } } } })), true, "ui.kitty.tmux_terminals extends trust")
    ok, why = verdict({ features = "256,sync" })
    assert_eq(ok, false, "client without RGB is unsupported (id rides the fg colour)")
    assert_eq(why:find("RGB", 1, true) ~= nil, true, "reason names the RGB feature")
    assert_eq((verdict({ attached = "0", termtype = "", termname = "" })), false, "no client attached")
    assert_eq((tmux.evaluate(nil)), false, "failed query is unsupported")
  end

  -- ------------------------------------------------------------------
  -- renderer selection and detection fallbacks
  -- ------------------------------------------------------------------
  do
    -- auto + supported client: detection completes through tmux, no bytes
    -- are written to the terminal for it.
    reset_tmux()
    local flips = {}
    detect.on_change(function(s)
      flips[#flips + 1] = s
    end)
    assert_eq(detect.passthrough(), "tmux", "$TMUX selects the tmux transport")
    assert_eq(detect.resolve({ ui = {} }), "cells", "cells while the tmux query runs")
    assert_eq(detect.status(), "probing", "tmux probe in flight")
    assert_eq(wait_for(function()
      return detect.status() == "kitty"
    end), true, "auto detects graphics through tmux")
    assert_eq(flips[1], "kitty", "hosts are notified")
    assert_eq(#sent, 0, "no in-band probe inside tmux (its reply would never arrive)")
    assert_eq(queries, 1, "one tmux query")
    assert_eq(detect.transmission({ ui = {} }), "direct", "tmux always transmits directly by default")
    assert_eq(detect.outer_terminal(), "ghostty 1.4.0", "outer terminal known for colour space")
    assert_eq(require("diffbandit.kitty.color").image_colorspace({}) == "display-p3", vim.fn.has("mac") == 1
      and (vim.env.SSH_CONNECTION or "") == "", "Ghostty behind tmux keeps the P3 conversion")

    -- Disabled passthrough falls back to cells.
    reset_tmux()
    answer({ passthrough = "off" })
    detect.resolve({ ui = {} })
    assert_eq(wait_for(function()
      return detect.status() == "cells"
    end), true, "passthrough off resolves to cells")
    local _, why = detect.status()
    assert_eq(why:find("allow-passthrough", 1, true) ~= nil, true, "reason recorded")
    assert_eq(#sent, 0, "nothing written when unsupported")

    -- tmux never answers: bounded by the timeout.
    reset_tmux()
    reply = nil
    local t0 = (vim.uv or vim.loop).now()
    detect.resolve({ ui = { kitty = { probe_timeout_ms = 20 } } })
    assert_eq(wait_for(function()
      return detect.status() == "cells"
    end, 2000), true, "silent tmux times out to cells")
    assert_eq((vim.uv or vim.loop).now() - t0 < 1500, true, "timeout is bounded (max(probe_timeout_ms, 500))")
    _, why = detect.status()
    assert_eq(why, "tmux query timed out", "timeout reason")

    -- tmux command fails.
    reset_tmux()
    reply = function()
      return 1, ""
    end
    detect.resolve({ ui = {} })
    assert_eq(wait_for(function()
      return detect.status() == "cells"
    end), true, "failing tmux command resolves to cells")

    -- "cells" never touches tmux or the terminal.
    reset_tmux()
    assert_eq(detect.resolve({ ui = { connector_renderer = "cells" } }), "cells", "cells mode")
    vim.wait(20)
    assert_eq(queries + #sent, 0, "cells mode neither queries tmux nor writes")

    -- "kitty" forces images even when tmux says no, still via tmux.
    reset_tmux()
    answer({ passthrough = "off" })
    assert_eq(detect.resolve({ ui = { connector_renderer = "kitty" } }), "kitty", "forced kitty inside tmux")
    assert_eq(detect.passthrough(), "tmux", "forced kitty keeps the tmux transport")
    detect.send(protocol.delete(9))
    assert_eq(sent[#sent], tmux.wrap(protocol.delete(9)), "forced sends are wrapped")

    -- Transport overrides.
    reset_tmux()
    detect.resolve({ ui = { connector_renderer = "kitty", kitty = { passthrough = "none" } } })
    assert_eq(detect.passthrough(), "none", "passthrough = none disables wrapping")
    detect.send(protocol.delete(9))
    assert_eq(sent[#sent], protocol.delete(9), "unwrapped with passthrough = none")
    reset_tmux({ has_ui_send = true, has_tty_ui = true, termguicolors = true, tmux = false })
    detect.resolve({ ui = { connector_renderer = "kitty", kitty = { passthrough = "tmux" } } })
    assert_eq(detect.passthrough(), "tmux", "passthrough = tmux forces wrapping")

    -- Outside tmux the in-band probe and raw bytes are unchanged.
    reset_tmux({ has_ui_send = true, has_tty_ui = true, termguicolors = true, tmux = false })
    detect.resolve({ ui = {} })
    assert_eq(queries, 0, "outside tmux nothing asks tmux")
    assert_eq(sent[1]:find(protocol.query(detect.QUERY_ID, "d"), 1, true), 1, "direct Ghostty keeps the raw in-band probe")
    detect._reset()

    -- Cell size: tmux client cell size when the pane reports no pixels.
    reset_tmux()
    detect._set_measure(function()
      return nil
    end)
    detect.resolve({ ui = {} })
    wait_for(function()
      return detect.status() == "kitty"
    end)
    local cell = detect.cell_size({})
    assert_eq(cell.w .. "x" .. cell.h, "16x34", "tmux client cell size used when the tty has none")
    assert_eq(cell.estimated, nil, "tmux size counts as a measurement")
    detect._set_measure(function()
      return { w = 18, h = 36 }
    end)
    assert_eq(detect.cell_size({}).w, 18, "a real tty measurement wins")
    detect._set_measure(nil)
    assert_eq(detect.cell_size({ ui = { kitty = { cell_px = { 9, 19 } } } }).w, 9, "cell_px override wins")
  end

  -- ------------------------------------------------------------------
  -- sessions under tmux: wrapped I/O, per-view cleanup, reattach
  -- ------------------------------------------------------------------
  local function tmux_session_config(extra)
    local cfg = vim.deepcopy(config)
    cfg.ui.connector_renderer = "auto"
    cfg.ui.kitty.cell_px = { 10, 20 }
    -- These exercise delivery tracking for allow-passthrough "on"; raising
    -- to "all" is covered separately.
    cfg.ui.kitty.tmux_passthrough_all = false
    cfg.ui.perf = { enabled = false }
    return vim.tbl_deep_extend("force", cfg, extra or {})
  end

  local function lines()
    local left, right = {}, {}
    for i = 1, 200 do
      left[i] = "line " .. i
      right[i] = "line " .. i
    end
    right[5] = "changed five"
    table.insert(right, 20, "added")
    right[120] = "changed 120"
    return left, right
  end

  local function start(cfg)
    local left, right = lines()
    return assert((Session.start({
      left = source_mod.from_lines(left, nil, "left"),
      right = source_mod.from_lines(right, nil, "right"),
    }, cfg, {})))
  end

  local function all_wrapped()
    for i, s in ipairs(sent) do
      local inner = unwrap(s)
      if not inner then
        return false, i
      end
      for _, c in ipairs(inner) do
        if c:sub(1, 3) ~= "\27_G" then
          return false, i
        end
      end
    end
    return true
  end

  local function deletes_of(id)
    local n = 0
    for _, s in ipairs(sent) do
      for _, c in ipairs(unwrap(s) or {}) do
        if c == protocol.delete(id) then
          n = n + 1
        end
      end
    end
    return n
  end

  do
    reset_tmux()
    local a = start(tmux_session_config())
    assert_eq(wait_for(function()
      return a.connector_renderer == "kitty"
    end), true, "auto session flips to kitty once tmux confirms support")
    a:render()
    local sta = a.kitty_state
    assert_eq(sta ~= nil and sta.transmits >= 1, true, "image transmitted through tmux")
    local ok, bad = all_wrapped()
    assert_eq(ok, true, "every graphics write is passthrough-wrapped (bad write #" .. tostring(bad) .. ")")
    local raw = table.concat(sent):gsub("\27\27", "")
    assert_eq(raw:find("\27_G", 1, true), nil, "no bare (unescaped) APC ever reaches tmux")

    -- Alignment: same ribbons as without tmux; independent scroll follows.
    local before = sta.transmits
    vim.api.nvim_win_call(a.right_win, function()
      vim.cmd("normal! 30\5")
    end)
    a:render()
    assert_eq(wait_for(function()
      return sta.transmits > before
    end), true, "independent scroll retransmits inside tmux")
    assert_eq((all_wrapped()), true, "scroll transmissions wrapped")

    -- A second view: closing the first deletes only the first image.
    local b = start(tmux_session_config())
    b:render()
    local stb = b.kitty_state
    assert_ne(sta.id, stb.id, "views own distinct image ids")
    a:close()
    assert_eq(deletes_of(sta.id), 1, "closing a view deletes its own image (wrapped)")
    assert_eq(deletes_of(stb.id), 0, "the other view's image is untouched")
    assert_eq(stb.destroyed, nil, "other view keeps its canvas")

    -- Reattach from the same terminal (new client pid): images re-sent.
    local sent_before = stb.transmits
    answer({ pid = "999" })
    detect.tmux_check(b.config)
    assert_eq(wait_for(function()
      return stb.transmits > sent_before
    end), true, "new tmux client (reattach) re-sends the images")

    -- Reattach from a terminal without graphics: cells, images deleted.
    answer({ pid = "1000", termtype = "iTerm2 3.5", termname = "xterm-256color" })
    detect.tmux_check(b.config)
    assert_eq(wait_for(function()
      return b.connector_renderer == "cells"
    end), true, "client without graphics flips the view to cells")
    assert_eq(deletes_of(stb.id) >= 1, true, "flip deletes the image")
    assert_eq(b.kitty_state, nil, "canvas released")

    -- Back in Ghostty: kitty again.
    answer({ pid = "1001" })
    detect.tmux_check(b.config)
    assert_eq(wait_for(function()
      return b.connector_renderer == "kitty"
    end), true, "returning to a graphics client restores the ribbons")
    b:render()
    local stb2 = b.kitty_state
    assert_eq(stb2 ~= nil and stb2.transmits >= 1, true, "fresh image after returning")

    -- Pane hidden while transmitting (other window, allow-passthrough on):
    -- re-sent once it is visible again.
    answer({ pid = "1001", window_active = "0" })
    detect.tmux_check(b.config)
    assert_eq(wait_for(function()
      return queries >= 1 and detect.status() == "kitty"
    end), true, "hidden check settles")
    vim.wait(50)
    local hidden_sent = stb2.transmits
    answer({ pid = "1001", window_active = "1" })
    detect.tmux_check(b.config)
    assert_eq(wait_for(function()
      return stb2.transmits > hidden_sent
    end), true, "pane shown again: images re-sent")

    -- FocusGained re-sends (switching back to the window / reattach).
    local focus_sent = stb2.transmits
    vim.api.nvim_exec_autocmds("FocusGained", {})
    assert_eq(wait_for(function()
      return stb2.transmits > focus_sent
    end), true, "FocusGained inside tmux re-sends the images")

    -- Pane resize (zoom) re-renders through the normal layout path.
    assert_eq((all_wrapped()), true, "all later writes stay wrapped")
    b:close()
    assert_eq(deletes_of(stb2.id), 1, "close deletes the remaining image")
    detect._reset()
  end

  -- Temp-file transmissions (forced) are removed on close and only for the
  -- closing view; image ids never collide across Neovim processes.
  do
    reset_tmux()
    local cfg = tmux_session_config({ ui = { connector_renderer = "kitty", kitty = { transmission = "file" } } })
    local a = start(cfg)
    local b = start(cfg)
    a:render()
    b:render()
    local fa = vim.deepcopy(a.kitty_state.files)
    local fb = vim.deepcopy(b.kitty_state.files)
    assert_eq(#fa >= 1 and #fb >= 1, true, "file transmissions write temp files")
    a:close()
    for _, p in ipairs(fa) do
      assert_eq(vim.uv.fs_stat(p), nil, "closed view's temp file removed")
    end
    for _, p in ipairs(fb) do
      assert_ne(vim.uv.fs_stat(p), nil, "other view's temp file kept")
    end
    b:close()
    for _, p in ipairs(fb) do
      assert_eq(vim.uv.fs_stat(p), nil, "second view's temp file removed on its close")
    end
    detect._reset()

    assert_ne(kitty_canvas.image_id(1, 0x101), kitty_canvas.image_id(1, 0x102),
      "the same slot in two processes maps to different ids")
    assert_eq(kitty_canvas.image_id(0xFFF, 0xFFF) < 0x1000000, true, "ids fit the 24-bit fg colour")
    assert_eq(kitty_canvas.image_id(1, 1) > 0, true, "ids are never 0")
  end

  -- ------------------------------------------------------------------
  -- inherited $TMUX (Zellij, a terminal or ssh started from inside tmux)
  -- ------------------------------------------------------------------
  do
    -- Same tty: a real tmux pane, tmux transport as usual.
    reset_tmux()
    detect._set_own_tty(function()
      return "/dev/ttys009"
    end)
    answer({ pane_tty = "/dev/ttys009" })
    detect.resolve({ ui = {} })
    assert_eq(wait_for(function()
      return detect.status() == "kitty"
    end), true, "matching pane tty: tmux detection")
    assert_eq(detect.passthrough(), "tmux", "matching pane tty keeps the tmux transport")

    -- Different tty: $TMUX belongs to an outer tmux. Never wrap or touch it;
    -- probe the terminal in front of us (here: Zellij, no placeholders).
    reset_tmux()
    detect._set_own_tty(function()
      return "/dev/ttys016"
    end)
    answer({ pane_tty = "/dev/ttys009" })
    detect.resolve({ ui = {} })
    assert_eq(wait_for(function()
      return #sent > 0
    end), true, "falls back to the in-band probe")
    assert_eq(detect.passthrough(), "none", "inherited $TMUX is ignored for wrapping")
    assert_eq(sent[1]:find(protocol.query(detect.QUERY_ID, "d"), 1, true), 1, "probe goes out unwrapped")
    assert_eq(#tmux_cmds, 0, "the outer tmux's options are never touched")
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. detect.QUERY_ID
      .. ";ENOTSUPPORTED:unicode placeholders are not supported\27\\" } })
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[?62;52c" } })
    assert_eq(wait_for(function()
      return detect.status() == "cells"
    end), true, "Zellij's placeholder rejection resolves to cells")
    local _, why = detect.status()
    assert_eq(why:find("ENOTSUPPORTED", 1, true) ~= nil, true, "reason is Zellij's answer")

    -- Forced kitty: stop wrapping once the mismatch is known, and re-send.
    reset_tmux()
    detect._set_own_tty(function()
      return "/dev/ttys016"
    end)
    answer({ pane_tty = "/dev/ttys009" })
    local resent = 0
    detect.on_retransmit(function()
      resent = resent + 1
    end)
    detect.resolve({ ui = { connector_renderer = "kitty" } })
    assert_eq(wait_for(function()
      return detect.passthrough() == "none"
    end), true, "forced kitty drops the inherited tmux transport")
    assert_eq(resent >= 1, true, "images written for the wrong transport are re-sent")
    assert_eq(#tmux_cmds, 0, "forced kitty never raises the outer tmux's passthrough")
    detect._reset()
  end

  -- ------------------------------------------------------------------
  -- review regressions
  -- ------------------------------------------------------------------

  -- A cell size learned from tmux is re-measured when the client changes
  -- (reattach from a terminal with another font), and views re-raster.
  do
    reset_tmux()
    detect._set_measure(function()
      return nil
    end)
    local cfg = tmux_session_config()
    cfg.ui.kitty.cell_px = nil
    local s1 = start(cfg)
    assert_eq(wait_for(function()
      return s1.connector_renderer == "kitty"
    end), true, "auto session in tmux")
    s1:render()
    local st = s1.kitty_state
    assert_eq(detect.cell_size(cfg).w .. "x" .. detect.cell_size(cfg).h, "16x34", "tmux cell size in use")
    assert_eq(st.last_key:find("|16|34|", 1, true) ~= nil, true, "image rasterized at 16x34")
    answer({ pid = "2000", cw = "10", ch = "20" })
    detect.tmux_check(cfg)
    assert_eq(wait_for(function()
      return detect.cell_size(cfg).w == 10
    end), true, "new client's cell size replaces the cached tmux measurement")
    assert_eq(wait_for(function()
      return s1.kitty_state and s1.kitty_state.last_key and s1.kitty_state.last_key:find("|10|20|", 1, true) ~= nil
    end), true, "views re-raster at the new cell size")
    -- Same client, font size changed (only tmux measures it).
    answer({ pid = "2000", cw = "12", ch = "24" })
    detect.tmux_check(cfg)
    assert_eq(wait_for(function()
      return s1.kitty_state and s1.kitty_state.last_key and s1.kitty_state.last_key:find("|12|24|", 1, true) ~= nil
    end), true, "a cell size change on the same client re-rasters too")
    s1:close()
    detect._set_measure(nil)
    detect._reset()
  end

  -- An image sent while the pane may have been hidden is re-sent on the next
  -- key, even when every visibility sample happened to say "visible".
  do
    reset_tmux()
    local s1 = start(tmux_session_config())
    assert_eq(wait_for(function()
      return s1.connector_renderer == "kitty"
    end), true, "auto session in tmux")
    s1:render()
    local st = s1.kitty_state
    -- Background re-render with no recent proof of visibility (e.g. a resize
    -- while another tmux window was shown, then switching back).
    vim.wait(300)
    kitty_canvas.invalidate(s1)
    s1:render()
    assert_eq(detect.tmux_unconfirmed(), true, "transmission without visibility proof is unconfirmed")
    answer({ window_active = "1" })
    detect.tmux_check(s1.config)
    vim.wait(50)
    local before = st.transmits
    detect.note_key()
    assert_eq(wait_for(function()
      return st.transmits > before
    end), true, "next key re-sends the unconfirmed image")
    assert_eq(detect.tmux_unconfirmed(), false, "re-send happens once")
    -- A transmission right after a key is known delivered.
    detect.note_key()
    kitty_canvas.invalidate(s1)
    s1:render()
    assert_eq(detect.tmux_unconfirmed(), false, "transmission after a key needs no re-send")

    -- A typed key whose mapping renders synchronously (long ]c, conflict
    -- jumps, hunk actions) after a pause: the key is stamped before the
    -- mapping runs, so its transmission is confirmed and nothing is re-sent.
    local function render_now()
      kitty_canvas.invalidate(s1)
      s1:render()
    end
    vim.keymap.set("n", "<Plug>(DiffBanditSpecRender)", render_now)
    local plug = vim.api.nvim_replace_termcodes("<Plug>(DiffBanditSpecRender)", true, false, true)
    vim.wait(300)
    before = st.transmits
    vim.api.nvim_feedkeys(plug, "mtx", false) -- "t": as if typed
    vim.wait(100)
    assert_eq(st.transmits - before, 1, "a typed key that renders synchronously transmits once")
    assert_eq(detect.tmux_unconfirmed(), false, "its transmission is confirmed")

    -- Keys from :normal / feedkeys / timers are not typed: no proof of
    -- visibility, the transmission stays unconfirmed.
    vim.wait(300)
    vim.api.nvim_feedkeys(plug, "mx", false)
    vim.wait(50)
    assert_eq(detect.tmux_unconfirmed(), true, "a non-typed key does not confirm a transmission")
    vim.keymap.del("n", "<Plug>(DiffBanditSpecRender)")
    s1:close()
    detect._reset()
  end

  -- The only client switches to another session and back (same client pid,
  -- same visibility). Passthrough written meanwhile had no recipient, even
  -- with allow-passthrough "all": session_last_attached moves, so re-send.
  do
    reset_tmux()
    local cfg = tmux_session_config()
    cfg.ui.kitty.tmux_passthrough_all = nil -- default: raised to "all"
    local s1 = start(cfg)
    assert_eq(wait_for(function()
      return s1.connector_renderer == "kitty"
    end), true, "auto session in tmux")
    s1:render()
    local st = s1.kitty_state
    detect.tmux_check(cfg)
    vim.wait(50)
    local before = st.transmits
    detect.tmux_check(cfg) -- same snapshot: nothing to do
    vim.wait(50)
    assert_eq(st.transmits, before, "an unchanged tmux snapshot re-sends nothing")
    answer({ last_attached = "107" })
    detect.tmux_check(cfg)
    assert_eq(wait_for(function()
      return st.transmits > before
    end), true, "returning to the session re-sends images, even with passthrough all")
    s1:close()
    detect._reset()
  end

  -- Image-id prefixes are claimed with flock(2), not hashed: pids 10000 and
  -- 14095 (equal mod 4095) get different prefixes, a released or crashed
  -- owner's prefix is free again, and concurrent claimers never share one.
  do
    local ids = require("diffbandit.kitty.ids")
    local dir = vim.fn.tempname() .. "-ids"
    ids._simulate({ dir = dir, pid = 10000 })
    local a = ids.prefix()
    ids._simulate({ dir = dir, pid = 14095 })
    local b = ids.prefix()
    assert_ne(a, b, "aliasing pids claim different prefixes")
    assert_ne(kitty_canvas.image_id(1, a), kitty_canvas.image_id(1, b), "their first image ids differ")
    assert_eq(ids._locked(dir, a), true, "a claim is a held lock")
    ids.release() -- the 14095 claim
    assert_eq(ids._locked(dir, b), false, "release drops the lock")
    ids._simulate({ dir = dir, pid = 14095 })
    assert_eq(ids.prefix(), b, "a released prefix can be claimed again")
    ids.release()

    -- Real processes: start several at once, all hashing to the same start
    -- prefix, and hold their claims; then SIGKILL one.
    local script = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
      "package.path = package.path .. ';' .. arg[1] .. '/lua/?.lua'",
      "local ids = require('diffbandit.kitty.ids')",
      "ids._simulate({ dir = arg[2], pid = 4242 })",
      "io.stdout:write(ids.prefix() .. '\\n')",
      "io.stdout:flush()",
      "vim.wait(20000, function() return false end)",
    }, script)
    local children, prefixes = {}, {}
    for i = 1, 6 do
      children[i] = vim.system({ vim.v.progpath, "--clean", "--headless", "-l", script, root, dir }, {
        stdout = function(_, data)
          local n = tonumber((data or ""):match("(%d+)"))
          if n then
            prefixes[i] = n
          end
        end,
      })
    end
    assert_eq(wait_for(function()
      local n = 0
      for _ in pairs(prefixes) do
        n = n + 1
      end
      return n == 6
    end, 10000), true, "concurrent claimers all report a prefix")
    local seen = {}
    for i = 1, 6 do
      assert_eq(seen[prefixes[i]], nil, "concurrent claimers never share a prefix")
      seen[prefixes[i]] = true
      assert_eq(ids._locked(dir, prefixes[i]), true, "each live claimer holds its lock")
    end
    children[1]:kill(9)
    children[1]:wait(2000)
    assert_eq(ids._locked(dir, prefixes[1]), false, "a crashed owner's prefix is free (kernel drops the lock)")
    for i = 2, 6 do
      children[i]:kill(9)
      children[i]:wait(2000)
    end
    ids._simulate(nil)
    vim.fn.delete(dir, "rf")
    vim.fn.delete(script)
    assert_eq(ids.prefix() >= 1 and ids.prefix() <= 0xFFF, true, "real process prefix in range")
  end

  -- allow-passthrough "on" drops images written while the pane is hidden,
  -- and visibility can change between any two samples: raise it to "all"
  -- for this pane only, before the first image, and restore it on exit.
  do
    local function cmds_matching(pat)
      local n = 0
      for _, c in ipairs(tmux_cmds) do
        if c:find(pat) then
          n = n + 1
        end
      end
      return n
    end

    reset_tmux()
    detect.resolve({ ui = {} })
    assert_eq(wait_for(function()
      return detect.status() == "kitty"
    end), true, "auto detects graphics")
    assert_eq(cmds_matching("^tmux show%-options %-p .*allow%-passthrough$"), 1, "reads the pane-local value first")
    assert_eq(cmds_matching("^tmux set%-option %-p .*allow%-passthrough all$"), 1, "raises this pane to all")
    assert_eq(cmds_matching("%-g") + cmds_matching("%-w"), 0, "never touches global or window options")
    assert_eq(tmux.raised(), true, "raise recorded")
    -- Even with "all", tmux drops passthrough while no client shows the
    -- session, and a quick switch away and back can leave tmux's snapshot
    -- identical (same pid, visibility, whole-second attach time). A send
    -- without a key just before it waits for the next key.
    detect.tmux_check({ ui = {} })
    vim.wait(50)
    detect.note_transmit()
    detect.tmux_check({ ui = {} }) -- identical snapshot after the switch back
    vim.wait(50)
    assert_eq(detect.tmux_unconfirmed(), true, "a background send with passthrough all is still unconfirmed")
    detect.note_key()
    assert_eq(detect.tmux_unconfirmed(), false, "the next key re-sends it")
    detect.note_transmit()
    assert_eq(detect.tmux_unconfirmed(), false, "a send right after a key is confirmed")

    tmux.restore_passthrough()
    assert_eq(cmds_matching("^tmux set%-option %-p %-u .*allow%-passthrough$"), 1,
      "exit restores inheritance when the pane had no own value")
    assert_eq(tmux.raised(), false, "restore clears the raise")

    reset_tmux()
    pane_local = "on"
    detect.resolve({ ui = {} })
    wait_for(function()
      return detect.status() == "kitty"
    end)
    tmux.restore_passthrough()
    assert_eq(cmds_matching("^tmux set%-option %-p .*allow%-passthrough on$"), 1,
      "exit restores the pane's own previous value")

    -- Overlapping raises (two tmux checks in flight) share one: the second
    -- must not read back our own "all" as the value to restore.
    reset_tmux()
    local results = {}
    tmux.raise_passthrough(500, function(ok)
      results[#results + 1] = ok
    end)
    tmux.raise_passthrough(500, function(ok)
      results[#results + 1] = ok
    end)
    assert_eq(wait_for(function()
      return #results == 2
    end), true, "both callers are answered")
    assert_eq(cmds_matching("^tmux set%-option %-p .*allow%-passthrough all$"), 1, "one raise for overlapping callers")
    tmux.restore_passthrough()
    assert_eq(cmds_matching("^tmux set%-option %-p %-u .*allow%-passthrough$"), 1,
      "restore still un-sets (previous value was not our own all)")

    -- The pane is reset to "on" after our raise: a fresh query reports "on",
    -- so "all" is applied again (the restore value stays the original).
    reset_tmux()
    detect.resolve({ ui = {} })
    wait_for(function()
      return detect.status() == "kitty"
    end)
    pane_local = "on"
    answer_defaults.passthrough = "on"
    detect.tmux_check({ ui = {} })
    assert_eq(wait_for(function()
      return cmds_matching("^tmux set%-option %-p .*allow%-passthrough all$") == 2
    end), true, "a pane reset to on is raised to all again")
    tmux.restore_passthrough()
    assert_eq(cmds_matching("^tmux set%-option %-p %-u .*allow%-passthrough$"), 1,
      "restore returns to the value found before the first raise")

    -- Exiting while the first raise is in flight (tmux applied it, Neovim has
    -- not processed the completion): restore ownership already exists.
    reset_tmux()
    hold_set = true
    tmux.raise_passthrough(500, function() end)
    assert_eq(wait_for(function()
      return cmds_matching("^tmux set%-option %-p .*allow%-passthrough all$") == 1
    end), true, "raise sent")
    assert_eq(tmux.raised(), true, "restore ownership is taken before set-option completes")
    tmux.restore_passthrough()
    assert_eq(cmds_matching("^tmux set%-option %-p %-u .*allow%-passthrough$"), 1,
      "an exit during the in-flight raise still restores the pane")

    -- tmux applies the raise, then vim.system times out (exit code 124):
    -- the outcome is unknown, so ownership stays and the restore checks.
    reset_tmux()
    set_code = 124
    local raise_ok
    tmux.raise_passthrough(500, function(ok)
      raise_ok = ok
    end)
    assert_eq(wait_for(function()
      return raise_ok ~= nil
    end), true, "timed-out raise completes")
    assert_eq(tmux.raised(), true, "a timeout keeps restore ownership")
    set_code = 0 -- the exit-time restore itself succeeds
    tmux.restore_passthrough()
    assert_eq(pane_local, "", "a raise that timed out after applying is still restored")

    -- The opposite ordering: Neovim exits before tmux has applied the raise.
    -- The restore waits for it, then sees "all" and restores.
    reset_tmux()
    delay_set_ms = 150
    tmux.raise_passthrough(500, function() end)
    assert_eq(wait_for(function()
      return cmds_matching("^tmux set%-option %-p .*allow%-passthrough all$") == 1
    end), true, "delayed raise sent")
    assert_eq(pane_local, "", "raise not applied yet")
    tmux.restore_passthrough()
    assert_eq(pane_local, "", "an exit before the raise lands still ends with the pane restored")
    assert_eq(cmds_matching("^tmux set%-option %-p %-u .*allow%-passthrough$"), 1,
      "restore ran after the pending raise completed")

    -- Exiting while the FIRST raise is still reading the pane value (no
    -- ownership yet): if anything pumps the loop after the restore returned
    -- (another VimLeavePre handler), the raise must not be sent.
    reset_tmux()
    delay_show_ms = 100
    local late_ok
    tmux.raise_passthrough(500, function(ok)
      late_ok = ok
    end)
    tmux.restore_passthrough()
    assert_eq(wait_for(function()
      return late_ok ~= nil
    end), true, "the pending raise completes")
    assert_eq(late_ok, false, "a raise answered after the exit restore reports failure")
    assert_eq(cmds_matching("^tmux set%-option %-p .*allow%-passthrough all$"), 0,
      "no set-option is sent after the exit restore")
    assert_eq(pane_local, "", "the pane is left untouched")
    local after_exit
    tmux.raise_passthrough(500, function(ok)
      after_exit = ok
    end)
    assert_eq(after_exit, false, "no new raise starts once exiting")

    -- The user changes the pane after our raise: exit keeps their choice.
    reset_tmux()
    detect.resolve({ ui = {} })
    wait_for(function()
      return detect.status() == "kitty"
    end)
    pane_local = "off"
    tmux.restore_passthrough()
    assert_eq(cmds_matching("%-u") + cmds_matching("allow%-passthrough on$"), 0,
      "a later explicit off survives the exit restore")

    -- Opt-out keeps the user's value and falls back to delivery tracking.
    reset_tmux()
    detect.resolve({ ui = { kitty = { tmux_passthrough_all = false } } })
    wait_for(function()
      return detect.status() == "kitty"
    end)
    assert_eq(#tmux_cmds, 0, "tmux_passthrough_all = false changes no tmux option")
    detect.note_transmit()
    assert_eq(detect.tmux_unconfirmed(), true, "without the raise, unproven transmissions await a re-send")

    -- A failed raise still renders, with delivery tracking.
    reset_tmux()
    set_code = 1
    detect.resolve({ ui = {} })
    assert_eq(wait_for(function()
      return detect.status() == "kitty"
    end), true, "failed raise still detects graphics")
    assert_eq(tmux.raised(), false, "failed raise not recorded")
    tmux.restore_passthrough()
    assert_eq(cmds_matching("%-u"), 0, "nothing to restore after a failed raise")
    detect._reset()
  end

  detect._set_sink(nil)
  detect._set_env(nil)
  tmux._set_runner(nil)
  vim.env.TMUX = saved_tmux_env
end
