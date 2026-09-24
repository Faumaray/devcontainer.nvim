--- Terminals for :Devcontainer shell / exec and interactive tasks (run): a split (builtin),
--- snacks.nvim's terminal or toggleterm.nvim, per `terminal.provider`.
local config = require("devcontainer.config")

local M = {}

---@class devcontainer.TerminalOpts
---@field cwd? string          host directory of the terminal process
---@field env? table<string,string>
---@field title? string
---@field height? integer      builtin split height (default: half the screen)
---@field on_exit? fun(code: integer)

local function shell_join(argv)
  return table.concat(vim.tbl_map(vim.fn.shellescape, argv), " ")
end

local providers = {}

function providers.builtin(argv, opts)
  vim.cmd(opts.height and ("botright %dnew"):format(opts.height) or "botright new")
  vim.fn.jobstart(argv, {
    term = true,
    cwd = opts.cwd,
    env = opts.env,
    on_exit = function(_, code)
      if opts.on_exit then opts.on_exit(code) end
    end,
  })
  vim.cmd.startinsert()
end

function providers.snacks(argv, opts)
  local term = Snacks.terminal.open(argv, {
    cwd = opts.cwd,
    env = opts.env,
    auto_close = false,
    start_insert = true,
    auto_insert = true,
    win = { title = opts.title },
  })
  if opts.on_exit and term and term.buf then
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = term.buf,
      once = true,
      callback = function() opts.on_exit(vim.v.event.status) end,
    })
  end
end

function providers.toggleterm(argv, opts)
  local Terminal = require("toggleterm.terminal").Terminal
  local cmd = shell_join(argv)
  if opts.env and next(opts.env) then
    local assignments = {}
    for k, v in vim.spairs(opts.env) do table.insert(assignments, vim.fn.shellescape(k .. "=" .. v)) end
    cmd = "env " .. table.concat(assignments, " ") .. " " .. cmd
  end
  Terminal:new({
    cmd = cmd,
    dir = opts.cwd,
    display_name = opts.title,
    close_on_exit = false,
    on_exit = function(_, _, code)
      if opts.on_exit then opts.on_exit(code or 0) end
    end,
  }):toggle()
end

--- Which provider is configured (falls back to the builtin one when the plugin is missing).
function M.provider()
  local p = config.options.terminal.provider
  if type(p) == "function" then return p end
  if p == "snacks" and not (rawget(_G, "Snacks") and Snacks.terminal) then return "builtin" end
  if p == "toggleterm" and not pcall(require, "toggleterm.terminal") then return "builtin" end
  return providers[p] and p or "builtin"
end

--- Open a terminal running `argv`.
---@param argv string[]
---@param opts? devcontainer.TerminalOpts
function M.open(argv, opts)
  opts = opts or {}
  local p = M.provider()
  if type(p) == "function" then return p(argv, opts) end
  return providers[p](argv, opts)
end

return M
