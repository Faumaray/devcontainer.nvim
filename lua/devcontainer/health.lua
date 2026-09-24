local M = {}

function M.check()
  local h = vim.health
  local o = require("devcontainer.config").options

  h.start("devcontainer.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.11 is required")
  end

  if vim.fn.executable(o.docker) == 1 then
    local res = vim.system({ o.docker, "version", "--format", "{{.Server.Version}}" }, { text = true }):wait(5000)
    if res.code == 0 then
      h.ok(("%s: server %s"):format(o.docker, vim.trim(res.stdout)))
    else
      h.error(("%s is installed but the daemon is not reachable: %s"):format(o.docker, vim.trim(res.stderr or "")),
        { "start the daemon", "make sure your user may talk to it (docker group / rootless socket)" })
    end
  else
    h.error(o.docker .. " not found in PATH")
  end

  if vim.fn.executable(o.cli) == 1 then
    local res = vim.system({ o.cli, "--version" }, { text = true }):wait(10000)
    h.ok(("devcontainer CLI %s (backend: %s)"):format(vim.trim(res.stdout or "?"), o.backend))
  else
    h.warn("devcontainer CLI not found: using the plain docker backend (no features, no docker compose)",
      { "npm install -g @devcontainers/cli" })
  end

  h.start("devcontainer.nvim: integrations")
  local function plugin(mod, file, name, what)
    if package.loaded[mod] or #vim.api.nvim_get_runtime_file(file, false) > 0 then
      h.ok(("%s found — %s"):format(name, what))
    else
      h.info(("%s not installed (%s)"):format(name, what))
    end
  end
  plugin("dap", "lua/dap.lua", "nvim-dap", ":Devcontainer debug, require('devcontainer').dap_adapter()")
  plugin("overseer", "lua/overseer/init.lua", "overseer.nvim", "project tasks run as overseer tasks; templates run in the container")
  plugin("lualine", "lua/lualine.lua", "lualine.nvim", "component: lualine_x = { 'devcontainer' }")
  plugin("rustaceanvim", "lua/rustaceanvim/init.lua", "rustaceanvim", "executor: require('devcontainer.integrations.rustaceanvim').executor")
  plugin("conform", "lua/conform/init.lua", "conform.nvim", "require('devcontainer.integrations.conform').setup()")
  plugin("lint", "lua/lint.lua", "nvim-lint", "require('devcontainer.integrations.lint').setup()")
  plugin("neotest", "lua/neotest/init.lua", "neotest", "default_strategy = 'devcontainer'")
  local runner = require("devcontainer.runner")
  h.info("project runner: " .. runner.backend())
  h.info("terminal: " .. tostring(require("devcontainer.terminal").provider()))
  h.info("progress: " .. tostring(require("devcontainer.progress").backend() or "off"))
  h.info("file picker: " .. require("devcontainer.picker").backend())

  local profiles = require("devcontainer.profiles")
  local scope, ws = profiles.current_scope()
  local names = profiles.names(ws)
  if #names > 0 then
    local p = profiles.describe(scope)
    h.start("devcontainer.nvim: profiles")
    h.info(("available: %s"):format(table.concat(names, ", ")))
    h.ok(("%s: %s%s"):format(vim.fn.fnamemodify(scope, ":~"), p.selected or "none",
      #p.matched > 0 and (" (matched: " .. table.concat(p.matched, ", ") .. ")") or ""))
  end

  local ctx = require("devcontainer.project").detect()
  if ctx then
    h.start("devcontainer.nvim: project")
    h.ok(require("devcontainer.project").describe())
    local tools = ctx.provider.name == "cmake" and { "cmake", "ctest" } or { "cargo", "rustc" }
    for _, tool in ipairs(tools) do
      local found = ctx.session and ctx.session:which(tool) or (not ctx.session and vim.fn.exepath(tool) ~= "" and vim.fn.exepath(tool))
      if found then
        h.ok(("%s: %s"):format(tool, found))
      else
        h.warn(("%s not found %s"):format(tool, ctx.session and ("in container " .. ctx.session.name) or "on the host"))
      end
    end
  end

  h.start("devcontainer.nvim: attached containers")
  local sessions = require("devcontainer.session").by_key
  if next(sessions) == nil then
    h.info("none")
  end
  local ports = require("devcontainer.ports")
  for _, s in vim.spairs(sessions) do
    h.ok(("%s (%s): %s -> %s"):format(s.name, s.key, s.local_folder, s.remote_folder))
    local relay
    for _, kind in ipairs(ports.RELAYS) do
      if not relay and s:which(kind) then relay = kind end
    end
    if relay then
      h.ok("port forwarding relay: " .. relay)
    else
      h.warn("no port forwarding relay in the container", { "install socat, bash, python3 or nc in the image" })
    end
    local fwd = vim.tbl_map(ports.describe, ports.list(s))
    if #fwd > 0 then h.info("ports: " .. table.concat(fwd, ", ")) end
    if s.ssh_agent then
      h.ok("SSH agent available in the container (SSH_AUTH_SOCK)")
    elseif s.ssh_agent == false then
      h.info("SSH agent not mounted in this container: rebuild it to get one (git.ssh_agent)")
    end
  end
end

return M
