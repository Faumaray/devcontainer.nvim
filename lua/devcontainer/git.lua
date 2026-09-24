--- Git conveniences inside the container, like VS Code: the host's SSH agent, ~/.gitconfig and a
--- dotfiles repository.
---
--- SSH agent (Linux): a folder in Neovim's state dir is bind-mounted into new containers and
--- Neovim serves a socket in it that relays to the current $SSH_AUTH_SOCK. The folder always
--- exists, so the container still starts after the agent socket moved (new login, reboot); the
--- agent works while a Neovim with this plugin runs. macOS (Docker Desktop): its
--- /run/host-services/ssh-auth.sock is mounted instead.
local async = require("devcontainer.async")
local log = require("devcontainer.log")

local M = {}
local uv = vim.uv

M.AGENT_DIR = "/tmp/devcontainer-nvim-ssh"
M.AGENT_SOCK = M.AGENT_DIR .. "/agent.sock"

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

local relay_server

--- Serve <state>/devcontainer.nvim/ssh-agent/agent.sock, relaying to $SSH_AUTH_SOCK.
---@return boolean ok
function M.start_agent_relay()
  if relay_server then return true end
  local upstream = vim.env.SSH_AUTH_SOCK
  local st = upstream and upstream ~= "" and uv.fs_stat(upstream)
  if not st or st.type ~= "socket" then return false end
  local dir = M.host_agent_dir()
  vim.fn.mkdir(dir, "p", 448)
  local path = dir .. "/agent.sock"
  pcall(uv.fs_unlink, path)
  local server = assert(uv.new_pipe(false))
  local ok, err = server:bind(path)
  if ok then
    ok, err = server:listen(16, function(e)
      if e then return end
      local client = assert(uv.new_pipe(false))
      if not server:accept(client) then return close(client) end
      local agent = assert(uv.new_pipe(false))
      agent:connect(os.getenv("SSH_AUTH_SOCK") or upstream, function(cerr)
        if cerr then
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
    log.append("ssh agent relay: " .. tostring(err))
    return false
  end
  uv.fs_chmod(path, 384) -- 0600
  relay_server = server
  return true
end

function M.stop_agent_relay()
  close(relay_server)
  relay_server = nil
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

--- After attach: SSH agent socket, ~/.gitconfig. Runs inside async.run.
function M.after_attach(session, o)
  local g = o.git or {}
  session.ssh_agent = nil
  if g.ssh_agent then
    if vim.fn.has("mac") == 0 then M.start_agent_relay() end
    local res = async.system(session:exec_argv({ "test", "-S", M.AGENT_SOCK }, { env = false }), {})
    session.ssh_agent = res.code == 0
    if session.ssh_agent then session.env.SSH_AUTH_SOCK = M.AGENT_SOCK end
  end
  if g.gitconfig then
    local src = type(g.gitconfig) == "string" and vim.fs.normalize(g.gitconfig) or vim.fs.normalize("~/.gitconfig")
    local f = io.open(src, "r")
    if f then
      local data = f:read("*a")
      f:close()
      -- never overwrite the container's own
      async.system(session:exec_argv({ "/bin/sh", "-c", '[ -e "$HOME/.gitconfig" ] || cat > "$HOME/.gitconfig"' },
        { stdin = true }), { stdin = data })
    end
  end
end

return M
