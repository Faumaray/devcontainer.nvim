--- Fallback backend talking to docker/podman directly. Handles `image` and `build`
--- based configs; features and docker compose need the devcontainer CLI.
local async = require("devcontainer.async")
local log = require("devcontainer.log")
local spec = require("devcontainer.spec")

local M = {}

local function stream(_, data) log.append(data) end

local JSON_OPTS = { luanil = { object = true, array = true } }

--- remoteUser/remoteEnv/... baked into images by the devcontainer tooling (mcr.microsoft.com/devcontainers/*)
local function image_metadata(docker, ref)
  local res = async.system({ docker, "inspect", "-f", '{{index .Config.Labels "devcontainer.metadata"}}', ref }, { text = true })
  if res.code ~= 0 then return {} end
  local ok, meta = pcall(vim.json.decode, vim.trim(res.stdout or ""), JSON_OPTS)
  if not ok or type(meta) ~= "table" then return {} end
  if not vim.islist(meta) then meta = { meta } end
  local merged = { remoteEnv = {} }
  for _, entry in ipairs(meta) do
    if type(entry) == "table" then
      merged.remoteUser = entry.remoteUser or merged.remoteUser
      merged.containerUser = entry.containerUser or merged.containerUser
      merged.userEnvProbe = entry.userEnvProbe or merged.userEnvProbe
      for k, v in pairs(entry.remoteEnv or {}) do merged.remoteEnv[k] = v end
    end
  end
  return merged
end

local function detect_remote_folder(docker, id, local_folder)
  local res = async.system({ docker, "inspect", "-f", "{{json .Mounts}}", id }, { text = true })
  if res.code ~= 0 then return end
  local ok, mounts = pcall(vim.json.decode, vim.trim(res.stdout or ""), JSON_OPTS)
  for _, m in ipairs(ok and type(mounts) == "table" and mounts or {}) do
    if m.Source == local_folder then return m.Destination end
  end
end

local function run_on_host(cmd, cwd)
  for _, argv in ipairs(spec.commands(cmd)) do
    local res = async.system(argv, { cwd = cwd, text = true, stdout = stream, stderr = stream })
    if res.code ~= 0 then error(("initializeCommand failed with exit code %d"):format(res.code), 0) end
  end
end

local function build_image(ctx, conf)
  local build = type(conf.build) == "table" and conf.build or {}
  local dockerfile = build.dockerfile or conf.dockerFile
  if not dockerfile then
    if not conf.image then error("devcontainer.json needs `image` or `build.dockerfile`", 0) end
    return conf.image
  end
  local dir = vim.fs.dirname(ctx.config_file)
  local function rel(p) return p:sub(1, 1) == "/" and p or (dir .. "/" .. p) end
  local slug = (vim.fs.basename(ctx.local_folder):lower():gsub("[^%w_.-]", "-"))
  local tag = ("nvim-devcontainer-%s-%s"):format(slug, vim.fn.sha256(ctx.config_file):sub(1, 8))
  local args = { ctx.docker, "build", "-f", rel(dockerfile), "-t", tag }
  for k, v in vim.spairs(build.args or {}) do vim.list_extend(args, { "--build-arg", k .. "=" .. tostring(v) }) end
  if build.target then vim.list_extend(args, { "--target", build.target }) end
  vim.list_extend(args, build.options or {})
  table.insert(args, rel(build.context or conf.context or "."))
  log.info("building image " .. tag .. " (progress: :Devcontainer log)")
  local res = async.system(args, { text = true, stdout = stream, stderr = stream })
  if res.code ~= 0 then error("docker build failed (see :Devcontainer log)", 0) end
  return tag
end

local function create(ctx, conf, image, labels)
  local args = { ctx.docker, "run", "-d", "--label", labels[1], "--label", labels[2] }
  local mount = conf.workspaceMount
    or ("type=bind,source=%s,target=%s"):format(ctx.local_folder, ctx.remote_folder)
  if mount ~= "" then vim.list_extend(args, { "--mount", mount }) end
  for k, v in vim.spairs(conf.containerEnv or {}) do vim.list_extend(args, { "-e", k .. "=" .. tostring(v) }) end
  for _, m in ipairs(conf.mounts or {}) do
    if type(m) == "table" then
      m = ("type=%s,source=%s,target=%s"):format(m.type or "bind", m.source, m.target)
    end
    vim.list_extend(args, { "--mount", m })
  end
  for _, port in ipairs(conf.forwardPorts or {}) do
    if type(port) == "number" then vim.list_extend(args, { "-p", ("127.0.0.1:%d:%d"):format(port, port) }) end
  end
  if conf.containerUser then vim.list_extend(args, { "-u", conf.containerUser }) end
  if conf.privileged then table.insert(args, "--privileged") end
  if conf.init then table.insert(args, "--init") end
  for _, cap in ipairs(conf.capAdd or {}) do vim.list_extend(args, { "--cap-add", cap }) end
  for _, opt in ipairs(conf.securityOpt or {}) do vim.list_extend(args, { "--security-opt", opt }) end
  vim.list_extend(args, conf.runArgs or {})
  if conf.overrideCommand ~= false then
    vim.list_extend(args, {
      "--entrypoint", "/bin/sh", image,
      "-c", "trap 'exit 0' TERM INT; while sleep 1000 & wait $!; do :; done",
    })
  else
    table.insert(args, image)
  end
  log.info("creating container from " .. image)
  local res = async.check(args, { text = true })
  return vim.trim(res.stdout)
end

function M.up(ctx, opts)
  local conf, docker = ctx.config, ctx.docker
  if conf.dockerComposeFile then
    error("docker compose devcontainers need the devcontainer CLI: npm install -g @devcontainers/cli", 0)
  end
  if type(conf.features) == "table" and next(conf.features) then
    log.warn("docker backend ignores `features` — install @devcontainers/cli for full spec support")
  end

  -- same labels as the devcontainer CLI / VS Code, so their containers are reused
  local labels = { "devcontainer.local_folder=" .. ctx.local_folder, "devcontainer.config_file=" .. ctx.config_file }
  local ps = async.check({
    docker, "ps", "-a", "--filter", "label=" .. labels[1], "--filter", "label=" .. labels[2],
    "--format", "{{.ID}} {{.State}}",
  }, { text = true })
  local id, state = vim.trim(ps.stdout or ""):match("^(%S+)%s+(%S+)")

  if id and opts.rebuild then
    log.info("removing container " .. id)
    async.check({ docker, "rm", "-f", id }, { text = true })
    id = nil
  end

  local hooks
  local remote_folder = ctx.remote_folder
  if not id then
    if conf.initializeCommand then run_on_host(conf.initializeCommand, ctx.local_folder) end
    id = create(ctx, conf, build_image(ctx, conf), labels)
    hooks = { "onCreateCommand", "updateContentCommand", "postCreateCommand", "postStartCommand" }
  else
    if state ~= "running" then
      log.info("starting container " .. id)
      async.check({ docker, "start", id }, { text = true })
      hooks = { "postStartCommand" }
    end
    if not ctx.explicit_remote_folder then
      remote_folder = detect_remote_folder(docker, id, ctx.local_folder) or remote_folder
    end
  end

  local merged = vim.tbl_deep_extend("force", image_metadata(docker, id), conf)
  return {
    container_id = id,
    remote_folder = remote_folder,
    remote_user = merged.remoteUser or merged.containerUser,
    config = merged,
    hooks = hooks,
  }
end

return M
