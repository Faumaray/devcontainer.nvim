--- "Reopen in container?" — when a file or cwd inside a project with a devcontainer config is
--- opened, offer to start it. "Always" / "Never" answers are remembered per project.
local config = require("devcontainer.config")
local registry = require("devcontainer.session")
local spec = require("devcontainer.spec")
local store = require("devcontainer.store")

local M = {}

local handled = {} -- roots already asked/started in this Neovim session
local queue, prompting = {}, false

M.choices = {
  { label = "Start the devcontainer", action = "start" },
  { label = "Always start it for this project", action = "always" },
  { label = "Not now", action = "skip" },
  { label = "Never for this project", action = "never" },
}

local function start(root)
  require("devcontainer").up({ path = root, quiet = true })
end

local function next_prompt()
  if prompting then return end
  local root = table.remove(queue, 1)
  if not root then return end
  prompting = true
  local name = vim.fn.fnamemodify(root, ":~")
  vim.ui.select(M.choices, {
    prompt = ("Devcontainer configuration found in %s"):format(name),
    format_item = function(c) return c.label end,
    kind = "devcontainer.autostart",
  }, function(choice)
    prompting = false
    if choice then
      if choice.action == "always" or choice.action == "never" then store.set(root, "autostart", choice.action) end
      if choice.action == "start" or choice.action == "always" then start(root) end
    end
    vim.schedule(next_prompt)
  end)
end

--- Consider starting the devcontainer of the project containing `path`.
---@param opts? { force?: boolean }  force: also without an attached UI (tests)
function M.check(path, opts)
  opts = opts or {}
  local mode = config.options.autostart
  if mode == false or mode == nil then return end
  if not opts.force and #vim.api.nvim_list_uis() == 0 then return end
  local root = type(path) == "string" and path ~= "" and spec.find_root(path)
  if not root or handled[root] or registry.by_folder(root) or require("devcontainer").is_starting(root) then return end
  handled[root] = true

  local remembered = store.get(root).autostart
  if remembered == "never" then return end
  if mode == true or remembered == "always" then return start(root) end
  table.insert(queue, root)
  next_prompt()
end

--- Forget the remembered answer for the project of `path` (and ask again next time).
function M.forget(path)
  local root = spec.find_root(path)
  if not root then return nil end
  store.clear(root, "autostart")
  handled[root] = nil
  return root
end

local function check_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then return end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^%a[%w+.-]*://") then return end
  M.check(name)
end

function M.setup(group)
  local function startup()
    M.check(vim.fn.getcwd())
    check_buf(vim.api.nvim_get_current_buf())
  end
  -- UIEnter: after VimEnter, once a UI is attached (never fires for headless scripts)
  vim.api.nvim_create_autocmd("UIEnter", {
    group = group,
    callback = function() vim.schedule(startup) end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      if vim.v.vim_did_enter == 1 then vim.schedule(function() check_buf(ev.buf) end) end
    end,
  })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function() vim.schedule(function() M.check(vim.fn.getcwd()) end) end,
  })
  -- set up after startup (lazy-loaded plugin): look at the current state right away
  if vim.v.vim_did_enter == 1 then vim.schedule(startup) end
end

function M._reset()
  handled, queue, prompting = {}, {}, false
end

return M
