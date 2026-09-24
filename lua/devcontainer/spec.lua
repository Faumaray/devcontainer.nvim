--- Locating and reading devcontainer.json.
local jsonc = require("devcontainer.jsonc")

local M = {}

function M.normalize_dir(p)
  p = vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
  return (p:gsub("(.)/+$", "%1"))
end

--- Workspace root = nearest folder with a devcontainer config (.devcontainer.json,
--- .devcontainer/devcontainer.json or .devcontainer/<name>/devcontainer.json). A .devcontainer/
--- folder without a config in it (just a Dockerfile, say) doesn't count.
function M.find_root(path)
  local root = vim.fs.root(path, function(name, dir)
    if name == ".devcontainer.json" then return true end
    return name == ".devcontainer" and #M.list_configs(dir) > 0
  end)
  return root and M.normalize_dir(root)
end

local root_cache = {}
local ROOT_CACHE_MS = 2000

--- find_root with a short-lived cache, for callers that run on every redraw (statuslines).
function M.find_root_cached(path)
  local now = vim.uv.now()
  local hit = root_cache[path]
  if hit and now - hit.time < ROOT_CACHE_MS then return hit.root or nil end
  local root = M.find_root(path)
  root_cache[path] = { root = root or false, time = now }
  return root
end

function M.clear_cache()
  root_cache = {}
end

function M.list_configs(root)
  local out = {}
  local function add(p)
    if vim.uv.fs_stat(p) then out[#out + 1] = p end
  end
  add(root .. "/.devcontainer/devcontainer.json")
  add(root .. "/.devcontainer.json")
  local dir = root .. "/.devcontainer"
  if vim.uv.fs_stat(dir) then
    local subdirs = {}
    for name, t in vim.fs.dir(dir) do
      if t == "directory" then subdirs[#subdirs + 1] = name end
    end
    table.sort(subdirs)
    for _, name in ipairs(subdirs) do
      add(("%s/%s/devcontainer.json"):format(dir, name))
    end
  end
  return out
end

--- Expand ${localWorkspaceFolder}, ${localEnv:X}, ${containerEnv:X}, ... in every string of `value`.
--- Unknown variables (or ones whose context isn't available yet) are left untouched.
function M.substitute(value, ctx)
  local function expand(s)
    return (s:gsub("%${([^}]+)}", function(expr)
      local kind, arg = expr:match("^(%w+):(.*)$")
      if not kind then kind, arg = expr, "" end
      if kind == "localWorkspaceFolder" then
        return ctx.local_folder
      elseif kind == "localWorkspaceFolderBasename" then
        return vim.fs.basename(ctx.local_folder)
      elseif kind == "containerWorkspaceFolder" then
        return ctx.remote_folder
      elseif kind == "containerWorkspaceFolderBasename" then
        return ctx.remote_folder and vim.fs.basename(ctx.remote_folder)
      elseif kind == "localEnv" or kind == "env" then
        local name, default = arg:match("^([^:]*):?(.*)$")
        return vim.env[name] or default
      elseif kind == "containerEnv" and ctx.container_env then
        local name, default = arg:match("^([^:]*):?(.*)$")
        return ctx.container_env[name] or default
      end
    end))
  end
  local function walk(v)
    if type(v) == "string" then return expand(v) end
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = walk(val) end
    return out
  end
  return walk(value)
end

--- @return table? config, string remote_folder_or_err, boolean explicit_remote_folder
function M.load(config_file, local_folder)
  local raw, err = jsonc.read_file(config_file)
  if not raw then return nil, err end
  if type(raw) ~= "table" then return nil, config_file .. ": expected a JSON object" end
  local ctx = { local_folder = local_folder }
  local explicit = type(raw.workspaceFolder) == "string"
  ctx.remote_folder = explicit and M.substitute(raw.workspaceFolder, ctx)
    or ("/workspaces/" .. vim.fs.basename(local_folder))
  return M.substitute(raw, ctx), ctx.remote_folder, explicit
end

--- Files that define the container: devcontainer.json, its Dockerfile, its compose files.
---@return string[]
function M.config_files(config_file, conf)
  local dir = vim.fs.dirname(config_file)
  local function abs(p) return vim.fs.normalize(p:sub(1, 1) == "/" and p or (dir .. "/" .. p)) end
  local files = { config_file }
  local build = type(conf.build) == "table" and conf.build or {}
  local dockerfile = build.dockerfile or conf.dockerFile
  if type(dockerfile) == "string" then table.insert(files, abs(dockerfile)) end
  local compose = conf.dockerComposeFile
  for _, f in ipairs(type(compose) == "string" and { compose } or type(compose) == "table" and compose or {}) do
    if type(f) == "string" then table.insert(files, abs(f)) end
  end
  return files
end

--- Hash of the files that define the container, to notice that it needs a rebuild.
function M.fingerprint(config_file, conf)
  local parts = {}
  for _, f in ipairs(M.config_files(config_file, conf)) do
    local fd = io.open(f, "rb")
    local data = fd and fd:read("*a") or ""
    if fd then fd:close() end
    parts[#parts + 1] = f .. "\31" .. data:gsub("%z", "")
  end
  return vim.fn.sha256(table.concat(parts, "\30")):sub(1, 16)
end

--- Lifecycle command (string | string[] | { name = cmd }) -> list of argv
function M.commands(cmd)
  if type(cmd) == "string" then return { { "/bin/sh", "-c", cmd } } end
  if type(cmd) ~= "table" then return {} end
  if vim.islist(cmd) then return #cmd > 0 and { cmd } or {} end
  local out = {}
  for _, c in vim.spairs(cmd) do vim.list_extend(out, M.commands(c)) end
  return out
end

return M
