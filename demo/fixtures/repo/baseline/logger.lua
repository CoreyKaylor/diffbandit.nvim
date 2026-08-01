local Logger = {}

Logger.min = "info"

local ORDER = {
  debug = 1,
  info = 2,
  warn = 3,
  error = 4,
}

function Logger.on(level)
  local rank = ORDER[level]
  return rank >= ORDER[Logger.min]
end

function Logger.write(level, msg)
  if not Logger.on(level) then
    return
  end
  io.write(level .. ": " .. msg)
end

return Logger
