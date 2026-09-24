--- Runs language servers inside the devcontainer.
---
--- `vim.lsp.start` is wrapped: for managed servers whose root_dir lies inside an attached
--- devcontainer, `cmd` is replaced by a function that spawns the server through
--- `docker exec -i` and translates every message between host and container paths.
local config = require("devcontainer.config")
local log = require("devcontainer.log")
local registry = require("devcontainer.session")

local M = {}

local helpers = setmetatable({}, { __mode = "k" }) -- cmd functions created by M.cmd() -> argv

--- LSP options for a workspace root (profiles applied), or the global ones.
local function opts(root)
  return config.get(root).lsp
end

function M.managed(name, root)
  local o = opts(root)
  if not o.enabled or not name then return false end
  if vim.tbl_contains(o.exclude or {}, name) then return false end
  return o.servers == "*" or vim.tbl_contains(o.servers or {}, name)
end

--- Workspace root of a client config (root_dir or the first workspace folder).
function M.root_of(cfg)
  if type(cfg.root_dir) == "string" then return cfg.root_dir end
  local wf = type(cfg.workspace_folders) == "table" and cfg.workspace_folders[1]
  if wf and wf.uri then return vim.uri_to_fname(wf.uri) end
end

local function host_cmd_of(cfg)
  if cfg._devcontainer_host_cmd then return cfg._devcontainer_host_cmd end
  if type(cfg.cmd) == "table" then return cfg.cmd end
  if type(cfg.cmd) == "function" then return helpers[cfg.cmd] end
end
M.host_cmd = host_cmd_of

-- private Neovim helpers, with fallbacks in case they move
local resolve_bufnr = vim._resolve_bufnr or function(bufnr)
  return (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
end
local get_workspace_folders = vim.lsp._get_workspace_folders or function(folders)
  if type(folders) == "table" then return folders end
  if type(folders) == "string" then return { { uri = vim.uri_from_fname(folders), name = folders } } end
end

--- Arguments that name the compilation database dir: clangd's --compile-commands-dir.
local function cdb_arg(argv)
  for i = 2, #argv do
    local a = argv[i]
    if type(a) == "string" then
      local v = a:match("^%-%-compile%-commands%-dir=(.*)$")
      if v then return i, v, true end
      if a == "--compile-commands-dir" and type(argv[i + 1]) == "string" then return i + 1, argv[i + 1], false end
    end
  end
end

local function inside(path, folder)
  return path == folder or path:sub(1, #folder + 1) == folder .. "/"
end

--- A server told where compile_commands.json is (clangd --compile-commands-dir, or
--- init_options.compilationDatabasePath) follows the active build dir of its project: `build`
--- becomes `build/Debug`, the dir of the selected profile / preset, ... Only relative dirs and dirs
--- inside the project are followed. Host paths (the container translation maps them).
---@param argv string[] host command
---@param cfg table config (root_dir, init_options)
---@return string[] argv, table? init_options, { dir: string, ready: boolean }? cdb
function M.remap_compile_commands(argv, cfg)
  local root = M.root_of(cfg)
  if not root or config.get(root).lsp.follow_build_dir == false then return argv end
  local idx, given, joined = cdb_arg(argv)
  local io_path = type(cfg.init_options) == "table" and cfg.init_options.compilationDatabasePath
  if not idx and type(io_path) ~= "string" then return argv end
  local dir, ctx = require("devcontainer.project").compile_commands_dir(root)
  if not dir then return argv end
  local function follows(p)
    return type(p) == "string" and (p:sub(1, 1) ~= "/" or inside(vim.fs.normalize(p), ctx.root))
  end
  local new_argv, init_options = argv, nil
  if idx and follows(given) then
    new_argv = vim.list_extend({}, argv)
    new_argv[idx] = joined and ("--compile-commands-dir=" .. dir) or dir
  end
  if follows(io_path) then
    init_options = vim.tbl_extend("force", {}, cfg.init_options, { compilationDatabasePath = dir })
  end
  if new_argv == argv and not init_options then return argv end
  return new_argv, init_options, { dir = dir, ready = vim.uv.fs_stat(dir .. "/compile_commands.json") ~= nil }
end

--- argv to run inside the container, or nil when the server isn't installed there.
local function remote_argv(session, name, host_cmd, cfg)
  local override = opts(session.local_folder).remote_cmd[name]
  if type(override) == "function" then override = override(host_cmd, session) end
  if type(override) == "table" then
    if not cdb_arg(override) then return override end
    -- its --compile-commands-dir follows the build dir too: remap in host paths, then map back
    local replace_root = require("devcontainer.paths").replace_root
    local as_host = vim.tbl_map(function(a)
      return type(a) == "string" and replace_root(a, session.remote_folder, session.local_folder) or a
    end, override)
    local remapped, _, cdb = M.remap_compile_commands(as_host, cfg)
    if remapped == as_host then return override end
    return vim.tbl_map(function(a) return session:map_arg(a) end, remapped), cdb
  end

  local bin = host_cmd[1]
  local found = session:which(bin)
  if not found and bin:find("/", 1, true) then
    -- absolute host path (e.g. mason): look the binary up by name in the container
    found = session:which(vim.fs.basename(bin))
  end
  if not found then return nil end
  local argv = { found }
  for i = 2, #host_cmd do argv[#argv + 1] = session:map_arg(host_cmd[i]) end
  return argv
end

--- Start `argv` inside the container and return a vim.lsp.rpc.PublicClient that speaks
--- host paths to Neovim and container paths to the server.
---@param session devcontainer.Session
---@param argv string[]
---@param dispatchers vim.lsp.rpc.Dispatchers
---@param extra? { cwd?: string, env?: table<string,string> }
function M.rpc(session, argv, dispatchers, extra)
  extra = extra or {}
  local tr = session.lsp
  local proxied = {
    notification = function(method, params)
      return dispatchers.notification(method, tr:to_local(params))
    end,
    server_request = function(method, params)
      local result, err = dispatchers.server_request(method, tr:to_local(params))
      return tr:to_remote(result), err
    end,
    on_exit = dispatchers.on_exit,
    on_error = dispatchers.on_error,
  }
  local cmd = session:exec_argv(argv, { stdin = true, cwd = extra.cwd, env = extra.env })
  local rpc = vim.lsp.rpc.start(cmd, proxied, { cwd = session.local_folder })

  local client = setmetatable({}, { __index = rpc })
  function client.request(method, params, callback, notify_reply_callback)
    if method == "initialize" and type(params) == "table" then
      -- the host PID means nothing inside the container; servers that watch it would exit
      params = vim.tbl_extend("force", {}, params, { processId = vim.NIL })
    end
    return rpc.request(method, tr:to_remote(params), function(err, result)
      callback(err, tr:to_local(result))
    end, notify_reply_callback)
  end
  function client.notify(method, params)
    return rpc.notify(method, tr:to_remote(params))
  end
  return client
end

--- Build an LSP `cmd` that runs in the devcontainer when there is one, and on the host otherwise.
--- Use it for servers that are *not installed on the host*: `vim.lsp.enable()` refuses to start a
--- config whose cmd[1] isn't executable locally, but it accepts functions.
---
---   vim.lsp.config("clangd", { cmd = require("devcontainer").lsp_cmd({ "clangd", "--background-index" }) })
function M.cmd(argv)
  local fn = function(dispatchers, cfg)
    return vim.lsp.rpc.start(argv, dispatchers, { cwd = cfg.cmd_cwd, env = cfg.cmd_env, detached = cfg.detached })
  end
  helpers[fn] = argv
  return fn
end

local function remote_start_fn(key, argv)
  return function(dispatchers, cfg)
    local session = registry.by_key[key]
    if not session then error("devcontainer " .. key .. " is not attached", 0) end
    -- like on the host: cmd_cwd, else Neovim's cwd (so relative arguments mean the same thing)
    local cwd = cfg.cmd_cwd or vim.fn.getcwd()
    return M.rpc(session, argv, dispatchers, {
      cwd = session.lsp:path_to_remote(cwd) or nil,
      env = cfg.cmd_env,
    })
  end
end

--- Decide where a config runs. Returns a (copied) config, or nil to not start it.
function M.rewrite(cfg)
  local host_cmd = host_cmd_of(cfg)
  local name = cfg.name or (type(host_cmd) == "table" and vim.fs.basename(host_cmd[1])) or nil
  local root = M.root_of(cfg)
  local session = root and registry.find(root)
  if not host_cmd then return cfg end
  if not M.managed(name, session and session.local_folder) then
    if not cfg._devcontainer_host_cmd then return cfg end
    -- was running in a container, now excluded (profile change): back to the host command
    local host = vim.tbl_extend("force", {}, cfg, { cmd = host_cmd })
    host._devcontainer_host_cmd, host._devcontainer_key = nil, nil
    return host
  end

  local new = vim.tbl_extend("force", {}, cfg)
  new.name = name
  new._devcontainer_host_cmd = host_cmd
  new._devcontainer_key = nil

  -- --compile-commands-dir / compilationDatabasePath follow the project's active build dir
  local argv_host, init_options, cdb = M.remap_compile_commands(host_cmd, cfg)
  if init_options then new.init_options = init_options end
  new._devcontainer_cdb = cdb
  local host_start = (cfg._devcontainer_host_cmd or argv_host ~= host_cmd) and argv_host or cfg.cmd

  if not session then
    -- installed only in the container (lsp_cmd, or a config adopted while attached): wait for it
    if vim.fn.executable(host_cmd[1]) == 0 then return nil end
    new.cmd = host_start
    return new
  end

  local argv, override_cdb = remote_argv(session, name, argv_host, cfg)
  new._devcontainer_cdb = cdb or override_cdb
  if not argv then
    local fallback = opts(session.local_folder).fallback
    if not session.warned[name] then
      session.warned[name] = true
      log.warn(("%s not found in container %s — %s"):format(
        host_cmd[1], session.name,
        fallback == "local" and "running it on the host" or "not starting it"
      ))
    end
    if fallback ~= "local" then return nil end
    new.cmd = host_start
    return new
  end

  new.cmd = remote_start_fn(session.key, argv)
  new._devcontainer_key = session.key
  new._devcontainer_argv = argv -- what runs in the container (for :Devcontainer info, tests)
  return new
end

-- Same as Neovim's default reuse_client (not exported).
local function default_reuse(client, cfg)
  if client.name ~= cfg.name or client:is_stopped() then return false end
  local folders = get_workspace_folders(cfg.workspace_folders or cfg.root_dir)
  if not folders or not next(folders) then
    local cf = get_workspace_folders(client.config.workspace_folders or client.config.root_dir)
    return not cf or not next(cf)
  end
  for _, f in ipairs(folders) do
    local found = false
    for _, cf in ipairs(client.workspace_folders or {}) do
      if cf.uri == f.uri then
        found = true
        break
      end
    end
    if not found then return false end
  end
  return true
end

local function attach_existing(bufnr, key, name)
  for _, c in ipairs(vim.lsp.get_clients({ name = name })) do
    if c.config._devcontainer_key == key and not c:is_stopped() then
      if vim.lsp.buf_attach_client(bufnr, c.id) then return c.id end
    end
  end
end

local patched = false
function M.patch()
  if patched then return end
  patched = true
  local orig_start = vim.lsp.start

  local orig_enable = vim.lsp.enable
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.enable = function(name, enable)
    if enable ~= false and opts().enabled then
      pcall(M.adopt, type(name) == "table" and name or { name })
    end
    return orig_enable(name, enable)
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.start = function(cfg, start_opts)
    start_opts = start_opts or {}
    if type(cfg) ~= "table" or not opts().enabled then return orig_start(cfg, start_opts) end
    local bufnr = resolve_bufnr(start_opts.bufnr)

    -- container-only files (devcontainer://<id>/usr/include/...) only talk to that container's servers
    local key = vim.api.nvim_buf_get_name(bufnr):match("^devcontainer://([^/]+)")
    if key then
      return attach_existing(bufnr, key, cfg.name or (type(cfg.cmd) == "table" and vim.fs.basename(cfg.cmd[1])))
    end

    if not cfg.root_dir and start_opts._root_markers then
      cfg = vim.tbl_extend("force", {}, cfg, { root_dir = vim.fs.root(bufnr, start_opts._root_markers) })
    end

    local ok, new = pcall(M.rewrite, cfg)
    if not ok then
      log.error("devcontainer: " .. tostring(new))
      new = cfg
    end
    if not new then return end

    local user_reuse = start_opts.reuse_client
    start_opts = vim.tbl_extend("force", {}, start_opts, {
      reuse_client = function(client, c)
        -- never share a client between the host and a container (or two containers)
        if client.config._devcontainer_key ~= c._devcontainer_key then return false end
        return (user_reuse or default_reuse)(client, c)
      end,
    })
    return orig_start(new, start_opts)
  end
end

--- Attach every server of `session` that handles this filetype to a devcontainer:// buffer.
function M.attach_remote_buffer(bufnr, session)
  if not vim.api.nvim_buf_is_loaded(bufnr) then return end
  local ft = vim.bo[bufnr].filetype
  for _, c in ipairs(vim.lsp.get_clients()) do
    local fts = c.config.filetypes
    if c.config._devcontainer_key == session.key and not c:is_stopped() and (not fts or vim.tbl_contains(fts, ft)) then
      vim.lsp.buf_attach_client(bufnr, c.id)
    end
  end
end

--- Executables of the running clients whose workspace is `folder` (or below): what `up` has to
--- look up in the container before moving them (see Session:prefetch).
function M.binaries(folder)
  local out = {}
  for _, c in ipairs(vim.lsp.get_clients()) do
    local root, cmd = M.root_of(c.config), host_cmd_of(c.config)
    if root and inside(root, folder) and type(cmd) == "table" and type(cmd[1]) == "string" then
      vim.list_extend(out, { cmd[1], vim.fs.basename(cmd[1]) })
    end
  end
  return out
end

---@class devcontainer.LspEntry
---@field client vim.lsp.Client
---@field config table
---@field bufs integer[]

--- Stop every client whose workspace is `folder` (or below), remembering its buffers.
---@param key? string  also the clients of this container
---@param filter? fun(client: vim.lsp.Client): boolean  only these
---@return devcontainer.LspEntry[]
function M.stop_clients(folder, key, filter)
  local entries = {}
  local roots = { folder, vim.uv.fs_realpath(folder) }
  for _, c in ipairs(vim.lsp.get_clients()) do
    local root = M.root_of(c.config)
    local match = key and c.config._devcontainer_key == key
    for _, r in ipairs(roots) do
      match = match or (root and inside(root, r))
    end
    if match and not c:is_stopped() and (not filter or filter(c)) then
      entries[#entries + 1] = { client = c, config = c.config, bufs = vim.tbl_keys(c.attached_buffers) }
      c:stop()
    end
  end
  return entries
end

-- folder -> the move in progress: its clients are still exiting
local moves = {}

--- Wait (≤3s) for the stopped clients to exit, then start them again for their buffers.
--- Each config goes through the patched vim.lsp.start, so it lands wherever it belongs now.
---
--- One move per workspace: a newer one (stop right after up, up with another backend, ...) takes
--- over the clients of the one still waiting, instead of both starting them when their timers fire.
---@param entries devcontainer.LspEntry[]
---@param after? fun()  called once the clients have been started again
---@param folder? string  workspace the move belongs to
function M.start_clients(entries, after, folder)
  local afters = {}
  local previous = folder and moves[folder]
  if previous then
    previous.cancel()
    local seen = {}
    for _, e in ipairs(entries) do seen[e.client.id] = true end
    for _, e in ipairs(previous.entries) do
      if not seen[e.client.id] then
        seen[e.client.id] = true
        entries[#entries + 1] = e
      end
    end
    vim.list_extend(afters, previous.afters) -- e.g. up's start of servers that couldn't run before
  end
  table.insert(afters, after)
  local function finish()
    for _, fn in ipairs(afters) do fn() end
  end
  if #entries == 0 then return finish() end
  local timer = assert(vim.uv.new_timer())
  local move = { entries = entries, afters = afters }
  function move.cancel()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if folder and moves[folder] == move then moves[folder] = nil end
  end
  if folder then moves[folder] = move end
  local waited = 0
  timer:start(0, 100, vim.schedule_wrap(function()
    if timer:is_closing() then return end
    waited = waited + 100
    local pending = vim.tbl_filter(function(e) return not e.client:is_stopped() end, entries)
    if #pending > 0 and waited < 3000 then return end
    move.cancel()
    for _, e in ipairs(pending) do e.client:stop(true) end

    for _, e in ipairs(entries) do
      local host_cmd = host_cmd_of(e.config)
      local root = M.root_of(e.config)
      local session = root and registry.find(root)
      local runnable = session
        or type(host_cmd) ~= "table"
        or vim.fn.executable(host_cmd[1]) == 1
      for _, buf in ipairs(runnable and e.bufs or {}) do
        local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
        if vim.api.nvim_buf_is_loaded(buf) and not name:match("^devcontainer://") then
          vim.lsp.start(e.config, { bufnr = buf })
        end
      end
    end
    finish()
  end))
end

--- vim.lsp.enable() won't start a config whose cmd[1] isn't executable on the host (clangd
--- installed only in the container). While a container is attached, such configs get a cmd
--- function (M.cmd), which it accepts; the patched vim.lsp.start then runs it in the container.
---@param names? string[]  default: every enabled config
function M.adopt(names)
  if next(registry.by_key) == nil then return end
  names = names or vim.tbl_keys(vim.lsp._enabled_configs or {})
  for _, name in ipairs(names) do
    local ok, cfg = pcall(function() return vim.lsp.config[name] end)
    local cmd = ok and type(cfg) == "table" and cfg.cmd
    if type(cmd) == "table" and type(cmd[1]) == "string" and vim.fn.executable(cmd[1]) == 0 and M.managed(name) then
      vim.lsp.config(name, { cmd = M.cmd(cmd) })
    end
  end
end

--- Run the startup of vim.lsp.enable() (and nvim-lspconfig's setup()) again for the file buffers
--- in `folder`: servers that couldn't start before the container was attached start now.
function M.retrigger(folder)
  local roots = { folder, vim.uv.fs_realpath(folder) }
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local in_folder = false
    for _, r in ipairs(roots) do
      in_folder = in_folder or (name ~= "" and inside(name, r))
    end
    if in_folder and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "" then
      for _, group in ipairs({ "nvim.lsp.enable", "lspconfig" }) do
        if pcall(vim.api.nvim_get_autocmds, { group = group, event = "FileType" }) then
          pcall(vim.api.nvim_exec_autocmds, "FileType", { group = group, buffer = buf, modeline = false })
        end
      end
    end
  end
end

--- Restart the clients below `root` that follow the build dir (see M.remap_compile_commands)
--- when the active build dir changed and has a compile_commands.json, or when the database they
--- were started without now exists (first configure).
function M.refresh_compile_commands(root)
  local project = require("devcontainer.project")
  local entries = M.stop_clients(root, nil, function(c)
    local cdb = c.config._devcontainer_cdb
    if not cdb then return false end
    local dir = project.compile_commands_dir(M.root_of(c.config) or root)
    if not dir or not vim.uv.fs_stat(dir .. "/compile_commands.json") then return false end
    return dir ~= cdb.dir or not cdb.ready
  end)
  if #entries == 0 then return end
  local s = registry.find(root)
  M.start_clients(entries, nil, s and s.local_folder or root)
end

--- Move every client of `folder` to wherever it should run now (container or host).
--- Then start the servers that couldn't run before (see M.adopt / M.retrigger).
function M.restart(folder, entries)
  entries = entries or {}
  local seen = {}
  for _, e in ipairs(entries) do seen[e.client.id] = true end
  for _, e in ipairs(M.stop_clients(folder)) do
    if not seen[e.client.id] then entries[#entries + 1] = e end
  end
  M.adopt()
  M.start_clients(entries, function() M.retrigger(folder) end, folder)
end

return M
