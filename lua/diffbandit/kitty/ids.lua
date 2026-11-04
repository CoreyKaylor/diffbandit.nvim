-- Per-process image-id namespace.
--
-- Image ids are 24-bit (the placeholder fg colour carries them): a 12-bit
-- process prefix and a 12-bit per-process slot. Several Neovim processes can
-- share one outer terminal (tmux panes, nested terminals), where an id
-- collision lets one process overwrite or delete another's ribbon. Hashing
-- the pid alone aliases (pids 10000 and 14095 agree mod 4095), so each
-- process claims a prefix in a per-user registry directory by holding an
-- exclusive flock(2) on that prefix's file for its whole lifetime.
--
-- The kernel arbitrates the lock atomically and drops it when the process
-- exits or crashes, so there is no stale-claim cleanup, no pid file to read,
-- and no window in which two processes can both win a prefix. Files are left
-- in place (empty, at most 4095); only the locks matter. Without LuaJIT ffi
-- or a usable directory the pid hash is used as a best-effort fallback.
local M = {}

M.PREFIXES = 0xFFF -- usable prefixes: 1..4095

local uv = vim.uv or vim.loop
local LOCK_EX, LOCK_NB = 2, 4

local claimed = nil -- { prefix = n, fd = int|nil }
local held = {} -- prefix -> fd, every lock this process holds (tests may hold several)
local dir_override = nil
local pid_override = nil

local flock = nil
local function get_flock()
  if flock ~= nil then
    return flock or nil
  end
  local ok, ffi = pcall(require, "ffi")
  if ok then
    pcall(ffi.cdef, "int flock(int fd, int operation);")
    local ok_fn, fn = pcall(function()
      return ffi.C.flock
    end)
    if ok_fn and fn then
      flock = function(fd, op)
        return ffi.C.flock(fd, op) == 0
      end
      return flock
    end
  end
  flock = false
  return nil
end

function M.dir()
  if dir_override then
    return dir_override
  end
  local tmp = vim.env.TMPDIR
  if not tmp or tmp == "" then
    tmp = "/tmp"
  end
  local uid = (uv.getuid and uv.getuid()) or 0
  return (tmp:gsub("/+$", "")) .. "/diffbandit-image-ids-" .. tostring(uid)
end

--- Try to lock `prefix` in `dir`. Returns the open fd on success.
local function try_lock(dir, prefix, lock)
  if held[dir .. "/" .. prefix] then
    return nil -- already ours (another simulated process in tests)
  end
  -- libuv opens with O_CLOEXEC: jobs Neovim spawns never inherit the lock.
  local fd = uv.fs_open(string.format("%s/%03x", dir, prefix), "a", 384)
  if not fd then
    return nil
  end
  if lock(fd, LOCK_EX + LOCK_NB) then
    held[dir .. "/" .. prefix] = fd
    return fd
  end
  uv.fs_close(fd)
  return nil
end

--- This process's prefix (1..4095), claimed on first use.
function M.prefix()
  if claimed then
    return claimed.prefix
  end
  local pid = pid_override or vim.fn.getpid()
  local start = pid % M.PREFIXES
  local lock = get_flock()
  local dir = M.dir()
  if lock and pcall(vim.fn.mkdir, dir, "p", "0o700") and vim.fn.isdirectory(dir) == 1 then
    for i = 0, M.PREFIXES - 1 do
      local prefix = ((start + i) % M.PREFIXES) + 1
      local fd = try_lock(dir, prefix, lock)
      if fd then
        claimed = { prefix = prefix, fd = fd, key = dir .. "/" .. prefix }
        break
      end
    end
  end
  if not claimed then
    claimed = { prefix = start + 1 }
  end
  return claimed.prefix
end

--- Release this process's claim (tests; the kernel does it on exit).
function M.release()
  if claimed and claimed.fd then
    uv.fs_close(claimed.fd) -- closing the fd drops the flock
    held[claimed.key] = nil
  end
  claimed = nil
end

--- Test hook: act as another process (opts = { dir, pid }). The current
--- claim stays held, as it would be by a still-running process.
function M._simulate(opts)
  opts = opts or {}
  claimed = nil
  dir_override = opts.dir
  pid_override = opts.pid
end

--- Test hook: is `prefix` in `dir` locked by someone (probe from a fresh fd)?
function M._locked(dir, prefix)
  local lock = get_flock()
  local fd = uv.fs_open(string.format("%s/%03x", dir, prefix), "a", 384)
  if not lock or not fd then
    return nil
  end
  local free = lock(fd, LOCK_EX + LOCK_NB)
  uv.fs_close(fd)
  return not free
end

return M
