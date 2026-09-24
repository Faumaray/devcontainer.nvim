--- conform.nvim: run formatters inside the devcontainer of the buffer (clang-format, rustfmt,
--- ruff, prettier, ... installed in the image, not on the host).
---
---   require("conform").setup({ formatters_by_ft = { cpp = { "clang_format" }, python = { "ruff_format" } } })
---   require("devcontainer.integrations.conform").setup()   -- after conform.setup()
---
--- or per formatter:  require("conform").formatters.clang_format = require("devcontainer.integrations.conform").wrap("clang_format")
---
--- Outside an attached workspace the formatter runs on the host as usual.
local log = require("devcontainer.log")
local registry = require("devcontainer.session")

local M = {}

local wrappers = setmetatable({}, { __mode = "k" }) -- our functions, to avoid wrapping twice
local warned = {}

local function session_of(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%a[%w+.-]*://") then return nil end
  return registry.find(name)
end

--- Built-in definition + the user's override, the way conform itself combines them.
local function base_config(name, override)
  if override and override.inherit == false then return override end
  local parent = type(override) == "table" and type(override.inherit) == "string" and override.inherit or name
  local ok, builtin = pcall(require, "conform.formatters." .. parent)
  if ok and type(builtin) == "table" then
    return override and require("conform.util").merge_formatter_configs(builtin, override) or builtin
  end
  return override
end

local function resolve(session, command)
  if type(command) ~= "string" then return nil end
  return session:which(command) or (command:find("/", 1, true) and session:which(vim.fs.basename(command))) or nil
end

local function relative(dir, file)
  if dir and vim.startswith(file, dir .. "/") then return file:sub(#dir + 2) end
  return file
end

--- conform args for `docker exec ... <formatter> <args>` (conform prepends the docker binary).
local function exec_args(session, base, ctx, args)
  local command = base.command
  if type(command) == "function" then command = command(base, ctx) end
  command = resolve(session, command) or session:map_arg(command)
  if type(args) == "function" then args = args(base, ctx) end
  local env = base.env
  if type(env) == "function" then env = env(base, ctx) end
  local host_cwd = base.cwd and base.cwd(base, ctx) or vim.fn.getcwd()
  local values = {
    FILENAME = session:remote_path(ctx.filename) or ctx.filename,
    DIRNAME = session:remote_path(ctx.dirname) or ctx.dirname,
    RELATIVE_FILEPATH = relative(host_cwd, ctx.filename),
    EXTENSION = ctx.filename:match(".*(%..*)$") or "",
  }
  local function subst(v)
    if type(v) ~= "string" then return v end
    v = v:gsub("%$(%u[%u_]*)", function(k) return values[k] end)
    return session:map_arg(v)
  end
  local inner
  if type(args) == "string" then
    inner = { "/bin/sh", "-c", command .. " " .. subst(args) }
  else
    inner = { command }
    for _, a in ipairs(args or {}) do inner[#inner + 1] = subst(a) end
  end
  local argv = session:exec_argv(inner, {
    stdin = true,
    cwd = host_cwd and session:remote_path(host_cwd) or session.remote_folder,
    env = env,
  })
  return vim.list_slice(argv, 2)
end

--- A complete formatter config that runs `base` in `session`.
function M.in_container(session, name, base)
  if base.format or not base.command then return nil end -- Lua formatters stay in Neovim
  if type(base.command) == "string" and not resolve(session, base.command) then
    if not warned[session.key .. name] then
      warned[session.key .. name] = true
      log.warn(("%s not found in container %s — formatting on the host"):format(base.command, session.name))
    end
    return nil
  end
  local cfg = {}
  for k, v in pairs(base) do cfg[k] = v end
  cfg.inherit = false
  cfg.command = session.docker
  cfg.env = nil
  cfg.prepend_args, cfg.append_args = nil, nil
  cfg.args = function(_, ctx) return exec_args(session, base, ctx, base.args) end
  if base.range_args then
    cfg.range_args = function(_, ctx) return exec_args(session, base, ctx, base.range_args) end
  end
  return cfg
end

--- Value for `conform.formatters[name]`: runs the formatter in the buffer's devcontainer.
---@param name string
---@param original? table|function  the existing override (default: conform.formatters[name])
function M.wrap(name, original)
  if original == nil then original = require("conform").formatters[name] end
  if wrappers[original] then return original end
  local fn = function(bufnr)
    local override = original
    if type(override) == "function" then override = override(bufnr) end
    local base = base_config(name, override)
    if type(base) ~= "table" then return override end
    local session = session_of(bufnr)
    local cfg = session and M.in_container(session, name, base)
    if cfg then return cfg end
    -- on the host: the same definition conform would have used
    return vim.tbl_extend("force", {}, base, { inherit = false })
  end
  wrappers[fn] = true
  return fn
end

local function collect(list, out)
  if type(list) ~= "table" then return end
  for _, v in ipairs(list) do
    if type(v) == "string" then
      out[v] = true
    elseif type(v) == "table" then
      collect(v, out)
    end
  end
end

--- Wrap formatters: every one named in `formatters_by_ft` and `conform.formatters` ("*", the
--- default) or the given list, minus `exclude`.
---@param opts? { formatters?: "*"|string[], exclude?: string[] }
function M.setup(opts)
  opts = opts or {}
  local conform = require("conform")
  local names = {}
  if opts.formatters == nil or opts.formatters == "*" then
    for _, list in pairs(conform.formatters_by_ft or {}) do collect(list, names) end
    for name in pairs(conform.formatters or {}) do names[name] = true end
  else
    for _, n in ipairs(opts.formatters) do names[n] = true end
  end
  for _, n in ipairs(opts.exclude or {}) do names[n] = nil end
  for name in pairs(names) do
    conform.formatters[name] = M.wrap(name, conform.formatters[name])
  end
end

return M
