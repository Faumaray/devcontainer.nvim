if vim.g.loaded_devcontainer then
  return
end
vim.g.loaded_devcontainer = true

local function dc() return require("devcontainer") end

local subcommands = {
  -- container
  up = function() dc().up() end,
  rebuild = function() dc().up({ rebuild = true }) end,
  stop = function() dc().stop() end,
  exec = function(args) dc().exec(args) end,
  shell = function() dc().exec() end,
  log = function() require("devcontainer.log").open() end,
  info = function() dc().info() end,
  forget = function() dc().forget() end,
  -- project (CMake / Cargo), in the container when attached
  configure = function(args) dc().configure(args) end,
  build = function(args) dc().build(args) end,
  run = function(args) dc().run(args) end,
  test = function(args) dc().test(args) end,
  clean = function(args) dc().clean(args) end,
  debug = function(args) dc().debug(args) end,
  task = function() dc().task() end,
  select = function() dc().select() end,
}

local with_target = { build = true, run = true, debug = true }

vim.api.nvim_create_user_command("Devcontainer", function(o)
  local sub, rest = o.args:match("^(%S+)%s*(.*)$")
  local fn = subcommands[sub or "info"]
  if not fn then
    return vim.notify("Devcontainer: unknown subcommand " .. sub, vim.log.levels.ERROR)
  end
  fn(rest)
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
    if #words == 3 and with_target[words[2]] then
      return require("devcontainer.project").complete_targets(arglead)
    end
    return {}
  end,
})
