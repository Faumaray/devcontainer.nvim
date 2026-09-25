--- nvim-lint: run linters inside the devcontainer of the buffer (clang-tidy, ruff, mypy, eslint,
--- ... installed in the image). Container paths in their output are mapped back to host paths
--- before nvim-lint's parser sees them.
---
---   require("lint").linters_by_ft = { python = { "ruff", "mypy" } }
---   require("devcontainer.integrations.lint").setup()   -- after setting linters_by_ft
---
--- or per linter:  require("lint").linters.mypy = require("devcontainer.integrations.lint").wrap("mypy")
local log = require("devcontainer.log")
local paths = require("devcontainer.paths")
local registry = require("devcontainer.session")

local M = {}

local wrappers = setmetatable({}, { __mode = "k" })
local warned = {}

local function to_host(session, s)
  if type(s) ~= "string" then return s end
  return paths.replace_root(s, session.remote_folder, session.local_folder)
end

--- The linter's parser, fed with host paths.
local function wrap_parser(parser, session)
  if type(parser) == "function" then
    return function(output, bufnr, cwd) return parser(to_host(session, output), bufnr, cwd) end
  end
  if type(parser) == "table" and parser.on_chunk then
    local wrapped = setmetatable({}, { __index = parser })
    wrapped.on_chunk = function(chunk, ...) return parser.on_chunk(to_host(session, chunk), ...) end
    return wrapped
  end
  return parser
end

--- A linter definition that runs `base` in `session` for the current buffer.
function M.in_container(session, name, base)
  local cmd = base.cmd
  if type(cmd) == "function" then cmd = cmd() end
  if type(cmd) ~= "string" then return nil end
  local exe = session:which(cmd) or (cmd:find("/", 1, true) and session:which(vim.fs.basename(cmd))) or nil
  if not exe then
    if not warned[session.key .. name] then
      warned[session.key .. name] = true
      log.warn(("%s not found in container %s — linting on the host"):format(cmd, session.name))
    end
    return nil
  end
  local inner = { exe }
  for _, a in ipairs(base.args or {}) do
    if type(a) == "function" then a = a() end
    inner[#inner + 1] = session:map_arg(a)
  end
  if not base.stdin and base.append_fname ~= false then
    inner[#inner + 1] = session:map_arg(vim.api.nvim_buf_get_name(0))
  end
  -- the linter's own cwd, else its project's root (not Neovim's cwd: a subfolder, or none of the container)
  local host_cwd = base.cwd or require("devcontainer.project").root_for(vim.api.nvim_buf_get_name(0)) or vim.fn.getcwd()
  local argv = session:exec_argv(inner, {
    stdin = true,
    cwd = session:remote_path(host_cwd) or session.remote_folder,
    env = base.env,
  })
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  out.name = base.name or name
  out.cmd = argv[1]
  out.args = vim.list_slice(argv, 2)
  out.append_fname = false
  out.env = nil
  out.cwd = host_cwd -- what the parser resolves relative file names against
  out.parser = wrap_parser(base.parser, session)
  return out
end

--- Value for `lint.linters[name]`: resolved when linting, in the buffer's devcontainer.
---@param name string
---@param original? table|function  the linter definition (default: lint.linters[name])
function M.wrap(name, original)
  if original == nil then original = require("lint").linters[name] end
  if wrappers[original] then return original end
  local fn = function()
    local base = original
    if type(base) == "function" then base = base() end
    if type(base) ~= "table" then return base end
    local path = vim.api.nvim_buf_get_name(0)
    local session = path ~= "" and not path:match("^%a[%w+.-]*://") and registry.find(path) or nil
    return session and M.in_container(session, name, base) or base
  end
  wrappers[fn] = true
  return fn
end

--- Wrap linters: every one in `linters_by_ft` ("*", the default) or the given list, minus `exclude`.
---@param opts? { linters?: "*"|string[], exclude?: string[] }
function M.setup(opts)
  opts = opts or {}
  local lint = require("lint")
  local names = {}
  if opts.linters == nil or opts.linters == "*" then
    for _, list in pairs(lint.linters_by_ft or {}) do
      for _, n in ipairs(type(list) == "table" and list or {}) do names[n] = true end
    end
  else
    for _, n in ipairs(opts.linters) do names[n] = true end
  end
  for _, n in ipairs(opts.exclude or {}) do names[n] = nil end
  for name in pairs(names) do
    local ok, original = pcall(function() return lint.linters[name] end)
    if ok and original then lint.linters[name] = M.wrap(name, original) end
  end
end

return M
