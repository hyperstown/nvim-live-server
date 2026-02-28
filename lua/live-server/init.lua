local server = require("live-server.server")
local watcher = require("live-server.watcher")

local M = {}

M.opts = {
  host = "0.0.0.0",
  port = 8080,
  bind_attempts = 2,
  ignore_files = {},
  ignore_dotfiles = true,
  open_browser = true,
}

---@class live_server.Opts
---@field port integer
---@field host string
---@field bind_attempts integer
---@field ignore_files string[]
---@field ignore_dotfiles boolean
---@field open_browser boolean

---@param opts live_server.Opts
function M.setup(opts) M.opts = vim.tbl_deep_extend("force", M.opts, opts) end

function M.start()
  local root = vim.fn.getcwd()

  server.start(root, M.opts)
  watcher.watch(root, function() server.reload() end, M.opts)
  vim.cmd("redrawstatus")
end

function M.stop()
  server.stop()
  vim.cmd("redrawstatus")
end

function M.toggle()
  if server.running then
    M.stop()
  else
    M.start()
  end
end

return M
