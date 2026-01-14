local uv = vim.uv or vim.loop

local M = {}

---@param dir string
---@param on_change fun()
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

    on_change()
  end)
end

---@param root_dir string
---@param on_change fun()
local function linux_watch(root_dir, on_change)
  simple_watch(root_dir, on_change)
  local scanner = uv.fs_scandir(root_dir)
  if not scanner then return end

  while true do
    local name, type = uv.fs_scandir_next(scanner)
    if not name then break end

    if type == "directory" then
      local sub = root_dir .. "/" .. name
      linux_watch(sub, on_change) -- recurse
    end
  end
end

---@param dir string
---@param on_change fun()
function M.watch(dir, on_change)
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
