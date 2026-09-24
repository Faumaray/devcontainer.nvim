--- Backend using the reference implementation: https://github.com/devcontainers/cli
--- Supports the full spec (features, docker compose, UID remapping, lifecycle hooks).
local async = require("devcontainer.async")
local log = require("devcontainer.log")

local M = {}

local JSON_OPTS = { luanil = { object = true, array = true } }

local function last_json(s)
  local found
  for line in vim.gsplit(s or "", "\n", { plain = true }) do
    line = vim.trim(line)
    if line:sub(1, 1) == "{" then
      local ok, v = pcall(vim.json.decode, line, JSON_OPTS)
      if ok and type(v) == "table" then found = v end
    end
  end
  if not found then
    local ok, v = pcall(vim.json.decode, vim.trim(s or ""), JSON_OPTS)
    found = ok and type(v) == "table" and v or nil
  end
  return found
end

function M.up(ctx, opts)
  local o = require("devcontainer.config").options
  local common = { "--workspace-folder", ctx.local_folder, "--config", ctx.config_file }
  if ctx.docker ~= "docker" then vim.list_extend(common, { "--docker-path", ctx.docker }) end

  local args = vim.list_extend({ o.cli, "up" }, common)
  if opts.rebuild then table.insert(args, "--remove-existing-container") end
  vim.list_extend(args, o.cli_up_args or {})

  local out = {}
  local res = async.system(args, {
    text = true,
    stdout = function(_, data)
      if data then
        out[#out + 1] = data
        log.append(data)
      end
    end,
    stderr = function(_, data) log.append(data) end,
  })
  local result = last_json(table.concat(out))
  if res.code ~= 0 or not result or result.outcome ~= "success" then
    local why = result and (result.message or result.description)
    error("`devcontainer up` failed" .. (why and (": " .. why) or "") .. " (see :Devcontainer log)", 0)
  end

  -- merged config = devcontainer.json + features + image metadata (remoteEnv, userEnvProbe, ...)
  local merged
  local rc = async.system(vim.list_extend({
    o.cli, "read-configuration", "--container-id", result.containerId, "--include-merged-configuration",
  }, common), { text = true })
  if rc.code == 0 then
    local decoded = last_json(rc.stdout)
    merged = decoded and (decoded.mergedConfiguration or decoded.configuration)
  end

  return {
    container_id = result.containerId,
    remote_user = result.remoteUser,
    remote_folder = result.remoteWorkspaceFolder or ctx.remote_folder,
    config = merged or ctx.config,
    -- lifecycle hooks are run by the CLI itself
  }
end

return M
