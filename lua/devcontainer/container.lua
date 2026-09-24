--- docker/podman operations on an attached container. Containers of a docker compose
--- devcontainer are handled as the whole compose project (stop / down), like VS Code does.
local async = require("devcontainer.async")
local log = require("devcontainer.log")

local M = {}

local JSON_OPTS = { luanil = { object = true, array = true } }

--- Read labels, published ports and mounts of the session's container. Runs inside async.run.
---@param s devcontainer.Session
function M.inspect(s)
  local res = async.system({ s.docker, "inspect", s.container_id }, { text = true })
  local ok, data = pcall(vim.json.decode, vim.trim(res.stdout or ""), JSON_OPTS)
  local info = ok and type(data) == "table" and type(data[1]) == "table" and data[1] or {}
  local labels = type(info.Config) == "table" and type(info.Config.Labels) == "table" and info.Config.Labels or {}
  s.compose_project = labels["com.docker.compose.project"]
  s.published = {} -- container port -> host port
  local ports = type(info.NetworkSettings) == "table" and info.NetworkSettings.Ports or nil
  for key, binds in pairs(type(ports) == "table" and ports or {}) do
    local port = tonumber(tostring(key):match("^(%d+)/tcp$"))
    local host = port and type(binds) == "table" and type(binds[1]) == "table" and tonumber(binds[1].HostPort)
    if host then s.published[port] = host end
  end
  s.mounts = type(info.Mounts) == "table" and info.Mounts or {}
end

--- Ids of the containers VS Code / the CLI / this plugin created for a workspace config
--- (running or not). Runs inside async.run.
function M.find(docker, local_folder, config_file)
  local res = async.system({
    docker, "ps", "-aq",
    "--filter", "label=devcontainer.local_folder=" .. local_folder,
    "--filter", "label=devcontainer.config_file=" .. config_file,
  }, { text = true })
  if res.code ~= 0 then return {} end
  return vim.split(vim.trim(res.stdout or ""), "%s+", { trimempty = true })
end

local function compose_ids(s)
  local res = async.system({ s.docker, "ps", "-aq", "--filter", "label=com.docker.compose.project=" .. s.compose_project }, { text = true })
  local ids = res.code == 0 and vim.split(vim.trim(res.stdout or ""), "%s+", { trimempty = true }) or {}
  return #ids > 0 and ids or { s.container_id }
end

--- `docker compose -p <project> <sub>`, falling back to `docker <fallback> <ids>` when the
--- compose plugin isn't there (podman without podman-compose, ...).
local function compose_or(s, sub, fallback)
  local r = async.system({ s.docker, "compose", "-p", s.compose_project, sub }, { text = true })
  if r.code == 0 then return end
  async.check(vim.list_extend(vim.list_extend({ s.docker }, fallback), compose_ids(s)), { text = true })
end

--- Stop the container (the compose project for compose devcontainers).
---@param done? fun(err?: string)
function M.stop(s, done)
  async.run(function()
    if s.compose_project then
      compose_or(s, "stop", { "stop" })
    else
      async.check({ s.docker, "stop", s.container_id }, { text = true })
    end
  end, done)
end

--- Remove the container (`docker compose down` for compose devcontainers).
---@param done? fun(err?: string)
function M.remove(s, done)
  async.run(function()
    if s.compose_project then
      compose_or(s, "down", { "rm", "-f" })
    else
      async.check({ s.docker, "rm", "-f", s.container_id }, { text = true })
    end
  end, done)
end

--- Stop on Neovim exit (stop_on_exit), honouring `shutdownAction: "none"`. Fire and forget.
function M.stop_detached(s)
  if type(s.config) == "table" and s.config.shutdownAction == "none" then return end
  local cmd = s.compose_project and { s.docker, "compose", "-p", s.compose_project, "stop" }
    or { s.docker, "stop", s.container_id }
  local ok, err = pcall(vim.system, cmd, { detach = true })
  if not ok then log.append("stop on exit: " .. tostring(err)) end
end

return M
