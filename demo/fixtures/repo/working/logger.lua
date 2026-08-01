local Logger = {}

Logger.min = "debug"

local ORDER = {
  trace = 0,
  debug = 1,
  info = 2,
  warn = 3,
  error = 4,
}

function Logger.on(level)
  local rank = ORDER[level] or 0
  return rank >= ORDER[Logger.min]
end

function Logger.write(level, msg)
  if not Logger.on(level) then
    return
  end
  local tag = level:upper()
  io.write(tag .. ": " .. msg)
end

return Logger
