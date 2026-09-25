--- Build systems: find the project around the current file, and run its actions (configure,
--- build, run, test, clean, debug, ...) in the devcontainer — or on the host when there is none.
local async = require("devcontainer.async")
local config = require("devcontainer.config")
local log = require("devcontainer.log")
local registry = require("devcontainer.session")
local runner = require("devcontainer.runner")
local store = require("devcontainer.store")

local M = {}

---@class devcontainer.ProjectAction
---@field name string
---@field desc string
---@field interactive? boolean  runs a program in a terminal (not offered as an overseer template)
---@field run fun(ctx: devcontainer.ProjectCtx, args: { target?: string, extra: string[], template?: boolean }): table[]?

---@class devcontainer.Provider
---@field name string
---@field detect fun(path: string, boundary?: string): string?        project root containing `path`
---@field actions devcontainer.ProjectAction[]
---@field executables fun(ctx: devcontainer.ProjectCtx): { name: string, path: string, cwd?: string }[]  (may yield)
---@field build_target fun(ctx: devcontainer.ProjectCtx, target: string): table[]
---@field targets? fun(ctx: devcontainer.ProjectCtx): string[]   cached names for completion (must not yield)
---@field settings? fun(ctx: devcontainer.ProjectCtx)              interactive configuration (may yield)
---@field describe? fun(ctx: devcontainer.ProjectCtx): string
---@field after? fun(ctx: devcontainer.ProjectCtx, action: string)  runs after a successful task
---@field compile_commands_dir? fun(ctx: devcontainer.ProjectCtx): string?  host dir of the active compile_commands.json

---@type devcontainer.Provider[]
M.providers = {}

---@param provider devcontainer.Provider
function M.register(provider)
  for i, p in ipairs(M.providers) do
    if p.name == provider.name then
      M.providers[i] = provider
      return
    end
  end
  table.insert(M.providers, provider)
end

M.register(require("devcontainer.project.cmake"))
M.register(require("devcontainer.project.cargo"))

---@class devcontainer.ProjectCtx
---@field root string                     host path of the project root
---@field provider devcontainer.Provider
---@field session? devcontainer.Session
---@field state table                     persisted choices (preset, profile, target, ...)
---@field options devcontainer.Options     options for this project (profiles applied)
---@field opts table                      options.project[provider]
---@field profile? string                 selected profile (see devcontainer.profiles)
local Ctx = {}
Ctx.__index = Ctx

--- Persist a choice for this project.
function Ctx:set(key, value)
  self.state[key] = value
  store.set(self.root, self.provider.name .. "." .. key, value)
end

--- Host path -> path where commands run (container path when attached).
function Ctx:exec_path(p)
  if not self.session then return p end
  return self.session:remote_path(p) or p
end

--- Path where commands run -> host path (nil when it only exists in the container).
function Ctx:host_path(p)
  if not self.session then return p end
  return self.session:local_path(p)
end

--- A task spec with the project defaults filled in.
function Ctx:task(t)
  t.cwd = t.cwd or self.root
  t.session = self.session or false
  local env = self.options and self.options.project.env
  if env and next(env) then t.env = vim.tbl_extend("force", {}, env, t.env or {}) end
  return t
end

--- Run a command where the project's commands run and wait for it (inside async.run).
function Ctx:system(cmd)
  local argv = runner.argv({ cmd = cmd, cwd = self.root, session = self.session or false })
  return async.system(argv, { cwd = self.root, text = true })
end

local function start_path()
  local name = vim.api.nvim_buf_get_name(0)
  local s = registry.find(name)
  if name:match("^devcontainer://") then return s and s.local_folder or vim.fn.getcwd() end
  if vim.bo.buftype == "" and name ~= "" then return vim.fs.dirname(name) end
  return vim.fn.getcwd()
end

local function inside(path, folder)
  return path == folder or path:sub(1, #folder + 1) == folder .. "/"
end

--- Where a command for `path` runs when nothing says otherwise: the root of its CMake / Cargo
--- project, else its git root (inside its devcontainer's workspace), else the workspace folder.
--- Host path; nil outside of any of them.
---@param path? string  file or directory (default: current file, else cwd)
---@return string?
function M.root_for(path)
  path = path or start_path()
  if vim.fn.isdirectory(path) == 0 then path = vim.fs.dirname(path) end
  local session = registry.find(path)
  local boundary = session and session.local_folder or vim.fs.root(path, ".git")
  local best
  for _, p in ipairs(M.providers) do
    local ok, root = pcall(p.detect, path, boundary)
    if ok and root and (not best or #root > #best) then best = root end
  end
  if best then return best end
  local git = vim.fs.root(path, ".git")
  if not session then return git end
  return git and inside(git, session.local_folder) and git or session.local_folder
end

--- Project around `path` (default: current file, else cwd).
---@return devcontainer.ProjectCtx?
function M.detect(path)
  path = path or start_path()
  local session = registry.find(path)
  local boundary = session and session.local_folder or vim.fs.root(path, ".git")
  local best
  for _, p in ipairs(M.providers) do
    local ok, root = pcall(p.detect, path, boundary)
    if ok and root and (not best or #root > #best.root) then best = { provider = p, root = root } end
  end
  if not best then return nil end
  best.session = registry.find(best.root)
  best.state = store.get(best.root)[best.provider.name] or {}
  best.options = config.get(best.root)
  best.opts = best.options.project[best.provider.name] or {}
  best.profile = require("devcontainer.profiles").describe(best.root).selected
  return setmetatable(best, Ctx)
end

--- Called by the runner / overseer component after a successful task.
function M.after(info)
  local provider
  for _, p in ipairs(M.providers) do
    if p.name == info.provider then provider = p end
  end
  if not (provider and provider.after) then return end
  local ctx = M.detect(info.root)
  if ctx and ctx.provider == provider then provider.after(ctx, info.action) end
end

--- Pick an executable target: by name, the remembered one, the only one, or ask.
function M.pick_executable(ctx, name)
  local exes = ctx.provider.executables(ctx)
  if #exes == 0 then error(("%s: no executable targets found (build the project first?)"):format(ctx.provider.name), 0) end
  local function find(n)
    for _, e in ipairs(exes) do
      if e.name == n then return e end
    end
  end
  if name then return find(name) or error(("%s: no executable target %q"):format(ctx.provider.name, name), 0) end
  local remembered = ctx.state.target and find(ctx.state.target)
  if remembered then return remembered end
  local choice = #exes == 1 and exes[1] or async.select(exes, {
    prompt = "Executable",
    format_item = function(e) return e.name end,
  })
  if not choice then return nil end
  ctx:set("target", choice.name)
  return choice
end

--- Launch configuration for nvim-dap, paths in host space (the DAP proxy maps them).
local function dap_config(ctx, exe, args)
  local dbg = ctx.options.project.debug
  local function host(p) return p and (ctx:host_path(p) or p) end
  return vim.tbl_extend("force", {
    type = dbg.adapter,
    request = "launch",
    name = ("%s (%s)"):format(exe.name, ctx.provider.name),
    program = host(exe.path),
    args = args,
    cwd = host(exe.cwd) or ctx.root,
  }, dbg.config or {})
end

local function ensure_adapter(dap, ctx)
  local dbg = ctx.options.project.debug
  if not dap.adapters[dbg.adapter] then
    dap.adapters[dbg.adapter] = require("devcontainer.dap").adapter({
      command = dbg.command[1],
      args = vim.list_slice(dbg.command, 2),
    })
  end
end

--- Build `target` and start it under nvim-dap.
function M.debug(ctx, args)
  local ok, dap = pcall(require, "dap")
  if not ok then error("nvim-dap is not installed", 0) end
  local exe = M.pick_executable(ctx, args.target)
  if not exe then return end
  local steps = ctx.provider.build_target(ctx, exe.name)
  table.insert(steps, function(cb)
    ensure_adapter(dap, ctx)
    dap.run(dap_config(ctx, exe, args.extra))
    cb(true)
  end)
  return steps
end

local CORE = { "configure", "build", "run", "test", "clean", "debug" }
M.core_actions = CORE

--- Split ":Devcontainer build app -- --flag" into { target = "app", extra = { "--flag" } }.
function M.parse_args(action, str)
  local words = vim.split(vim.trim(str or ""), "%s+", { trimempty = true })
  local args = { extra = {} }
  local takes_target = action == "build" or action == "run" or action == "debug"
  local after_dashes = false
  for _, w in ipairs(words) do
    if w == "--" and not after_dashes then
      after_dashes = true
    elseif takes_target and not after_dashes and not args.target and not w:match("^%-") then
      args.target = w
    else
      table.insert(args.extra, w)
    end
  end
  return args
end

local function find_action(ctx, name)
  for _, a in ipairs(ctx.provider.actions) do
    if a.name == name then return a end
  end
end

--- Run a project action by name.
function M.action(name, argstr)
  local ctx = M.detect()
  if not ctx then return log.warn("no CMake or Cargo project around " .. start_path()) end
  local args = M.parse_args(name, argstr)
  if (name == "run" or name == "debug") and #args.extra == 0 then
    args.extra = vim.deepcopy(ctx.options.project.run_args or {})
  end
  async.run(function()
    local steps
    if name == "debug" then
      steps = M.debug(ctx, args)
    else
      local action = find_action(ctx, name)
      if not action then error(("%s projects have no %q action"):format(ctx.provider.name, name), 0) end
      steps = action.run(ctx, args)
    end
    if steps and #steps > 0 then runner.run(steps) end
  end, function(err)
    if err then log.error(tostring(err)) end
  end)
end

--- Pick any action of the current project (including provider-specific ones like clippy).
function M.pick_action()
  local ctx = M.detect()
  if not ctx then return log.warn("no CMake or Cargo project found") end
  local items = vim.deepcopy(ctx.provider.actions)
  table.insert(items, { name = "debug", desc = "build and start the debugger (nvim-dap)" })
  table.insert(items, { name = "select", desc = "choose preset / build type / profile / target" })
  vim.ui.select(items, {
    prompt = ("%s project%s"):format(ctx.provider.name, ctx.session and (" in " .. ctx.session.name) or ""),
    format_item = function(a) return ("%-12s %s"):format(a.name, a.desc or "") end,
  }, function(choice)
    if not choice then return end
    if choice.name == "select" then return M.select() end
    M.action(choice.name, "")
  end)
end

--- Interactive settings of the current project.
function M.select()
  local ctx = M.detect()
  if not ctx then return log.warn("no CMake or Cargo project found") end
  if not ctx.provider.settings then return log.info(ctx.provider.name .. " has nothing to select") end
  async.run(function() ctx.provider.settings(ctx) end, function(err)
    if err then return log.error(tostring(err)) end
    -- another preset / build type: servers following the build dir move to its database
    require("devcontainer.lsp").refresh_compile_commands(ctx.root)
  end)
end

--- Host dir of the active compile_commands.json of the project around `path`, or nil.
function M.compile_commands_dir(path)
  local ctx = M.detect(path)
  if not (ctx and ctx.provider.compile_commands_dir) then return nil end
  local ok, dir = pcall(ctx.provider.compile_commands_dir, ctx)
  return ok and dir or nil, ctx
end

--- Target names for command-line completion.
function M.complete_targets(arglead)
  local ctx = M.detect()
  if not (ctx and ctx.provider.targets) then return {} end
  local ok, names = pcall(ctx.provider.targets, ctx)
  if not ok then return {} end
  return vim.tbl_filter(function(n) return vim.startswith(n, arglead) end, names)
end

--- One-line description for :Devcontainer info.
function M.describe()
  local ctx = M.detect()
  if not ctx then return nil end
  local where = ctx.session and ("in " .. ctx.session.name) or "on the host"
  local detail = ctx.provider.describe and ctx.provider.describe(ctx) or ""
  if ctx.profile then detail = ("profile %s%s"):format(ctx.profile, detail ~= "" and (", " .. detail) or "") end
  return ("%s project %s%s — runs %s"):format(ctx.provider.name, ctx.root, detail ~= "" and (" (" .. detail .. ")") or "", where)
end

return M
