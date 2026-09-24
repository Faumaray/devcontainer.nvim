--- neotest strategy that runs the adapter's test command inside the devcontainer of the tests:
---
---   require("neotest").setup({ adapters = { ... }, default_strategy = "devcontainer" })
---   -- or per run: require("neotest").run.run({ strategy = "devcontainer" })
---
--- It wraps neotest's "integrated" strategy. Workspace paths in the command are translated.
--- Temporary files the adapter passes (result / stream files under Neovim's tempdir) live in a
--- temporary folder in the container and are copied back, with container paths turned into host
--- paths, before the adapter reads them. Helper scripts of the adapter that exist only on the host
--- (neotest-python's neotest.py, ...) are copied in first. Outside an attached workspace this is
--- just the integrated strategy.
local paths = require("devcontainer.paths")
local registry = require("devcontainer.session")

local M = {}

local REMOTE_TMP = "/tmp/devcontainer-nvim-neotest"

local function is_under(path, dir)
  return path == dir or vim.startswith(path, dir .. "/")
end

--- Rewrite a RunSpec for `session` (pure, for tests).
---@param spec table            neotest.RunSpec
---@param session devcontainer.Session
---@param tempdir string        Neovim's tempdir on the host
---@param remote_tmp string     scratch folder in the container for this run
---@param host_file? fun(path: string): boolean  exists on the host (default: vim.uv.fs_stat)
---@return { command: string[], cwd: string, copy_in: { host: string, remote: string }[] }
function M.transform(spec, session, tempdir, remote_tmp, host_file)
  host_file = host_file or function(p)
    local st = vim.uv.fs_stat(p)
    return st ~= nil and st.type == "file"
  end
  local copy_in, seen = {}, {}
  local function in_workspace(p)
    for _, root in ipairs(session.local_roots) do
      if is_under(p, root) then return true end
    end
    return false
  end
  local function map(s)
    if type(s) ~= "string" then return s end
    s = paths.replace_root(s, tempdir, remote_tmp .. "/tmp")
    -- a helper script only the host has: copy its folder in (scripts import their siblings)
    if s:sub(1, 1) == "/" and not in_workspace(s) and not is_under(s, remote_tmp) and host_file(s) then
      local dir = vim.fs.dirname(s)
      local remote_dir = remote_tmp .. "/in/" .. vim.fn.sha256(dir):sub(1, 12)
      if not seen[dir] then
        seen[dir] = true
        table.insert(copy_in, { host = dir, remote = remote_dir })
      end
      return remote_dir .. "/" .. vim.fs.basename(s)
    end
    return session:map_arg(s)
  end
  local command = spec.command
  if type(command) == "string" then command = { "/bin/sh", "-c", command } end
  local inner = {}
  for i, a in ipairs(command) do inner[i] = map(a) end
  local env
  for k, v in pairs(spec.env or {}) do
    env = env or {}
    env[k] = map(v)
  end
  local cwd = spec.cwd and session:remote_path(spec.cwd) or session.remote_folder
  return {
    command = session:exec_argv(inner, { tty = true, cwd = cwd, env = env }),
    cwd = session.local_folder,
    copy_in = copy_in,
  }
end

--- Copy files of the run's scratch folder back to Neovim's tempdir, mapping container paths.
local function copy_back(nio, session, tempdir, remote_tmp)
  local system = nio.wrap(function(cmd, opts, cb) vim.system(cmd, opts, vim.schedule_wrap(cb)) end, 3)
  local list = system(session:exec_argv({ "find", remote_tmp .. "/tmp", "-type", "f" }, { env = false }), { text = true })
  for file in vim.gsplit(list.stdout or "", "\n", { plain = true, trimempty = true }) do
    local host = tempdir .. file:sub(#remote_tmp + #"/tmp" + 1)
    local res = system(session:exec_argv({ "cat", "--", file }, { env = false }), {})
    if res.code == 0 then
      vim.fn.mkdir(vim.fs.dirname(host), "p")
      local f = io.open(host, "wb")
      if f then
        f:write(paths.replace_root(res.stdout or "", session.remote_folder, session.local_folder))
        f:close()
      end
    end
  end
  system(session:exec_argv({ "rm", "-rf", remote_tmp }, { env = false }), {})
end

local function copy_dirs_in(nio, session, run)
  local system = nio.wrap(function(cmd, opts, cb) vim.system(cmd, opts, vim.schedule_wrap(cb)) end, 3)
  system(session:exec_argv({ "mkdir", "-p", run.remote_tmp .. "/tmp" }, { env = false }), {})
  for _, c in ipairs(run.copy_in) do
    local tar = system({ "tar", "-C", c.host, "--exclude=.git", "-cf", "-", "." }, {})
    if tar.code == 0 then
      system(session:exec_argv({ "/bin/sh", "-c", 'mkdir -p "$1" && tar -C "$1" -xf -', "sh", c.remote },
        { stdin = true, env = false }), { stdin = tar.stdout })
    end
  end
end

local function integrated_spec(spec)
  local ok, config = pcall(require, "neotest.config")
  local defaults = ok and config.strategies and config.strategies.integrated or {}
  local new = vim.tbl_extend("force", {}, spec)
  new.strategy = vim.tbl_extend("keep", type(spec.strategy) == "table" and spec.strategy or {}, defaults)
  return new
end

--- The strategy (neotest calls it inside a nio task).
---@param spec table neotest.RunSpec
---@param context? table
function M.strategy(spec, context)
  local nio = require("nio")
  local integrated = require("neotest.client.strategies.integrated")
  local pos = context and context.position and context.position.path
  local session = (pos and registry.find(pos)) or (spec.cwd and registry.find(spec.cwd)) or nil
  if not session then return integrated(integrated_spec(spec)) end

  local tempdir = vim.fs.dirname(nio.fn.tempname())
  local remote_tmp = ("%s/%d"):format(REMOTE_TMP, vim.uv.hrtime())
  local run = M.transform(spec, session, tempdir, remote_tmp)
  run.remote_tmp = remote_tmp
  copy_dirs_in(nio, session, run)

  local wrapped = integrated_spec(spec)
  wrapped.command, wrapped.cwd, wrapped.env = run.command, run.cwd, nil
  local proc = integrated(wrapped)
  local result = proc.result
  proc.result = function()
    local code = result()
    copy_back(nio, session, tempdir, remote_tmp)
    -- output with host paths, so errors point at files the host can open
    local out = proc.output()
    local f = out and io.open(out, "rb")
    if f then
      local data = f:read("*a")
      f:close()
      local mapped = paths.replace_root(data, session.remote_folder, session.local_folder)
      if mapped ~= data then
        f = io.open(out, "wb")
        if f then
          f:write(mapped)
          f:close()
        end
      end
    end
    return code
  end
  return proc
end

return M
