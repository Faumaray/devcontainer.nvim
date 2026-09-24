--- A running devcontainer attached to a host workspace folder, plus the registry of them.
local async = require("devcontainer.async")
local paths = require("devcontainer.paths")
local spec = require("devcontainer.spec")

local M = { by_key = {} }

---@class devcontainer.Session
---@field key string              short container id, used in devcontainer:// URIs
---@field name string
---@field container_id string
---@field local_folder string
---@field local_roots string[]
---@field remote_folder string
---@field remote_user? string
---@field docker string
---@field backend string
---@field env table<string,string>
---@field lsp devcontainer.Translator
---@field dap devcontainer.Translator
---@field lsp_clients table<integer,true>
local Session = {}
Session.__index = Session

local PROBE_MARKER = "__NVIM_DEVCONTAINER_ENV__"
local SKIP_ENV = { _ = true, PWD = true, OLDPWD = true, SHLVL = true, HOSTNAME = true, TERM = true, PS1 = true, PS2 = true }

function M.new(o)
  local self = setmetatable(o, Session)
  self.remote_folder = self.remote_folder:gsub("(.)/+$", "%1")
  self.key = o.container_id:sub(1, 12)
  self.name = o.name or vim.fs.basename(o.local_folder)
  self.local_roots = { o.local_folder }
  local real = vim.uv.fs_realpath(o.local_folder)
  if real and real ~= o.local_folder then table.insert(self.local_roots, real) end
  self.env = {}
  self.lsp_clients = {}
  self.warned = {}
  self._which = {}
  self.lsp = paths.new({ local_roots = self.local_roots, remote_root = self.remote_folder, scheme = "devcontainer://" .. self.key })
  self.dap = paths.new({ local_roots = self.local_roots, remote_root = self.remote_folder })
  return self
end

--- argv for `docker exec` into this container.
---@param cmd string[]
---@param opts? { tty?: boolean, stdin?: boolean, cwd?: string, env?: table<string,string>|false, user?: string }
function Session:exec_argv(cmd, opts)
  opts = opts or {}
  local argv = { self.docker, "exec" }
  if opts.tty then
    table.insert(argv, "-it")
  elseif opts.stdin then
    table.insert(argv, "-i")
  end
  local user = opts.user or self.remote_user
  if user and user ~= "" then vim.list_extend(argv, { "-u", user }) end
  vim.list_extend(argv, { "-w", opts.cwd or self.remote_folder })
  if opts.env ~= false then
    local env = vim.tbl_extend("force", {}, self.env, opts.env or {})
    for k, v in vim.spairs(env) do
      vim.list_extend(argv, { "-e", k .. "=" .. tostring(v) })
    end
  end
  table.insert(argv, self.container_id)
  vim.list_extend(argv, cmd)
  return argv
end

function Session:remote_path(p) return self.dap:path_to_remote(p) end
function Session:local_path(p) return self.dap:path_to_local(p) end

--- Rewrite host workspace paths inside an argument (--compile-commands-dir=/home/me/proj/build,
--- "cd /home/me/proj && make") to container paths.
function Session:map_arg(arg)
  if type(arg) ~= "string" then return arg end
  for _, root in ipairs(self.local_roots) do
    arg = paths.replace_root(arg, root, self.remote_folder)
  end
  return arg
end

--- Capture the environment a login/interactive shell of the remote user would have
--- (VS Code's userEnvProbe). Runs inside async.run.
function Session:probe_env(mode)
  local flags = ({ loginShell = "-lc", interactiveShell = "-ic", loginInteractiveShell = "-lic" })[mode]
  local script = "printf '" .. PROBE_MARKER .. "'; env -0 2>/dev/null || env"
  local cmd = { "/bin/sh", "-c", script }
  if flags then
    local sh_flags = flags:gsub("i", "")
    cmd = {
      "/bin/sh", "-c",
      ('if command -v bash >/dev/null 2>&1; then exec bash %s "$0"; else exec /bin/sh %s "$0"; fi'):format(flags, sh_flags),
      script,
    }
  end
  local res = async.system(self:exec_argv(cmd, { env = false }), { text = true })
  local out = res.stdout or ""
  local pos = out:find(PROBE_MARKER, 1, true)
  if not pos then return nil end
  out = out:sub(pos + #PROBE_MARKER)
  local sep = out:find("\0", 1, true) and "\0" or "\n"
  local env = {}
  for _, entry in ipairs(vim.split(out, sep, { plain = true, trimempty = true })) do
    local k, v = entry:match("^([%a_][%w_]*)=(.*)$")
    if k and not SKIP_ENV[k] then env[k] = v end
  end
  return env
end

--- Probe env + apply remoteEnv. Runs inside async.run.
function Session:setup_env(conf)
  local mode = require("devcontainer.config").options.user_env_probe or conf.userEnvProbe or "loginInteractiveShell"
  local env = (mode ~= "none" and self:probe_env(mode)) or self:probe_env(nil) or {}
  local remote_env = spec.substitute(conf.remoteEnv or {}, {
    local_folder = self.local_folder,
    remote_folder = self.remote_folder,
    container_env = env,
  })
  for k, v in pairs(remote_env) do
    if type(v) == "string" then env[k] = v end
  end
  self.env = env
end

--- Resolve an executable inside the container (cached). Synchronous.
function Session:which(bin)
  if self._which[bin] == nil then
    local res = vim.system(self:exec_argv({ "/bin/sh", "-c", 'command -v "$1"', "sh", bin }), { text = true }):wait(10000)
    local path = res.code == 0 and vim.trim(res.stdout or "") or ""
    self._which[bin] = path ~= "" and path or false
  end
  return self._which[bin] or nil
end

--- Resolve several executables with a single `docker exec` so that later `which` calls are
--- answered from the cache. Runs inside async.run.
---@param bins string[]
function Session:prefetch(bins)
  local todo, seen = {}, {}
  for _, b in ipairs(bins) do
    if type(b) == "string" and b ~= "" and self._which[b] == nil and not seen[b] then
      seen[b] = true
      todo[#todo + 1] = b
    end
  end
  if #todo == 0 then return end
  local script = 'for b; do printf "%s\\t%s\\n" "$b" "$(command -v "$b" 2>/dev/null)"; done'
  local res = async.system(self:exec_argv(vim.list_extend({ "/bin/sh", "-c", script, "sh" }, todo)), { text = true })
  if res.code ~= 0 then return end
  for line in vim.gsplit(res.stdout or "", "\n", { plain = true }) do
    local bin, path = line:match("^([^\t]+)\t(.*)$")
    if bin and seen[bin] then self._which[bin] = path ~= "" and path or false end
  end
end

-- registry -------------------------------------------------------------------

function M.register(s) M.by_key[s.key] = s end
function M.unregister(s) M.by_key[s.key] = nil end

function M.by_folder(folder)
  for _, s in pairs(M.by_key) do
    if s.local_folder == folder then return s end
  end
end

--- Session whose workspace contains `path` (deepest match wins). Accepts devcontainer:// names.
---@return devcontainer.Session?
function M.find(path)
  if type(path) ~= "string" or path == "" then return end
  local key = path:match("^devcontainer://([^/]+)")
  if key then return M.by_key[key] end
  local best, best_len
  for _, s in pairs(M.by_key) do
    for _, root in ipairs(s.local_roots) do
      if (path == root or path:sub(1, #root + 1) == root .. "/") and (not best or #root > best_len) then
        best, best_len = s, #root
      end
    end
  end
  return best
end

function M.current()
  local name = vim.api.nvim_buf_get_name(0)
  return M.find(name) or M.find(vim.fn.getcwd())
end

--- Attached sessions, sorted by name.
---@return devcontainer.Session[]
function M.list()
  local all = vim.tbl_values(M.by_key)
  table.sort(all, function(a, b) return a.name < b.name end)
  return all
end

--- Call `cb` with the session of the current buffer / cwd; else the only attached one; else ask.
--- `cb(nil)` when nothing is attached (or the choice was cancelled).
---@param cb fun(session: devcontainer.Session?)
---@param prompt? string
function M.pick(cb, prompt)
  local s = M.current()
  if s then return cb(s) end
  local all = M.list()
  if #all <= 1 then return cb(all[1]) end
  vim.ui.select(all, {
    prompt = prompt or "Devcontainer",
    format_item = function(x) return ("%s  (%s)"):format(x.name, vim.fn.fnamemodify(x.local_folder, ":~")) end,
  }, cb)
end

return M
