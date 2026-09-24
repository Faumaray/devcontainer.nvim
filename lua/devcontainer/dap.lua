--- Debug adapters inside the devcontainer, for nvim-dap.
---
--- nvim-dap talks to a local TCP port; behind it this module spawns the (stdio) adapter via
--- `docker exec -i`, and rewrites workspace paths in both directions (launch `program`/`cwd`,
--- breakpoint sources, stack frames). `runInTerminal` requests are turned into
--- `docker exec -it ...` so the debuggee's terminal also lives in the container.
---
---   dap.adapters.gdb = require("devcontainer.dap").adapter({ command = "gdb", args = { "-i", "dap" } })
local log = require("devcontainer.log")
local registry = require("devcontainer.session")

local M = {}
local uv = vim.uv

local ACCEPT_TIMEOUT_MS = 10000

--- Content-Length framing (DAP base protocol). Returns a feed(chunk) function.
function M.framer(on_message)
  local buf = ""
  return function(chunk)
    buf = buf .. chunk
    while true do
      local header_end = buf:find("\r\n\r\n", 1, true)
      if not header_end then return end
      local len = tonumber(buf:sub(1, header_end):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
      if not len then
        buf = buf:sub(header_end + 4) -- malformed header: skip it
      else
        local body_start = header_end + 4
        if #buf < body_start + len - 1 then return end
        local body = buf:sub(body_start, body_start + len - 1)
        buf = buf:sub(body_start + len)
        on_message(body)
      end
    end
  end
end

function M.frame(body)
  return ("Content-Length: %d\r\n\r\n%s"):format(#body, body)
end

--- client -> adapter
function M.rewrite_to_adapter(session, msg, state)
  if msg.type == "response" and state.run_in_terminal[msg.request_seq] then
    state.run_in_terminal[msg.request_seq] = nil
    if type(msg.body) == "table" then
      -- host PIDs are meaningless in the container
      msg.body.processId, msg.body.shellProcessId = nil, nil
      if next(msg.body) == nil then msg.body = vim.empty_dict() end
    end
    return msg
  end
  return session.dap:to_remote(msg)
end

--- adapter -> client
function M.rewrite_to_client(session, msg, state)
  if msg.type == "request" and msg.command == "runInTerminal" and type(msg.arguments) == "table" then
    state.run_in_terminal[msg.seq] = true
    local a = msg.arguments
    local env = {}
    for k, v in pairs(type(a.env) == "table" and a.env or {}) do
      if type(v) == "string" then env[k] = v end
    end
    a.args = session:exec_argv(a.args or {}, { tty = true, cwd = a.cwd ~= "" and a.cwd or nil, env = env })
    a.cwd = session.local_folder
    a.env = nil
    return msg
  end
  return session.dap:to_local(msg)
end

local function close(h)
  if h and not h:is_closing() then h:close() end
end

--- Listen on 127.0.0.1:<random>; on the first connection spawn `argv` (a docker exec command)
--- and pump translated DAP messages between the socket and the adapter's stdio.
---@param opts? { on_close?: fun() }  called once when the debug session is over (or never started)
---@return integer port
function M.proxy(session, argv, opts)
  local on_close = opts and opts.on_close
  local function closed()
    if on_close then
      local f = on_close
      on_close = nil
      pcall(f)
    end
  end
  local server = assert(uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  local port = server:getsockname().port
  local state = { run_in_terminal = {} }
  local accepted = false
  local timer = assert(uv.new_timer())

  local function relay(rewrite, write)
    return M.framer(function(body)
      local ok, msg = pcall(vim.json.decode, body)
      if ok and type(msg) == "table" then
        local ok2, out = pcall(rewrite, session, msg, state)
        if ok2 then
          body = vim.json.encode(out)
        else
          log.append("dap proxy: " .. tostring(out))
        end
      end
      write(M.frame(body))
    end)
  end

  server:listen(1, function(err)
    if err or accepted then return end
    accepted = true
    timer:stop()
    close(timer)
    local sock = assert(uv.new_tcp())
    server:accept(sock)
    close(server)

    local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local handle, done = nil, false
    local function shutdown()
      if done then return end
      done = true
      closed()
      close(stdin)
      close(stdout)
      close(stderr)
      if not sock:is_closing() then
        sock:shutdown(function() close(sock) end)
      end
      if handle and not handle:is_closing() then
        -- the client went away first: give the adapter a moment to exit on stdin EOF
        local kill = assert(uv.new_timer())
        kill:start(2000, 0, function()
          close(kill)
          if handle and not handle:is_closing() then pcall(handle.kill, handle, "sigterm") end
        end)
      end
    end

    local spawn_err
    handle, spawn_err = uv.spawn(argv[1], {
      args = vim.list_slice(argv, 2),
      stdio = { stdin, stdout, stderr },
      cwd = session.local_folder,
    }, function(code)
      log.append(("debug adapter exited with code %d"):format(code))
      close(handle)
      -- stdout EOF normally arrives too; this is a safety net
      local t = assert(uv.new_timer())
      t:start(500, 0, function()
        close(t)
        shutdown()
      end)
    end)
    if not handle then
      log.error("cannot start debug adapter: " .. tostring(spawn_err))
      return shutdown()
    end

    local to_client = relay(M.rewrite_to_client, function(data)
      if not sock:is_closing() then sock:write(data) end
    end)
    local to_adapter = relay(M.rewrite_to_adapter, function(data)
      if not stdin:is_closing() then stdin:write(data) end
    end)
    stdout:read_start(function(e, data)
      if e or not data then return shutdown() end
      to_client(data)
    end)
    stderr:read_start(function(_, data)
      if data then log.append(data) end
    end)
    sock:read_start(function(e, data)
      if e or not data then return shutdown() end
      to_adapter(data)
    end)
  end)

  timer:start(ACCEPT_TIMEOUT_MS, 0, function()
    if not accepted then
      close(timer)
      close(server)
      log.append("dap proxy: nvim-dap never connected")
      closed()
    end
  end)

  return port
end

local function pick_session(cfg)
  for _, p in ipairs({ cfg and cfg.cwd, cfg and type(cfg.program) == "string" and cfg.program or nil }) do
    local s = type(p) == "string" and registry.find(vim.fs.normalize(p))
    if s then return s end
  end
  return registry.current()
end

local function resolve_cmd(session, command)
  return session:which(command) or (command:find("/", 1, true) and session:which(vim.fs.basename(command))) or nil
end

--- A TCP ("server") adapter such as codelldb or delve: start it in the container, wait until it
--- listens, and hand nvim-dap the local proxy whose upstream is a relay to the adapter's port.
local function server_adapter(spec, session, callback)
  local ports = require("devcontainer.ports")
  local exe = spec.executable or {}
  if not exe.command then
    return log.error("devcontainer.dap: server adapters need `executable = { command = ..., args = ... }`")
  end
  local cmd = resolve_cmd(session, exe.command)
  if not cmd then return log.error(("%s not found in container %s"):format(exe.command, session.name)) end
  local port = tonumber(spec.port) or (20000 + vim.uv.hrtime() % 20000)
  local args = vim.tbl_map(function(a)
    return type(a) == "string" and (a:gsub("%${port}", tostring(port))) or a
  end, exe.args or {})
  local relay = ports.relay_for(session, "127.0.0.1", port)
  if not relay then return log.error("devcontainer.dap: the container has none of " .. table.concat(ports.RELAYS, ", ")) end

  local exited = false
  local adapter = vim.system(session:exec_argv(vim.list_extend({ cmd }, args), {
    cwd = exe.cwd and (session:remote_path(exe.cwd) or exe.cwd) or nil,
  }), {
    stdout = function(_, data) if data then log.append(data) end end,
    stderr = function(_, data) if data then log.append(data) end end,
  }, function(res)
    exited = true
    log.append(("debug adapter %s exited with code %d"):format(exe.command, res.code))
  end)
  session.dap_procs = session.dap_procs or {}
  session.dap_procs[adapter] = true
  local function stop_adapter()
    session.dap_procs[adapter] = nil
    if not exited then pcall(adapter.kill, adapter, 15) end
  end

  -- poll until the adapter listens (not by connecting: it only accepts one client)
  local probe = session:exec_argv(ports.listening_argv(port), { env = false })
  local deadline = vim.uv.now() + 10000
  local function poll()
    if exited then return log.error(("debug adapter %s exited before listening (see :Devcontainer log)"):format(exe.command)) end
    vim.system(probe, {}, vim.schedule_wrap(function(res)
      if res.code ~= 0 then
        if vim.uv.now() > deadline then
          stop_adapter()
          return log.error(("debug adapter %s did not listen on port %d"):format(exe.command, port))
        end
        return vim.defer_fn(poll, 100)
      end
      local ok, proxy_port = pcall(M.proxy, session, session:exec_argv(relay, { stdin = true, env = false }), { on_close = stop_adapter })
      if not ok then
        stop_adapter()
        return log.error("devcontainer.dap: " .. tostring(proxy_port))
      end
      callback({
        type = "server",
        host = "127.0.0.1",
        port = proxy_port,
        id = spec.id,
        enrich_config = spec.enrich_config,
        options = spec.options,
      })
    end))
  end
  poll()
end

--- nvim-dap adapter that runs inside the devcontainer of the debugged project (and unchanged on
--- the host when there is none). Stdio adapters: `{ command, args?, options?, id? }`. TCP adapters
--- (codelldb, delve): `{ type = "server", port = "${port}", executable = { command, args } }`.
---@param spec { type?: string, command?: string, args?: string[], port?: string|integer, executable?: table, options?: table, id?: string, enrich_config?: function }
function M.adapter(spec)
  if spec.type == "server" then
    return function(callback, cfg)
      local session = pick_session(cfg)
      if not session then return callback(spec) end
      server_adapter(spec, session, callback)
    end
  end
  return function(callback, cfg)
    local session = pick_session(cfg)
    if not session then
      return callback(vim.tbl_extend("force", spec, { type = "executable" }))
    end
    local options = vim.deepcopy(spec.options or {})
    local env, cwd = options.env, options.cwd
    options.env, options.cwd, options.detached = nil, nil, nil

    local cmd = resolve_cmd(session, spec.command)
    if not cmd then
      log.error(("%s not found in container %s"):format(spec.command, session.name))
      return
    end
    local argv = session:exec_argv(vim.list_extend({ cmd }, spec.args or {}), {
      stdin = true,
      cwd = cwd and (session:remote_path(cwd) or cwd),
      env = env,
    })
    local ok, port = pcall(M.proxy, session, argv)
    if not ok then
      log.error("devcontainer.dap: " .. tostring(port))
      return
    end
    callback({
      type = "server",
      host = "127.0.0.1",
      port = port,
      id = spec.id,
      enrich_config = spec.enrich_config,
      options = next(options) and options or nil,
    })
  end
end

return M
