--- Port forwarding. devcontainer.json `forwardPorts` (and :Devcontainer forward) become TCP
--- listeners on the host; each connection is relayed into the container through `docker exec -i`
--- running socat, bash (/dev/tcp), python3 or nc. That reaches servers bound to the container's
--- localhost and compose services ("db:5432"), with either backend, like VS Code does.
local config = require("devcontainer.config")
local log = require("devcontainer.log")

local M = {}
local uv = vim.uv

--- In-container relay tools, in order of preference.
M.RELAYS = { "socat", "bash", "python3", "nc" }

local BASH_RELAY = [[
hosts="$0"; [ "$0" = localhost ] && hosts="127.0.0.1 ::1"
for h in $hosts; do exec 3<>"/dev/tcp/$h/$1" && break; done 2>/dev/null
{ true >&3; } 2>/dev/null || { echo "connection to $0:$1 refused" >&2; exit 1; }
{ cat <&3; kill $$ 2>/dev/null; } & cat >&3; wait]]

local PY_RELAY = [[
import socket, sys, threading
s = socket.create_connection((sys.argv[1], int(sys.argv[2])))
def up():
    while True:
        d = sys.stdin.buffer.read1(65536)
        if not d:
            break
        s.sendall(d)
    try:
        s.shutdown(socket.SHUT_WR)
    except OSError:
        pass
threading.Thread(target=up, daemon=True).start()
while True:
    d = s.recv(65536)
    if not d:
        break
    sys.stdout.buffer.write(d)
    sys.stdout.buffer.flush()
]]

--- argv (inside the container) that connects stdin/stdout to host:port.
---@param kind string   socat | bash | python3 | nc
---@param exe? string   resolved path of the tool
function M.relay_argv(kind, host, port, exe)
  port = tostring(port)
  if kind == "socat" then return { exe or "socat", "-", ("TCP:%s:%s"):format(host, port) } end
  if kind == "bash" then return { exe or "bash", "-c", BASH_RELAY, host, port } end
  if kind == "python3" then return { exe or "python3", "-c", PY_RELAY, host, port } end
  if kind == "nc" then return { exe or "nc", host, port } end
  error("unknown relay " .. tostring(kind))
end

--- argv (inside the container) that succeeds once something listens on `port`. It reads
--- /proc/net/tcp instead of connecting: single-client servers (debug adapters) would take a
--- test connection for their client.
function M.listening_argv(port)
  return {
    "/bin/sh", "-c",
    'grep -qE ":$(printf %04X "$0") [0-9A-F]+:0000 0A" /proc/net/tcp /proc/net/tcp6 2>/dev/null',
    tostring(port),
  }
end

--- argv of the relay for a session, or nil when the container has none of the tools.
function M.relay_for(session, host, port)
  local custom = config.get(session.local_folder).ports.relay
  if type(custom) == "function" then return custom(host, port, session) end
  for _, kind in ipairs(M.RELAYS) do
    local exe = session:which(kind)
    if exe then return M.relay_argv(kind, host, port, exe), kind end
  end
end

--- portsAttributes entry for a port: exact key or a "from-to" range.
function M.attributes(attrs, port)
  if type(attrs) ~= "table" then return nil end
  if type(attrs[tostring(port)]) == "table" then return attrs[tostring(port)] end
  for key, a in pairs(attrs) do
    local lo, hi = tostring(key):match("^(%d+)%-(%d+)$")
    if lo and port >= tonumber(lo) and port <= tonumber(hi) and type(a) == "table" then return a end
  end
end

---@class devcontainer.PortSpec
---@field host string            where the relay connects, inside the container
---@field port integer
---@field local_port? integer    wanted host port (default: `port`)
---@field label? string
---@field on_auto_forward string notify | silent | ignore | openBrowser | openBrowserOnce
---@field require_local_port boolean
---@field protocol? string

--- forwardPorts + portsAttributes of a (merged) devcontainer.json.
---@return devcontainer.PortSpec[]
function M.parse(conf)
  local out = {}
  for _, p in ipairs(type(conf.forwardPorts) == "table" and conf.forwardPorts or {}) do
    local host, port = "localhost", nil
    if type(p) == "number" then
      port = p
    elseif type(p) == "string" then
      local h, n = p:match("^(.-):(%d+)$")
      if h and h ~= "" then
        host, port = h, tonumber(n)
      else
        port = tonumber(p:match("^(%d+)$"))
      end
    end
    if port then
      local a = M.attributes(conf.portsAttributes, port) or conf.otherPortsAttributes or {}
      table.insert(out, {
        host = host,
        port = port,
        label = type(a.label) == "string" and a.label or nil,
        on_auto_forward = type(a.onAutoForward) == "string" and a.onAutoForward or "notify",
        require_local_port = a.requireLocalPort == true,
        protocol = type(a.protocol) == "string" and a.protocol or nil,
      })
    end
  end
  return out
end

local function close(h)
  if h and not h:is_closing() then h:close() end
end

--- bind + listen, or nil and the error.
local function listen(addr, port, on_connection)
  local server = assert(uv.new_tcp())
  local ok, err = server:bind(addr, port)
  if ok then ok, err = server:listen(128, on_connection) end
  if not ok then
    close(server)
    return nil, err
  end
  return server, server:getsockname().port
end

--- Relay one accepted connection through a fresh `docker exec -i <relay>`.
local function pump(session, fwd, sock)
  local argv = session:exec_argv(fwd.relay, { stdin = true, env = false })
  local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local conn = { sock = sock }
  local handle, spawn_err
  local function finish()
    if conn.done then return end
    conn.done = true
    fwd.conns[conn] = nil
    close(stdin)
    close(stdout)
    close(stderr)
    close(sock)
    if handle and not handle:is_closing() then
      local kill = assert(uv.new_timer())
      kill:start(2000, 0, function()
        close(kill)
        if handle and not handle:is_closing() then pcall(handle.kill, handle, "sigterm") end
      end)
    end
  end
  conn.finish = finish
  handle, spawn_err = uv.spawn(argv[1], { args = vim.list_slice(argv, 2), stdio = { stdin, stdout, stderr } }, function()
    close(handle)
  end)
  if not handle then
    log.append(("port %d: cannot start relay: %s"):format(fwd.port, tostring(spawn_err)))
    return finish()
  end
  conn.handle = handle
  fwd.conns[conn] = true
  sock:read_start(function(err, data)
    if err or not data then
      -- client is done sending: let the relay pass EOF on, then give it a moment to finish
      if not stdin:is_closing() then stdin:shutdown() end
      local t = assert(uv.new_timer())
      t:start(2000, 0, function()
        close(t)
        finish()
      end)
      return
    end
    if not stdin:is_closing() then stdin:write(data) end
  end)
  stdout:read_start(function(err, data)
    if err or not data then
      if not sock:is_closing() then sock:shutdown(function() finish() end) end
      return
    end
    if not sock:is_closing() then sock:write(data) end
  end)
  stderr:read_start(function(_, data)
    if data then log.append(("port %d: %s"):format(fwd.port, data)) end
  end)
end

---@class devcontainer.Forward
---@field host string
---@field port integer
---@field local_port integer
---@field label? string
---@field protocol? string
---@field published? boolean  published by docker (appPort / -p) rather than tunnelled
---@field server? uv.uv_tcp_t
---@field conns table

local function key_of(host, port) return host .. ":" .. port end

--- Start forwarding `spec`. Returns the forward, or nil and an error message.
---@param spec devcontainer.PortSpec
---@return devcontainer.Forward?, string?
function M.forward(session, spec)
  session.forwards = session.forwards or {}
  local key = key_of(spec.host, spec.port)
  if session.forwards[key] then return session.forwards[key] end
  local relay = M.relay_for(session, spec.host, spec.port)
  if not relay then
    return nil, ("cannot forward port %d: the container has none of %s"):format(spec.port, table.concat(M.RELAYS, ", "))
  end
  local fwd = { host = spec.host, port = spec.port, label = spec.label, protocol = spec.protocol, relay = relay, conns = {} }
  local function on_connection(err)
    if err or not fwd.server then return end
    local sock = assert(uv.new_tcp())
    if fwd.server:accept(sock) then
      pump(session, fwd, sock)
    else
      close(sock)
    end
  end
  local bind = config.get(session.local_folder).ports.bind_address or "127.0.0.1"
  local wanted = spec.local_port or spec.port
  local server, port = listen(bind, wanted, on_connection)
  if not server then
    if spec.require_local_port then
      return nil, ("cannot forward port %d: local port %d is busy (%s)"):format(spec.port, wanted, tostring(port))
    end
    server, port = listen(bind, 0, on_connection)
    if not server then return nil, ("cannot forward port %d: %s"):format(spec.port, tostring(port)) end
  end
  fwd.server, fwd.local_port = server, port
  session.forwards[key] = fwd
  return fwd
end

local function stop_forward(fwd)
  close(fwd.server)
  fwd.server = nil
  for conn in pairs(fwd.conns or {}) do
    conn.finish()
    if conn.handle and not conn.handle:is_closing() then pcall(conn.handle.kill, conn.handle, "sigterm") end
  end
end

--- Stop forwarding a container port (any host). Returns true when something was stopped.
function M.unforward(session, port, host)
  local stopped = false
  for key, fwd in pairs(session.forwards or {}) do
    if fwd.port == port and (not host or fwd.host == host) then
      stop_forward(fwd)
      session.forwards[key] = nil
      stopped = true
    end
  end
  return stopped
end

function M.stop_all(session)
  for _, fwd in pairs(session.forwards or {}) do stop_forward(fwd) end
  session.forwards = {}
end

--- Forwards of a session, sorted by container port.
---@return devcontainer.Forward[]
function M.list(session)
  local out = vim.tbl_values(session.forwards or {})
  table.sort(out, function(a, b) return a.port < b.port end)
  return out
end

function M.url(fwd)
  return ("%s://localhost:%d"):format(fwd.protocol == "https" and "https" or "http", fwd.local_port)
end

function M.describe(fwd)
  local target = fwd.host == "localhost" and tostring(fwd.port) or key_of(fwd.host, fwd.port)
  local how = fwd.published and "published" or ("localhost:%d"):format(fwd.local_port)
  return ("%s → %s%s"):format(target, how, fwd.label and (" (" .. fwd.label .. ")") or "")
end

local opened_once = {}

--- Forward the ports of the devcontainer.json (after attach).
function M.start(session)
  if not config.get(session.local_folder).ports.forward then return end
  local shown = {}
  for _, spec in ipairs(M.parse(session.config or {})) do
    local published = spec.host == "localhost" and session.published and session.published[spec.port]
    if spec.on_auto_forward == "ignore" then
      -- listed in devcontainer.json but explicitly not wanted
    elseif published then
      session.forwards = session.forwards or {}
      session.forwards[key_of(spec.host, spec.port)] = {
        host = spec.host, port = spec.port, local_port = published, label = spec.label,
        protocol = spec.protocol, published = true, conns = {},
      }
    else
      local fwd, err = M.forward(session, spec)
      if not fwd then
        log.warn(err)
      else
        local mode = spec.on_auto_forward
        if mode ~= "silent" then table.insert(shown, M.describe(fwd)) end
        local once_key = session.local_folder .. ":" .. spec.port
        if mode == "openBrowser" or mode == "openPreview" or (mode == "openBrowserOnce" and not opened_once[once_key]) then
          opened_once[once_key] = true
          pcall(vim.ui.open, M.url(fwd))
        end
      end
    end
  end
  if #shown > 0 then log.info("forwarding " .. table.concat(shown, ", ")) end
end

--- "3000", "db:5432" -> host, port
function M.parse_arg(arg)
  arg = vim.trim(arg or "")
  local h, n = arg:match("^(.-):(%d+)$")
  if h and h ~= "" then return h, tonumber(n) end
  local p = tonumber(arg:match("^(%d+)$"))
  if p then return "localhost", p end
end

return M
