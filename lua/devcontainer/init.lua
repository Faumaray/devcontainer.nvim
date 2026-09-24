local async = require("devcontainer.async")
local config = require("devcontainer.config")
local log = require("devcontainer.log")
local registry = require("devcontainer.session")
local spec = require("devcontainer.spec")

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
  if config.options.stop_on_exit then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        for _, s in pairs(registry.by_key) do
          vim.system({ s.docker, "stop", s.container_id }, { detach = true })
        end
      end,
    })
  end
end

--- Is `:Devcontainer up` currently running for this workspace root?
function M.is_starting(root)
  return busy[root] == true
end

local function ensure_setup()
  if not did_setup then M.setup({}) end
end

local function pick_backend()
  local b = config.options.backend
  if b == "auto" then b = vim.fn.executable(config.options.cli) == 1 and "cli" or "docker" end
  return b, require("devcontainer.backend." .. b)
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
  local prefix = "devcontainer://" .. session.key .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.startswith(vim.api.nvim_buf_get_name(buf), prefix) and not vim.bo[buf].modified then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
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

  async.run(function()
    local configs = spec.list_configs(root)
    if #configs == 0 then error("no devcontainer.json in " .. root, 0) end
    local config_file = configs[1]
    if #configs > 1 then
      config_file = async.select(configs, {
        prompt = "Devcontainer configuration",
        format_item = function(p) return p:sub(#root + 2) end,
      })
      if not config_file then return end
    end
    local conf, remote_folder, explicit = spec.load(config_file, root)
    if not conf then error(remote_folder, 0) end

    local entries = {}
    local existing = registry.by_folder(root)
    if existing then
      if not opts.rebuild and existing.config_file == config_file and is_running(existing) then
        return log.info(("already attached to %s (%s)"):format(existing.name, existing.key))
      end
      entries = lsp.stop_clients(root, existing.key)
      M._teardown(existing)
    end

    local backend_name, backend = pick_backend()
    local name = conf.name or vim.fs.basename(root)
    log.info(("%s %s (%s backend, progress: :Devcontainer log)"):format(
      opts.rebuild and "rebuilding" or "starting", name, backend_name))

    local res = backend.up({
      local_folder = root,
      config_file = config_file,
      config = conf,
      remote_folder = remote_folder,
      explicit_remote_folder = explicit,
      docker = config.options.docker,
    }, { rebuild = opts.rebuild, no_cache = opts.no_cache })

    local session = registry.new({
      container_id = res.container_id,
      local_folder = root,
      remote_folder = res.remote_folder,
      remote_user = res.remote_user,
      docker = config.options.docker,
      backend = backend_name,
      config_file = config_file,
      config = res.config,
      name = res.config.name or name,
    })
    session:setup_env(res.config)
    -- one exec instead of one blocking `which` per server when the clients move in
    local bins = lsp.binaries(root)
    for _, e in ipairs(entries) do
      local cmd = lsp.host_cmd(e.config)
      if type(cmd) == "table" and type(cmd[1]) == "string" then vim.list_extend(bins, { cmd[1], vim.fs.basename(cmd[1]) }) end
    end
    table.insert(bins, config.options.project.debug.command[1])
    session:prefetch(bins)

    -- lifecycle hooks (the devcontainer CLI runs these itself)
    for _, hook in ipairs(res.hooks or {}) do
      for _, argv in ipairs(spec.commands(res.config[hook])) do
        log.info("running " .. hook)
        local r = async.system(session:exec_argv(argv), { text = true, stdout = stream, stderr = stream })
        if r.code ~= 0 then log.warn(("%s failed with exit code %d"):format(hook, r.code)) end
      end
    end

    registry.register(session)
    log.info(("attached to %s: %s -> %s"):format(session.name, root, session.remote_folder))
    lsp.restart(root, entries)

    -- postAttachCommand runs on every attach and is left to the tool, even with the CLI
    for _, argv in ipairs(spec.commands(res.config.postAttachCommand)) do
      vim.system(session:exec_argv(argv), { text = true, stdout = stream, stderr = stream })
    end
  end, function(err)
    busy[root] = nil
    if err then log.error("devcontainer: " .. tostring(err)) end
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
  vim.system({ s.docker, "stop", s.container_id }, { text = true }, function(res)
    if res.code ~= 0 then
      log.error("docker stop failed: " .. vim.trim(res.stderr or ""))
    else
      log.info(s.name .. " stopped")
    end
  end)
  lsp.start_clients(entries)
end

local LOGIN_SHELL = 'shell="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"; exec "${shell:-/bin/sh}" -l'

--- Open a terminal running `cmd` (or the user's login shell) in the container.
function M.exec(cmd)
  local dir = vim.fn.expand("%:p:h")
  registry.pick(function(s)
    if not s then return log.warn("no devcontainer attached — run :Devcontainer up") end
    local argv = (cmd and vim.trim(cmd) ~= "") and { "/bin/sh", "-lc", cmd } or { "/bin/sh", "-c", LOGIN_SHELL }
    local cwd = (dir ~= "" and s:remote_path(dir)) or s.remote_folder
    vim.cmd("botright new")
    vim.fn.jobstart(s:exec_argv(argv, { tty = true, cwd = cwd }), { term = true, cwd = s.local_folder })
    vim.cmd("startinsert")
  end, "Devcontainer")
end

function M.info()
  local lines = {}
  local project = require("devcontainer.project").describe()
  for _, s in vim.spairs(registry.by_key) do
    local clients = {}
    for _, c in ipairs(vim.lsp.get_clients()) do
      if c.config._devcontainer_key == s.key then clients[#clients + 1] = c.name end
    end
    vim.list_extend(lines, {
      ("%s  [%s, %s backend]"):format(s.name, s.key, s.backend),
      ("  %s -> %s%s"):format(s.local_folder, s.remote_folder, s.remote_user and (" as " .. s.remote_user) or ""),
      ("  LSP in container: %s"):format(#clients > 0 and table.concat(clients, ", ") or "-"),
    })
  end
  if #lines == 0 then
    local root = spec.find_root(start_path())
    lines = { root and ("not attached; :Devcontainer up to start " .. root) or "no devcontainer config in this workspace" }
  end
  if project then table.insert(lines, project) end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "devcontainer" })
end

--- Name of the devcontainer the current buffer belongs to ("" if none), for statuslines.
function M.statusline()
  local s = registry.current()
  if s then return s.name end
  if next(busy) == nil then return "" end
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" or path:match("^%a[%w+.-]*://") then path = vim.fn.getcwd() end
  local root = spec.find_root_cached(path)
  if root and busy[root] then return vim.fs.basename(root) .. " (starting)" end
  return ""
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
