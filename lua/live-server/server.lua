local uv = vim.uv or vim.loop
local M = {}

local server ---@type uv.uv_tcp_t?
local root_dir ---@type string

local inject_snippet = [[
<!--  Code injected by nvim-live-server -->
<script>
(() => {
  const es = new EventSource("/__live_reload");

  // When the page is about to reload or navigate
  window.addEventListener("beforeunload", () => {
    es.close(); // explicitly close SSE
  });

  // Swap stylesheets in place with a cache-busting query param
  const refreshCSS = () => {
    for (const link of document.querySelectorAll('link[rel="stylesheet"]')) {
      const url = new URL(link.href);
      url.searchParams.set('_lr', Date.now());
      link.href = url.href;
    }
  };

  // Reload when SSE message arrives
  es.onmessage = (msg) => {
    if (msg.data === 'reload') location.reload();
    else if (msg.data === 'refreshcss') refreshCSS();
  };
})();
</script>
]]

---@param html string
---@param path string
---@return string
local function inject(html, path)
  if not html:find("</body>") then
    vim.schedule(function()
      vim.notify("Live reload is not supported without a body tag", vim.log.levels.WARN)
    end)
    return html
  end

  if path:match("%.html?$") then return (html:gsub("</body>", inject_snippet .. "\n</body>")) end
  return html
end

---@type uv.uv_tcp_t[]
M.sse_clients = {}

-- https://mimetype.io/all-types
local mime_types = {
  html = "text/html",
  htm = "text/html",
  css = "text/css",
  png = "image/png",
  gif = "image/gif",
  avif = "image/avif",
  webp = "image/webp",
  apng = "image/apng",
  mp4 = "video/mp4",
  mpeg = "video/mpeg",
  m1v = "video/mpeg",
  mpg = "video/mpeg",
  webm = "video/webm",
  wav = "audio/x-wav",
  mp3 = "audio/mpeg",
  mp2 = "audio/mpeg",
  m3u = "application/vnd.apple.mpegurl",
  m3u8 = "application/vnd.apple.mpegurl",
  txt = "text/plain",
  woff = "font/woff",
  woff2 = "font/woff2",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  svg = "image/svg+xml",
  ico = "image/x-icon",
  xml = "application/xml",
  pdf = "application/pdf",
  json = "application/json",
  js = "application/javascript",
  mjs = 'application/javascript',
  wasm = 'application/wasm',
  webmanifest = 'application/manifest+json',
}

---@param path string
---@return string
local function get_mime_type(path)
  local ext = path:match("%.([^./]+)$")
  return mime_types[ext] or "application/octet-stream"
end

---@param text string
---@return string
local function html_response(text) return ("<!DOCTYPE html><html><body>%s</body></html>"):format(text) end

---@param client uv.uv_tcp_t
---@param status string
---@param headers {[string]: string}
---@param body string?
local function send(client, status, headers, body, cb)
  local lines = { ("HTTP/1.1 %s"):format(status) }
  for k, v in pairs(headers) do
    table.insert(lines, ("%s: %s"):format(k, v))
  end
  table.insert(lines, "")
  table.insert(lines, body or "")

  client:write(table.concat(lines, "\r\n"), cb)
end

---@param client uv.uv_tcp_t
---@param raw string
local function handle_request(client, raw)
  ---@type string?, string?
  local method, path = raw:match("(%w+)%s+([^%s]+)")
  if method ~= "GET" then
    send(client, "405 Method Not Allowed", {
      ["Content-Type"] = "text/plain",
    }, html_response("Method Not Allowed"))
    client:close()
    return
  end
  if not path then
    client:close()
    return
  end

  -- ignore query params
  path = path:gsub("[?#].*$", "")

  if path == "/__live_reload" then
    client:write(table.concat({
      "HTTP/1.1 200 OK",
      "Content-Type: text/event-stream",
      "Cache-Control: no-cache",
      "Connection: keep-alive",
      "Access-Control-Allow-Origin: * ",
      "",
    }, "\r\n"))

    table.insert(M.sse_clients, client)
    client:write("data: start\n\n")
    return
  end

  if path:sub(-1) == "/" then path = path .. "index.html" end

  local file_path = root_dir .. path
  local file = io.open(file_path, "rb")

  if not file then
    send(client, "404 Not Found", {
      ["Content-Type"] = "text/html",
    }, html_response("Not Found"), function()
      client:close()
    end)

    return
  end

  local body = file:read("*a") ---@type string?
  file:close()
  if not body then
    send(client, "404 Not Found", {
      ["Content-Type"] = "text/html",
    }, html_response("Not Found"), function()
      client:close()
    end)
    return
  end

  local mime = get_mime_type(path)

  if mime == "text/html" then body = inject(body, path) end

  send(client, "200 OK", {
    ["Content-Type"] = mime,
    ["Content-Length"] = tostring(#body),
    ["Cache-Control"] = "no-cache",
    ["Access-Control-Allow-Origin"] = "*",
  }, body, function()
      client:close()
    end)
end

-- -----------------------------
-- PUBLIC API
-- -----------------------------
---@param root string
---@param config live_server.Opts
function M.start(root, config)
  local start = uv.hrtime()
  local host = config.host
  local port = config.port
  local max_attempts = config.bind_attempts
  if M.running then
    vim.notify("Live server already running!", vim.log.levels.WARN)
    return
  end

  root_dir = root

  server = uv.new_tcp()
  if not server then
    vim.notify("Live server encounter TCP error!", vim.log.levels.ERROR)
    return
  end

  ---@param conn_err string?
  local on_connection = function(conn_err)
    assert(not conn_err, conn_err)

    local client = uv.new_tcp()
    if not client then
      vim.schedule(function()
        vim.notify("Live server encounter TCP error", vim.log.levels.ERROR)
      end)
      return
    end

    server:accept(client)
    client:read_start(function(r_err, data)
      assert(not r_err, r_err)

      if not data then
        for i, c in ipairs(M.sse_clients) do
          if c == client then
            table.remove(M.sse_clients, i)
            break
          end
        end
        client:close()
        return
      end
      handle_request(client, data)
    end)
  end

  ---@param port_curr integer
  ---@return string?
  local function bind_server(port_curr)
    local b_ok, b_err, b_err_name = server.bind(server, host, port_curr)
    if not b_ok then
      if port_curr == 0 or b_err_name == "EADDRINUSE" then
        vim.notify(("Live server failed to bind server: %s"):format(b_err), vim.log.levels.ERROR)
        return b_err
      end
      local new_port = (port_curr + 2 <= port + max_attempts) and (port_curr + 1) or 0
      return bind_server(new_port)
    end
    local l_ok, l_err, l_err_name = server:listen(128, on_connection)
    if not l_ok then
      if port_curr == 0 or l_err_name ~= "EADDRINUSE" then
        vim.notify(("Failed to listen on server: %s"):format(l_err), vim.log.levels.ERROR)
        return b_err
      end
      local new_port = (port_curr + 2 <= port + max_attempts) and (port_curr + 1) or 0
      return bind_server(new_port)
    end
  end

  local err = bind_server(port)
  if err then return end

  M.running = true
  M.port = server:getsockname().port
  M.host = server:getsockname().ip
  local url = ("http://%s:%d"):format(M.host, M.port)
  local elapsed_ms = (uv.hrtime() - start) / 1e6
  vim.notify(("Server started in %.3fms at %s"):format(elapsed_ms, url))

  if config.open_browser then vim.ui.open(url) end
end

function M.stop()
  if server then
    server:close()
    server = nil
  end
  M.running = false
  M.sse_clients = {}
  vim.notify("Live server stopped")
end

---@param filename string? changed file; CSS files refresh stylesheets without a full reload
function M.reload(filename)
  local msg = (filename and filename:match("%.css$")) and "refreshcss" or "reload"
  -- reverse loop to safely remove clients from the table
  for i = #M.sse_clients, 1, -1 do
    local client = M.sse_clients[i]
    local _, err = client:write(("data: %s\n\n"):format(msg))
    if err then
      client:close()
      table.remove(M.sse_clients, i)
    end
  end
end

return M
