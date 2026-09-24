if vim.g.loaded_devcontainer then
  return
end
vim.g.loaded_devcontainer = true

local function dc() return require("devcontainer") end
local function targets(arglead) return require("devcontainer.project").complete_targets(arglead) end

---@type table<string, { fn: fun(args: string), complete?: fun(arglead: string, words: string[]): string[] }>
local subcommands = {
  -- container
  up = { fn = function() dc().up() end },
  rebuild = {
    fn = function(args) dc().rebuild({ no_cache = args:find("--no-cache", 1, true) ~= nil }) end,
    complete = function() return { "--no-cache" } end,
  },
  stop = { fn = function() dc().stop() end },
  down = { fn = function() dc().down() end },
  config = { fn = function() dc().open_config() end },
  ports = { fn = function() dc().ports() end },
  forward = {
    fn = function(args) dc().forward(args) end,
    complete = function()
      local s = dc().get()
      return s and vim.tbl_map(function(p) return p.host == "localhost" and tostring(p.port) or (p.host .. ":" .. p.port) end,
        require("devcontainer.ports").parse(s.config or {})) or {}
    end,
  },
  unforward = {
    fn = function(args) dc().unforward(args) end,
    complete = function()
      local s = dc().get()
      return s and vim.tbl_map(function(f) return tostring(f.port) end, require("devcontainer.ports").list(s)) or {}
    end,
  },
  exec = { fn = function(args) dc().exec(args) end },
  shell = { fn = function() dc().exec() end },
  log = { fn = function() require("devcontainer.log").open() end },
  info = { fn = function() dc().info() end },
  forget = { fn = function() dc().forget() end },
  profile = {
    fn = function(args) dc().profile(args ~= "" and vim.trim(args) or nil) end,
    complete = function()
      local profiles = require("devcontainer.profiles")
      local _, ws = profiles.current_scope()
      return vim.list_extend({ "none" }, profiles.names(ws))
    end,
  },
  -- project (CMake / Cargo), in the container when attached
  configure = { fn = function(args) dc().configure(args) end },
  build = { fn = function(args) dc().build(args) end, complete = targets },
  run = { fn = function(args) dc().run(args) end, complete = targets },
  test = { fn = function(args) dc().test(args) end },
  clean = { fn = function(args) dc().clean(args) end },
  debug = { fn = function(args) dc().debug(args) end, complete = targets },
  task = { fn = function() dc().task() end },
  select = { fn = function() dc().select() end },
}

vim.api.nvim_create_user_command("Devcontainer", function(o)
  local sub, rest = o.args:match("^(%S+)%s*(.*)$")
  local cmd = subcommands[sub or "info"]
  if not cmd then
    return vim.notify("Devcontainer: unknown subcommand " .. sub, vim.log.levels.ERROR)
  end
  cmd.fn(rest or "")
end, {
  nargs = "*",
  desc = "Devcontainer and project (CMake/Cargo) commands",
  complete = function(arglead, cmdline)
    local words = vim.split(cmdline, "%s+")
    if #words == 2 then
      local names = vim.tbl_keys(subcommands)
      table.sort(names)
      return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, names)
    end
    local cmd = subcommands[words[2]]
    if #words == 3 and cmd and cmd.complete then
      return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, cmd.complete(arglead, words))
    end
    return {}
  end,
})
