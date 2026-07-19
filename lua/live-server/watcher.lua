local uv = vim.uv or vim.loop

local M = {}

---@class live_server.WatcherConfig
---@field root string
---@field ignore_patterns vim.regex[]
---@field ignore_dotfiles boolean

---@type live_server.WatcherConfig
local config = {
  root = "",
  ignore_patterns = {},
  ignore_dotfiles = false,
}

---@param path string
---@return boolean
local function should_ignore(path)
  local rel_path = vim.fn.fnamemodify(path, ":." .. config.root)
  if config.ignore_dotfiles and (rel_path:match("^%.") or rel_path:match("/%.")) then return true end

  for _, rex in ipairs(config.ignore_patterns) do
    if rex:match_str(rel_path) then return true end
  end

  return false
end

---@param dir string
---@param on_change fun(filename: string)
---@param recursive boolean?
local function simple_watch(dir, on_change, recursive)
  local handle, err = uv.new_fs_event()
  assert(handle, err)

  if not handle then
    vim.notify("Live server has encountered an error  while setting up file watcher")
    return
  end

  handle:start(dir, { recursive = recursive }, function(err, filename)
    if err then
      vim.notify("Live server file watcher error occurred")
      return
    end
    if not filename then return end

    if should_ignore(filename) then return end

    vim.schedule(function() on_change(filename) end)
  end)
end

---@param root_dir string
---@param on_change fun(filename: string)
local function linux_watch(root_dir, on_change)
  if should_ignore(root_dir) then return end

  simple_watch(root_dir, on_change)
  local scanner = uv.fs_scandir(root_dir)
  if not scanner then return end

  while true do
    local name, type = uv.fs_scandir_next(scanner)
    if not name then break end

    if type == "directory" then
      local sub = root_dir .. "/" .. name
      -- Recurse only if not ignored
      if not should_ignore(sub) then linux_watch(sub, on_change) end
    end
  end
end

---@param dir string
---@param on_change fun(filename: string)
---@param opts live_server.Opts
function M.watch(dir, on_change, opts)
  config = {
    root = dir:gsub("/$", ""),
    ignore_patterns = {},
    ignore_dotfiles = opts.ignore_dotfiles,
  }

  -- compile patterns once to keep things fast
  for _, pattern in ipairs(opts.ignore_files or {}) do
    -- glob2regpat converts "**/node_modules/**" -> "^.*/node_modules/.*$"
    local regex_str = vim.fn.glob2regpat(pattern)
    table.insert(config.ignore_patterns, vim.regex(regex_str))
  end

  -- linux doesn't support recursive file watching
  -- (https://www.reddit.com/r/neovim/comments/1gchaus/recursive_directory_watching/)
  -- But you can watch a lot of dirs with quite a good performance
  -- cat /proc/sys/fs/inotify/max_user_watches --> 524288
  -- this might seem small but even the largest project I could find with node_modules
  -- included had 13k dirs. It should be ok. Maybe later add option to exclude dirs.
  if uv.os_uname().sysname == "Linux" then
    linux_watch(dir, on_change)
  else
    simple_watch(dir, on_change, true)
  end
end

return M
