local async = require("devcontainer.async")
local config = require("devcontainer.config")
local log = require("devcontainer.log")
local registry = require("devcontainer.session")
local spec = require("devcontainer.spec")
local store = require("devcontainer.store")

local M = {}

local did_setup = false
local busy = {}

---@param opts? devcontainer.Options
function M.setup(opts)
  config.set(opts)
  spec.clear_cache()
  did_setup = true
  require("devcontainer.lsp").patch()
  if config.options.remote_fs then require("devcontainer.remote_fs").setup() end

  local group = vim.api.nvim_create_augroup("devcontainer", { clear = true })
  require("devcontainer.autostart").setup(group)
  -- customizations["devcontainer.nvim"] / workspace detection may have changed
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "devcontainer.json", ".devcontainer.json" },
    callback = function()
      spec.clear_cache()
      require("devcontainer.profiles").invalidate()
    end,
  })
  if config.options.watch_config then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      callback = function(ev) M._config_saved(vim.fs.normalize(vim.fn.fnamemodify(ev.match, ":p"))) end,
    })
  end
  if config.options.stop_on_exit then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        for _, s in pairs(registry.by_key) do
          require("devcontainer.container").stop_detached(s)
        end
      end,
    })
  end
end

--- User autocmd + statusline refresh.
local function emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", { pattern = pattern, modeline = false, data = data })
  pcall(vim.cmd.redrawstatus, { bang = true })
end

local function event_data(s)
  return { name = s.name, key = s.key, container_id = s.container_id, local_folder = s.local_folder, remote_folder = s.remote_folder }
end

--- A file that defines an attached container was saved: offer to rebuild.
local prompting = {}
function M._config_saved(file)
  for _, s in pairs(registry.by_key) do
    local dir = vim.fs.dirname(s.config_file)
    -- .devcontainer/ (not the workspace itself for a root .devcontainer.json)
    local in_config_dir = dir ~= s.local_folder and vim.startswith(file, dir .. "/")
    if (in_config_dir or vim.tbl_contains(s.watch_files or {}, file)) and not prompting[s.key] then
      prompting[s.key] = true
      vim.ui.select({ "Rebuild now", "Not now" }, {
        prompt = ("The configuration of %s changed"):format(s.name),
        kind = "devcontainer.rebuild",
      }, function(choice)
        prompting[s.key] = nil
        if choice == "Rebuild now" then M.up({ path = s.local_folder, rebuild = true }) end
      end)
    end
  end
end

--- Is `:Devcontainer up` currently running for this workspace root?
function M.is_starting(root)
  return busy[root] == true
end

local function ensure_setup()
  if not did_setup then M.setup({}) end
end

local function pick_backend(o)
  local b = o.backend
  if b == "auto" then b = vim.fn.executable(o.cli) == 1 and "cli" or "docker" end
  return b, require("devcontainer.backend." .. b)
end

--- The config file to use: the one named by the `devcontainer` option (a profile), the only one,
--- or ask. Runs inside async.run.
local function choose_config(root, configs, wanted)
  if wanted then
    for _, p in ipairs(configs) do
      local rel = p:sub(#root + 2)
      if rel == wanted or vim.fs.basename(vim.fs.dirname(p)) == wanted then return p end
    end
    log.warn(("devcontainer config %q not found in %s"):format(wanted, root))
  end
  if #configs == 1 then return configs[1] end
  return async.select(configs, {
    prompt = "Devcontainer configuration",
    format_item = function(p) return p:sub(#root + 2) end,
  })
end

local function stream(_, data) log.append(data) end

--- Folder to operate on: the current buffer's file, else the cwd.
local function start_path(opts)
  if opts and opts.path then return opts.path end
  local name = vim.api.nvim_buf_get_name(0)
  local s = registry.find(name)
  if s then return s.local_folder end
  if name == "" or name:match("^%a[%w+.-]*://") then return vim.fn.getcwd() end
  return name
end

--- Forget a session: unregister it and wipe its (unmodified) devcontainer:// buffers.
function M._teardown(session)
  registry.unregister(session)
  require("devcontainer.ports").stop_all(session)
  for proc in pairs(session.dap_procs or {}) do pcall(proc.kill, proc, 15) end
  local prefix = "devcontainer://" .. session.key .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.startswith(vim.api.nvim_buf_get_name(buf), prefix) and not vim.bo[buf].modified then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  emit("DevcontainerDetached", event_data(session))
end

--- devcontainer:// buffers read before the container was attached (restored by a session
--- manager, say) are read again now.
local function reload_unread(session)
  local prefix = "devcontainer://" .. session.key .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].devcontainer_unread
      and vim.startswith(vim.api.nvim_buf_get_name(buf), prefix) and not vim.bo[buf].modified then
      vim.api.nvim_buf_call(buf, function() pcall(vim.cmd.edit, { bang = true }) end)
    end
  end
end

local function is_running(session)
  local res = async.system({ session.docker, "inspect", "-f", "{{.State.Running}}", session.container_id }, { text = true })
  return res.code == 0 and vim.trim(res.stdout or "") == "true"
end

--- Start (or reuse) the devcontainer of the current workspace and move its LSP clients into it.
---@param opts? { rebuild?: boolean, no_cache?: boolean, path?: string, quiet?: boolean }
function M.up(opts)
  ensure_setup()
  opts = opts or {}
  local lsp = require("devcontainer.lsp")
  local path = start_path(opts)
  local root = spec.find_root(path) or spec.find_root(vim.fn.getcwd())
  if not root then
    if not opts.quiet then log.warn("no .devcontainer/devcontainer.json or .devcontainer.json found") end
    return
  end
  if busy[root] then return log.warn("devcontainer for " .. root .. " is already starting") end
  busy[root] = true
  emit("DevcontainerStarting", { local_folder = root })

  local progress, unsubscribe
  local entries = {} -- clients stopped to move them; started again wherever they belong now
  async.run(function()
    local o = config.get(root)
    local configs = spec.list_configs(root)
    if #configs == 0 then error("no devcontainer.json in " .. root, 0) end
    local config_file = choose_config(root, configs, o.devcontainer)
    if not config_file then return end
    local conf, remote_folder, explicit = spec.load(config_file, root)
    if not conf then error(remote_folder, 0) end

    local existing = registry.by_folder(root)
    if existing and not opts.rebuild and existing.config_file == config_file and is_running(existing) then
      return log.info(("already attached to %s (%s)"):format(existing.name, existing.key))
    end

    -- the container predates changes to devcontainer.json / Dockerfile: offer to rebuild it
    local fingerprint = spec.fingerprint(config_file, conf)
    local known = store.get(root).fingerprint
    if not opts.rebuild and o.watch_config and type(known) == "table" and known.file == config_file
      and known.hash ~= fingerprint and #require("devcontainer.container").find(o.docker, root, config_file) > 0 then
      local choice = async.select({ "Rebuild the container", "Start the existing container" }, {
        prompt = "The devcontainer configuration changed since the container was built",
        kind = "devcontainer.rebuild",
      })
      if not choice then return end
      opts.rebuild = choice == "Rebuild the container"
    end

    if existing then
      entries = lsp.stop_clients(root, existing.key)
      M._teardown(existing)
    end

    -- serve the agent before the container starts: the CLI runs lifecycle commands during `up`
    if o.git and o.git.ssh_agent and vim.fn.has("mac") == 0 then require("devcontainer.git").start_agent_relay() end

    local backend_name, backend = pick_backend(o)
    local name = conf.name or vim.fs.basename(root)
    log.info(("%s %s (%s backend, progress: :Devcontainer log)"):format(
      opts.rebuild and "rebuilding" or "starting", name, backend_name))
    progress = require("devcontainer.progress").start("devcontainer " .. name)
    progress:report(opts.rebuild and "rebuilding" or "starting")
    unsubscribe = log.subscribe(function(lines) progress:feed(lines) end)

    local res = backend.up({
      local_folder = root,
      config_file = config_file,
      config = conf,
      remote_folder = remote_folder,
      explicit_remote_folder = explicit,
      docker = o.docker,
      options = o,
    }, { rebuild = opts.rebuild, no_cache = opts.no_cache })

    local session = registry.new({
      container_id = res.container_id,
      local_folder = root,
      remote_folder = res.remote_folder,
      remote_user = res.remote_user,
      docker = o.docker,
      backend = backend_name,
      config_file = config_file,
      config = res.config,
      name = res.config.name or name,
    })
    progress:report("probing the environment of " .. (session.remote_user or "the container user"))
    session:setup_env(res.config)
    -- one exec instead of one blocking `which` per server when the clients move in
    local bins = lsp.binaries(root)
    for _, e in ipairs(entries) do
      local cmd = lsp.host_cmd(e.config)
      if type(cmd) == "table" and type(cmd[1]) == "string" then vim.list_extend(bins, { cmd[1], vim.fs.basename(cmd[1]) }) end
    end
    table.insert(bins, o.project.debug.command[1])
    vim.list_extend(bins, require("devcontainer.ports").RELAYS)
    session:prefetch(bins)

    require("devcontainer.git").after_attach(session, o)

    -- lifecycle hooks (the devcontainer CLI runs these itself)
    for _, hook in ipairs(res.hooks or {}) do
      for _, argv in ipairs(spec.commands(res.config[hook])) do
        log.info("running " .. hook)
        progress:report("running " .. hook)
        local r = async.system(session:exec_argv(argv), { text = true, stdout = stream, stderr = stream })
        if r.code ~= 0 then log.warn(("%s failed with exit code %d"):format(hook, r.code)) end
      end
    end

    -- dotfiles after the create hooks, like the CLI (which installs them itself)
    if res.created then require("devcontainer.git").install_dotfiles(session, o) end
    require("devcontainer.container").inspect(session)
    session.watch_files = spec.config_files(config_file, conf)
    store.set(root, "fingerprint", { file = config_file, hash = fingerprint })

    registry.register(session)
    log.info(("attached to %s: %s -> %s"):format(session.name, root, session.remote_folder))
    lsp.restart(root, entries)
    reload_unread(session)
    require("devcontainer.ports").start(session)
    emit("DevcontainerAttached", event_data(session))

    -- postAttachCommand runs on every attach and is left to the tool, even with the CLI
    for _, argv in ipairs(spec.commands(res.config.postAttachCommand)) do
      vim.system(session:exec_argv(argv), { text = true, stdout = stream, stderr = stream })
    end
  end, function(err)
    busy[root] = nil
    if unsubscribe then unsubscribe() end
    if progress then progress:finish(not err, err and "failed" or "attached") end
    if err then
      log.error("devcontainer: " .. tostring(err))
      -- nothing attached: the clients stopped for the move go back to the host
      if not registry.by_folder(root) then lsp.start_clients(entries, nil, root) end
    end
  end)
end

function M.rebuild(opts)
  M.up(vim.tbl_extend("force", opts or {}, { rebuild = true }))
end

--- Detach from and stop the current workspace's container; LSP clients move back to the host.
function M.stop()
  registry.pick(function(s)
    if not s then return log.warn("no devcontainer attached") end
    M._stop(s)
  end, "Stop devcontainer")
end

function M._stop(s)
  local lsp = require("devcontainer.lsp")
  local entries = lsp.stop_clients(s.local_folder, s.key)
  M._teardown(s)
  log.info("stopping " .. s.name)
  require("devcontainer.container").stop(s, function(err)
    if err then return log.error("stop failed: " .. tostring(err)) end
    log.info(s.name .. " stopped")
  end)
  lsp.start_clients(entries, nil, s.local_folder)
end

--- Remove the container of the current workspace (docker compose down for compose configs).
--- The workspace files are not touched. Asks first.
---@param opts? { confirm?: boolean }
function M.down(opts)
  registry.pick(function(s)
    if not s then return log.warn("no devcontainer attached") end
    local function remove()
      local lsp = require("devcontainer.lsp")
      local entries = lsp.stop_clients(s.local_folder, s.key)
      M._teardown(s)
      store.set(s.local_folder, "fingerprint", nil)
      log.info("removing " .. s.name)
      require("devcontainer.container").remove(s, function(err)
        if err then return log.error("remove failed: " .. tostring(err)) end
        log.info(s.name .. " removed")
      end)
      lsp.start_clients(entries, nil, s.local_folder)
    end
    if opts and opts.confirm == false then return remove() end
    vim.ui.select({ "Remove", "Cancel" }, {
      prompt = ("Remove the container of %s%s? The workspace files are kept."):format(
        s.name, s.compose_project and (" (compose project " .. s.compose_project .. ")") or ""),
      kind = "devcontainer.down",
    }, function(choice)
      if choice == "Remove" then remove() end
    end)
  end, "Remove devcontainer")
end

--- Forwarded ports of the current devcontainer: open one in the browser, copy its address or
--- stop forwarding it.
function M.ports()
  local ports = require("devcontainer.ports")
  registry.pick(function(s)
    if not s then return log.warn("no devcontainer attached") end
    local list = ports.list(s)
    if #list == 0 then return log.info("no forwarded ports (:Devcontainer forward <port>)") end
    vim.ui.select(list, { prompt = "Ports of " .. s.name, format_item = ports.describe }, function(fwd)
      if not fwd then return end
      local actions = { "Open in browser", "Copy address" }
      if not fwd.published then table.insert(actions, "Stop forwarding") end
      vim.ui.select(actions, { prompt = ports.describe(fwd) }, function(action)
        if action == "Open in browser" then
          vim.ui.open(ports.url(fwd))
        elseif action == "Copy address" then
          vim.fn.setreg("+", ("localhost:%d"):format(fwd.local_port))
          vim.fn.setreg('"', ("localhost:%d"):format(fwd.local_port))
          log.info(("copied localhost:%d"):format(fwd.local_port))
        elseif action == "Stop forwarding" then
          ports.unforward(s, fwd.port, fwd.host)
        end
      end)
    end)
  end, "Devcontainer")
end

--- Forward a container port: "3000", "db:5432", optionally followed by the local port.
function M.forward(arg)
  local ports = require("devcontainer.ports")
  local target, local_port = vim.trim(arg or ""):match("^(%S+)%s*(%d*)$")
  local host, port = ports.parse_arg(target)
  if not port then return log.warn("usage: :Devcontainer forward <port | host:port> [local port]") end
  registry.pick(function(s)
    if not s then return log.warn("no devcontainer attached") end
    local fwd, err = ports.forward(s, {
      host = host, port = port, local_port = tonumber(local_port), on_auto_forward = "notify",
      require_local_port = local_port ~= "",
    })
    if not fwd then return log.error(err) end
    log.info("forwarding " .. ports.describe(fwd))
  end, "Devcontainer")
end

--- Stop forwarding a container port.
function M.unforward(arg)
  local ports = require("devcontainer.ports")
  local host, port = ports.parse_arg(arg)
  if not port then return log.warn("usage: :Devcontainer unforward <port | host:port>") end
  registry.pick(function(s)
    if not s then return log.warn("no devcontainer attached") end
    if not ports.unforward(s, port, arg:find(":", 1, true) and host or nil) then
      log.warn(("port %d is not forwarded"):format(port))
    end
  end, "Devcontainer")
end

--- Add a devcontainer configuration to the current project from a template.
function M.init_config()
  ensure_setup()
  require("devcontainer.templates").init(start_path())
end

--- Find and open a file that exists only in the container (below `dir`, or a folder of `files.roots`).
function M.files(dir)
  registry.pick(function(s)
    if not s then return log.warn("no devcontainer attached") end
    require("devcontainer.picker").files(s, dir and vim.trim(dir) or nil)
  end, "Devcontainer")
end

--- Open the devcontainer.json of the current workspace.
function M.open_config()
  local s = registry.current()
  if s then return vim.cmd.edit(vim.fn.fnameescape(s.config_file)) end
  local root = spec.find_root(start_path())
  if not root then return log.warn("no devcontainer config here (:Devcontainer init creates one)") end
  local configs = spec.list_configs(root)
  if #configs == 1 then return vim.cmd.edit(vim.fn.fnameescape(configs[1])) end
  vim.ui.select(configs, {
    prompt = "Devcontainer configuration",
    format_item = function(p) return p:sub(#root + 2) end,
  }, function(p)
    if p then vim.cmd.edit(vim.fn.fnameescape(p)) end
  end)
end

local LOGIN_SHELL = 'shell="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"; exec "${shell:-/bin/sh}" -l'

--- Open a terminal running `cmd` (or the user's login shell) in the container.
function M.exec(cmd)
  local dir = vim.fn.expand("%:p:h")
  registry.pick(function(s)
    if not s then return log.warn("no devcontainer attached — run :Devcontainer up") end
    local interactive = not (cmd and vim.trim(cmd) ~= "")
    local argv = interactive and { "/bin/sh", "-c", LOGIN_SHELL } or { "/bin/sh", "-lc", cmd }
    local cwd = (dir ~= "" and s:remote_path(dir)) or s.remote_folder
    require("devcontainer.terminal").open(s:exec_argv(argv, { tty = true, cwd = cwd }), {
      cwd = s.local_folder,
      title = interactive and s.name or cmd,
    })
  end, "Devcontainer")
end

--- `argv` wrapped to run in the devcontainer of `opts.path` (default: the current buffer / cwd):
--- a `docker exec` command with host workspace paths in the arguments translated. Returns `argv`
--- unchanged (and no session) when there is no attached devcontainer. For your own jobs, terminal
--- plugins, test runners, ...
---
---   local argv = require("devcontainer").wrap_cmd({ "make", "-C", vim.fn.getcwd() .. "/sub" })
---@param argv string[]
---@param opts? { path?: string, cwd?: string, env?: table<string,string>, tty?: boolean, stdin?: boolean }
---@return string[] argv, devcontainer.Session? session
function M.wrap_cmd(argv, opts)
  opts = opts or {}
  local s
  if opts.path or opts.cwd then
    s = registry.find(opts.path or opts.cwd)
  else
    s = registry.current()
  end
  if not s then return argv, nil end
  local cmd = {}
  for i, a in ipairs(argv) do cmd[i] = s:map_arg(a) end
  -- absolute host path outside the workspace (mason, ...): look it up by name in the container
  if type(cmd[1]) == "string" and cmd[1]:sub(1, 1) == "/" and cmd[1] == argv[1] then cmd[1] = vim.fs.basename(cmd[1]) end
  local cwd = opts.cwd and (s:remote_path(opts.cwd) or s.remote_folder) or nil
  return s:exec_argv(cmd, { tty = opts.tty, stdin = opts.stdin ~= false, cwd = cwd, env = opts.env }), s
end

--- Login shell of the remote user in the devcontainer of `opts.path` (default: current buffer),
--- for terminal plugins: `Snacks.terminal(require("devcontainer").shell_cmd())`.
---@param opts? { path?: string, cwd?: string }
---@return string[]? argv  nil when no devcontainer is attached
function M.shell_cmd(opts)
  opts = opts or {}
  local argv, s = M.wrap_cmd({ "/bin/sh", "-c", LOGIN_SHELL }, { path = opts.path, cwd = opts.cwd, tty = true })
  return s and argv or nil
end

function M.info()
  local lines = {}
  local project = require("devcontainer.project").describe()
  for _, s in vim.spairs(registry.by_key) do
    local clients = {}
    for _, c in ipairs(vim.lsp.get_clients()) do
      if c.config._devcontainer_key == s.key then clients[#clients + 1] = c.name end
    end
    local ports = vim.tbl_map(require("devcontainer.ports").describe, require("devcontainer.ports").list(s))
    vim.list_extend(lines, {
      ("%s  [%s, %s backend]"):format(s.name, s.key, s.backend),
      ("  %s -> %s%s"):format(s.local_folder, s.remote_folder, s.remote_user and (" as " .. s.remote_user) or ""),
      ("  LSP in container: %s"):format(#clients > 0 and table.concat(clients, ", ") or "-"),
      ("  ports: %s"):format(#ports > 0 and table.concat(ports, ", ") or "-"),
    })
  end
  if #lines == 0 then
    local root = spec.find_root(start_path())
    lines = { root and ("not attached; :Devcontainer up to start " .. root) or "no devcontainer config in this workspace" }
  end
  local profiles = require("devcontainer.profiles")
  local p = profiles.describe((profiles.current_scope()))
  if p.selected or #p.matched > 0 then
    table.insert(lines, ("profile: %s%s"):format(p.selected or "none",
      #p.matched > 0 and (" (matched: " .. table.concat(p.matched, ", ") .. ")") or ""))
  end
  if project then table.insert(lines, project) end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "devcontainer" })
end

--- Name of the devcontainer the current buffer belongs to ("" if none), for statuslines:
--- "name", "name [profile]" when a profile is selected, "name (starting)" while it starts.
---@param opts? { profile?: boolean }
function M.statusline(opts)
  local s = registry.current()
  if s then
    local profile = not (opts and opts.profile == false) and require("devcontainer.profiles").active_name(s.local_folder)
    return profile and ("%s [%s]"):format(s.name, profile) or s.name
  end
  if next(busy) == nil then return "" end
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" or path:match("^%a[%w+.-]*://") then path = vim.fn.getcwd() end
  local root = spec.find_root_cached(path)
  if root and busy[root] then return vim.fs.basename(root) .. " (starting)" end
  return ""
end

--- Select the profile of the current workspace: a name, "none", or nil to pick one.
---@param name? string
function M.profile(name)
  ensure_setup()
  local profiles = require("devcontainer.profiles")
  local scope, ws = profiles.current_scope()
  local defs = profiles.definitions(ws)

  local function apply(choice)
    local before = config.get(scope)
    profiles.set(scope, choice)
    local after = config.get(scope)
    -- manual choices (:Devcontainer select) would hide what the profile sets
    local ctx = require("devcontainer.project").detect()
    if ctx then
      for _, k in ipairs({ "preset", "build_type", "profile" }) do
        if ctx.state[k] ~= nil then ctx:set(k, nil) end
      end
    end
    log.info(("profile for %s: %s"):format(vim.fn.fnamemodify(scope, ":~"), choice or "default"))
    local s = registry.by_folder(scope)
    local lsp_changed = not vim.deep_equal(before.lsp, after.lsp)
    if not lsp_changed then
      -- servers following the build dir move to the new profile's database (if it's configured)
      require("devcontainer.lsp").refresh_compile_commands(scope)
    end
    if s then
      if lsp_changed then require("devcontainer.lsp").restart(s.local_folder) end
      for _, k in ipairs({ "devcontainer", "backend", "docker", "cli_up_args", "git", "dotfiles" }) do
        if not vim.deep_equal(before[k], after[k]) then
          log.warn("the profile changes container settings: run :Devcontainer rebuild to apply them")
          break
        end
      end
    end
    vim.api.nvim_exec_autocmds("User", {
      pattern = "DevcontainerProfileChanged",
      modeline = false,
      data = { scope = scope, profile = profiles.describe(scope).selected },
    })
    vim.cmd.redrawstatus({ bang = true })
  end

  if name then
    if name ~= "none" and not defs[name] then return log.warn("unknown profile " .. name) end
    return apply(name)
  end
  local info = profiles.describe(scope)
  local items = { { name = "none", desc = "no profile" } }
  for _, n in ipairs(profiles.names(ws)) do
    table.insert(items, { name = n, desc = defs[n].desc })
  end
  vim.ui.select(items, {
    prompt = "Profile for " .. vim.fn.fnamemodify(scope, ":~"),
    format_item = function(it)
      local mark = (it.name == info.selected or (it.name == "none" and not info.selected)) and "● " or "  "
      local auto = vim.tbl_contains(info.matched, it.name) and " (auto)" or ""
      return ("%s%s%s%s"):format(mark, it.name, auto, it.desc and ("  — " .. it.desc) or "")
    end,
  }, function(choice)
    if choice then apply(choice.name) end
  end)
end

--- Options that apply to `path` (default: the current workspace), profiles included.
---@param path? string
---@return devcontainer.Options
function M.options(path)
  return config.get(path or require("devcontainer.profiles").current_scope())
end

--- Define profiles at runtime, e.g. from a project's .nvim.lua (:help 'exrc').
function M.add_profiles(defs)
  require("devcontainer.profiles").add(defs)
end

--- Forget the remembered autostart answer for the current project.
function M.forget()
  local root = require("devcontainer.autostart").forget(start_path())
  if root then
    log.info("autostart choice for " .. root .. " forgotten")
  else
    log.warn("no devcontainer config in this workspace")
  end
end

-- project actions (CMake / Cargo) -------------------------------------------------------------

for _, action in ipairs({ "configure", "build", "run", "test", "clean", "debug" }) do
  M[action] = function(args)
    ensure_setup()
    require("devcontainer.project").action(action, args)
  end
end

--- Pick any action of the current project (clippy, fresh configure, ...).
function M.task()
  ensure_setup()
  require("devcontainer.project").pick_action()
end

--- Choose CMake preset / build type / cargo profile / run target.
function M.select()
  ensure_setup()
  require("devcontainer.project").select()
end

--- Session attached to `path` (defaults to the current buffer / cwd).
---@param path? string
---@return devcontainer.Session?
function M.get(path)
  if path then return registry.find(path) end
  return registry.current()
end

function M.dap_adapter(adapter_spec)
  return require("devcontainer.dap").adapter(adapter_spec)
end

function M.lsp_cmd(argv)
  return require("devcontainer.lsp").cmd(argv)
end

return M
