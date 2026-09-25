--- Git conveniences inside the container, like VS Code: the host's SSH agent, ~/.gitconfig and a
--- dotfiles repository.
---
--- SSH agent (Linux): a folder in Neovim's state dir is bind-mounted into new containers and
--- Neovim serves a socket in it that relays to the current $SSH_AUTH_SOCK. The folder always
--- exists, so the container still starts after the agent socket moved (new login, reboot); the
--- agent works while a Neovim with this plugin runs. All Neovims share the socket: the first one
--- serves it, the others take over when it exits. macOS (Docker Desktop): its
--- /run/host-services/ssh-auth.sock is mounted instead.
local async = require("devcontainer.async")
local log = require("devcontainer.log")

local M = {}
local uv = vim.uv

M.AGENT_DIR = "/tmp/devcontainer-nvim-ssh"
M.AGENT_SOCK = M.AGENT_DIR .. "/agent.sock"
-- how often a Neovim that doesn't serve the socket checks whether its server is still there (ms)
M.takeover_interval = 10000

function M.host_agent_dir()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "devcontainer.nvim", "ssh-agent")
end

--- `--mount` value for the SSH agent of new containers, or nil.
---@param o devcontainer.Options
---@param mac? boolean  (default: running on macOS)
function M.agent_mount(o, mac)
  if not (o.git and o.git.ssh_agent) then return nil end
  if mac == nil then mac = vim.fn.has("mac") == 1 end
  if mac then return ("type=bind,source=/run/host-services/ssh-auth.sock,target=%s"):format(M.AGENT_SOCK) end
  local dir = M.host_agent_dir()
  vim.fn.mkdir(dir, "p", 448) -- 0700
  return ("type=bind,source=%s,target=%s"):format(dir, M.AGENT_DIR)
end

local function close(h)
  if h and not h:is_closing() then h:close() end
end

local relay_server ---@type uv.uv_pipe_t?
local takeover_timer ---@type uv.uv_timer_t?
local noted = {}

-- once per kind in :Devcontainer log (safe from luv callbacks)
local function note(kind, msg)
  if noted[kind] then return end
  noted[kind] = true
  log.append("ssh agent relay: " .. msg)
end

local function sock_path() return M.host_agent_dir() .. "/agent.sock" end
local function owner_path() return M.host_agent_dir() .. "/owner" end

--- Calls `cb(true)` when something accepts connections on the unix socket `path`.
local function probe(path, cb)
  local st = uv.fs_stat(path)
  if not st or st.type ~= "socket" then return cb(false) end
  local pipe = assert(uv.new_pipe(false))
  pipe:connect(path, function(err)
    close(pipe)
    cb(not err)
  end)
end

local function serving(path)
  local result
  probe(path, function(ok) result = ok end)
  vim.wait(1000, function() return result ~= nil end, 5)
  return result == true
end

local function stop_takeover()
  if takeover_timer then close(takeover_timer) end
  takeover_timer = nil
end

--- Another Neovim serves the socket: take over once it's gone.
local function watch_takeover()
  if takeover_timer then return end
  takeover_timer = assert(uv.new_timer())
  takeover_timer:start(M.takeover_interval, M.takeover_interval, function()
    probe(sock_path(), function(ok)
      if ok then return end
      vim.schedule(function()
        stop_takeover()
        M.start_agent_relay()
      end)
    end)
  end)
end

--- Serve <state>/devcontainer.nvim/ssh-agent/agent.sock, relaying to $SSH_AUTH_SOCK, unless another
--- Neovim serves it already.
---@return boolean ok  the socket is served (by this Neovim or another one)
function M.start_agent_relay()
  if relay_server then return true end
  local path = sock_path()
  if serving(path) then
    watch_takeover()
    return true
  end
  local upstream = vim.env.SSH_AUTH_SOCK
  local st = upstream and upstream ~= "" and uv.fs_stat(upstream)
  if not st or st.type ~= "socket" then
    note("upstream", ("$SSH_AUTH_SOCK of this Neovim (%s) is not a socket: no SSH agent for containers"):format(
      upstream and upstream ~= "" and upstream or "unset"))
    return false
  end
  vim.fn.mkdir(M.host_agent_dir(), "p", 448)
  pcall(uv.fs_unlink, path)
  local server = assert(uv.new_pipe(false))
  local ok, err = server:bind(path)
  if ok then
    ok, err = server:listen(16, function(e)
      if e then return end
      local client = assert(uv.new_pipe(false))
      if not server:accept(client) then return close(client) end
      local agent = assert(uv.new_pipe(false))
      local target = os.getenv("SSH_AUTH_SOCK") or upstream
      agent:connect(target, function(cerr)
        if cerr then
          note("connect", ("cannot reach %s: %s"):format(target, cerr))
          close(agent)
          return close(client)
        end
        local function pipe(from, to)
          from:read_start(function(rerr, data)
            if rerr or not data then
              close(from)
              return close(to)
            end
            if not to:is_closing() then to:write(data) end
          end)
        end
        pipe(client, agent)
        pipe(agent, client)
      end)
    end)
  end
  if not ok then
    close(server)
    note("bind", tostring(err))
    return false
  end
  uv.fs_chmod(path, 384) -- 0600
  local f = io.open(owner_path(), "w")
  if f then
    f:write(("%d\t%s\n"):format(uv.os_getpid(), upstream))
    f:close()
  end
  relay_server = server
  stop_takeover()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("devcontainer.ssh_agent", { clear = true }),
    callback = function() M.stop_agent_relay() end,
  })
  return true
end

--- Stop serving (and remove the socket, so another Neovim can take over).
function M.stop_agent_relay()
  stop_takeover()
  if not relay_server then return end
  close(relay_server)
  relay_server = nil
  pcall(uv.fs_unlink, sock_path())
  pcall(uv.fs_unlink, owner_path())
end

--- Who serves the agent socket: "self" (this Neovim), "other" (another Neovim, pid) or "none".
---@return { state: "self"|"other"|"none", pid?: integer, upstream?: string }
function M.relay_status()
  local pid, upstream
  local f = io.open(owner_path(), "r")
  if f then
    pid, upstream = (f:read("*l") or ""):match("^(%d+)\t(.*)$")
    f:close()
  end
  if relay_server then return { state = "self", pid = uv.os_getpid(), upstream = upstream } end
  if serving(sock_path()) then return { state = "other", pid = tonumber(pid), upstream = upstream } end
  return { state = "none" }
end

-- what a task in the container sees: its SSH_AUTH_SOCK, `ssh-add -l`, known_hosts
M.DIAGNOSE_SCRIPT = [[
printf 'sock=%s\n' "$SSH_AUTH_SOCK"
if command -v ssh-add >/dev/null 2>&1; then
  keys=$(ssh-add -l 2>&1); code=$?
  printf 'ssh_add=%s\nkeys=%s\n' "$code" "$(printf '%s\n' "$keys" | grep -c '^[0-9]')"
  [ "$code" = 0 ] || printf 'error=%s\n' "$(printf '%s' "$keys" | head -n 1)"
else
  echo ssh_add=missing
fi
[ -s "$HOME/.ssh/known_hosts" ] && echo known_hosts=yes || echo known_hosts=no]]

--- Check the SSH setup the way build tasks run (same exec path and environment). Synchronous.
---@return { sock: string, ssh_add: string, keys: integer, error?: string, known_hosts: boolean }?
function M.diagnose(session)
  local argv = require("devcontainer.runner").argv({
    cmd = { "/bin/sh", "-c", M.DIAGNOSE_SCRIPT }, cwd = session.local_folder, session = session,
  }, false)
  local res = vim.system(argv, { text = true }):wait(15000)
  if res.code ~= 0 then return nil end
  local r = {}
  for line in vim.gsplit(res.stdout or "", "\n", { plain = true }) do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then r[k] = v end
  end
  return { sock = r.sock or "", ssh_add = r.ssh_add or "missing", keys = tonumber(r.keys) or 0,
    error = r.error, known_hosts = r.known_hosts == "yes" }
end

--- "owner/repo" -> GitHub URL; anything else is used as is.
function M.dotfiles_url(repo)
  if repo:match("^[%w_.-]+/[%w_.-]+$") then return ("https://github.com/%s.git"):format((repo:gsub("%.git$", ""))) end
  return repo
end

--- sh script (args: url, target path, install command) that installs dotfiles once, like the
--- devcontainer CLI: run the install command, or the first install script found, or else link
--- the repository's dotfiles into $HOME.
M.DOTFILES_SCRIPT = [[
repo="$1"; target="$2"; cmd="$3"
case "$target" in "~"*) target="$HOME${target#\~}";; esac
[ -e "$target" ] && exit 0
command -v git >/dev/null 2>&1 || { echo "dotfiles: git is not installed in the container" >&2; exit 1; }
git clone --depth 1 "$repo" "$target" || exit 1
cd "$target" || exit 1
if [ -n "$cmd" ]; then
  if [ -f "$cmd" ]; then
    chmod +x "$cmd"
    case "$cmd" in /*) exec "$cmd";; *) exec "./$cmd";; esac
  fi
  exec /bin/sh -c "$cmd"
fi
for f in install.sh install bootstrap.sh bootstrap script/bootstrap setup.sh setup script/setup; do
  if [ -f "$f" ]; then chmod +x "$f"; exec "./$f"; fi
done
for f in .[!.]* ..?*; do
  [ -e "$f" ] || continue
  case "$f" in .git|.github|.gitignore|.gitmodules) continue;; esac
  [ -e "$HOME/$f" ] || ln -s "$target/$f" "$HOME/$f"
done]]

--- `devcontainer up` flags for dotfiles.
function M.cli_dotfiles_args(o)
  local d = o.dotfiles or {}
  if not d.repository then return {} end
  local args = { "--dotfiles-repository", M.dotfiles_url(d.repository) }
  if d.target_path then vim.list_extend(args, { "--dotfiles-target-path", d.target_path }) end
  if d.install_command then vim.list_extend(args, { "--dotfiles-install-command", d.install_command }) end
  return args
end

--- Install dotfiles in a new container (docker backend; the CLI does it itself). Runs inside async.run.
function M.install_dotfiles(session, o)
  local d = o.dotfiles or {}
  if not d.repository then return end
  log.info("installing dotfiles from " .. d.repository)
  local stream = function(_, data) log.append(data) end
  local res = async.system(session:exec_argv({
    "/bin/sh", "-c", M.DOTFILES_SCRIPT, "sh", M.dotfiles_url(d.repository), d.target_path or "~/dotfiles", d.install_command or "",
  }), { text = true, stdout = stream, stderr = stream })
  if res.code ~= 0 then log.warn(("dotfiles installation failed with exit code %d (see :Devcontainer log)"):format(res.code)) end
end

--- sh script: append the known_hosts lines on stdin that ~/.ssh/known_hosts doesn't have yet.
M.KNOWN_HOSTS_SCRIPT = [[
d="$HOME/.ssh"; f="$d/known_hosts"
[ -d "$d" ] || { mkdir -p "$d" && chmod 700 "$d"; } || exit 1
[ -e "$f" ] || { : > "$f" && chmod 600 "$f"; } || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ""|"#"*) continue;; esac
  grep -qxF -e "$line" "$f" || printf '%s\n' "$line" >> "$f"
done]]

local function read_file(path)
  local f = io.open(vim.fs.normalize(path), "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

--- After attach: SSH agent socket, ~/.gitconfig, known_hosts. Runs inside async.run.
function M.after_attach(session, o)
  local g = o.git or {}
  session.ssh_agent = nil
  if g.ssh_agent then
    if vim.fn.has("mac") == 0 then M.start_agent_relay() end
    -- mounted (containers created with git.ssh_agent): every exec gets SSH_AUTH_SOCK, also the
    -- ones that start while no Neovim serves the socket yet
    local res = async.system(session:exec_argv({ "/bin/sh", "-c", 'test -S "$1" || test -d "$2"', "sh", M.AGENT_SOCK, M.AGENT_DIR },
      { env = false }), {})
    session.ssh_agent = res.code == 0
    if session.ssh_agent then session.env.SSH_AUTH_SOCK = M.AGENT_SOCK end
  end
  if g.gitconfig then
    local data = read_file(type(g.gitconfig) == "string" and g.gitconfig or "~/.gitconfig")
    if data then
      -- never overwrite the container's own
      async.system(session:exec_argv({ "/bin/sh", "-c", '[ -e "$HOME/.gitconfig" ] || cat > "$HOME/.gitconfig"' },
        { stdin = true }), { stdin = data })
    end
  end
  if g.known_hosts then
    -- builds have no terminal to answer "continue connecting?": trust the hosts the host trusts
    local data = read_file(type(g.known_hosts) == "string" and g.known_hosts or "~/.ssh/known_hosts")
    if data and data ~= "" then
      async.system(session:exec_argv({ "/bin/sh", "-c", M.KNOWN_HOSTS_SCRIPT }, { stdin = true }), { stdin = data })
    end
  end
end

return M
