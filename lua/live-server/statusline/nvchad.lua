M = {}

local server = require("live-server.server")

function M.render()
  return server.running and " %@v:lua.require'live-server'.stop@󰙧 Port: " .. tostring(server.port) .. " %T"
    or " %@v:lua.require'live-server'.start@󰀂 Go Live %T"
end

return M
