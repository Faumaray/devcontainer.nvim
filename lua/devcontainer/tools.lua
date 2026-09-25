--- Language tools missing in the container: when a C/C++ workspace is attached to a container
--- without clangd, offer to install clangd, clang-tidy and clang-format (latest LLVM from
--- apt.llvm.org on Debian/Ubuntu, the distribution's packages elsewhere). They are installed into
--- the running container, so after a rebuild they are offered again.
local async = require("devcontainer.async")
local config = require("devcontainer.config")
local log = require("devcontainer.log")
local store = require("devcontainer.store")

local M = {}

--- sh script, run as root: $1 = LLVM major version ("" = the latest stable release).
--- $DEVCONTAINER_BIN_DIR (default /usr/local/bin) gets the plain names of versioned binaries
--- ($DEVCONTAINER_ROOT prefixes the paths looked at, for tests).
M.LLVM_SCRIPT = [[
V="${1:-}"
BIN="${DEVCONTAINER_BIN_DIR:-/usr/local/bin}"
ROOT="${DEVCONTAINER_ROOT:-}"
export DEBIAN_FRONTEND=noninteractive
have() { command -v "$1" >/dev/null 2>&1; }
link() {
  mkdir -p "$BIN"
  for t in clangd clang-tidy clang-format; do
    for c in "$ROOT/usr/lib/llvm-$1/bin/$t" "$ROOT/usr/bin/$t-$1"; do
      if [ -x "$c" ]; then ln -sf "$c" "$BIN/$t"; break; fi
    done
  done
}
if have apt-get; then
  apt-get update || exit 1
  # what llvm.sh needs
  apt-get install -y --no-install-recommends ca-certificates wget gnupg lsb-release software-properties-common || exit 1
  tmp=$(mktemp -d)
  if wget -qO "$tmp/llvm.sh" https://apt.llvm.org/llvm.sh; then
    [ -n "$V" ] || V=$(sed -n 's/^CURRENT_LLVM_STABLE=\([0-9][0-9]*\).*/\1/p' "$tmp/llvm.sh" | head -n 1)
    if [ -n "$V" ] && bash "$tmp/llvm.sh" "$V" \
      && apt-get update -y && apt-get install -y --no-install-recommends "clang-tidy-$V" "clang-format-$V"; then
      link "$V"
      rm -rf "$tmp"
      exit 0
    fi
  fi
  rm -rf "$tmp"
  echo "apt.llvm.org didn't work here: installing the distribution's packages" >&2
  apt-get update -y
  apt-get install -y --no-install-recommends clangd clang-tidy clang-format
elif have dnf; then
  dnf install -y clang-tools-extra
elif have yum; then
  yum install -y clang-tools-extra
elif have zypper; then
  zypper --non-interactive install clang-tools
elif have apk; then
  apk add --no-cache clang-extra-tools
elif have pacman; then
  pacman -Sy --noconfirm clang
else
  echo "no supported package manager (apt-get, dnf, yum, zypper, apk, pacman)" >&2
  exit 1
fi]]

---@class devcontainer.ToolSet
---@field desc string
---@field bins string[]  what it provides (the first one decides whether it's missing)
---@field script string  sh script run as root; $1 = lsp.llvm_version or ""
---@field wanted fun(root: string): boolean  whether the workspace needs it

local C_FT = { c = true, cpp = true, objc = true, objcpp = true, cuda = true }
local C_MARKERS = { "CMakeLists.txt", "compile_commands.json", "compile_flags.txt", ".clangd", "meson.build" }

--- A C/C++ workspace: a C/C++ build file in its root or a C/C++ buffer open below it.
function M.is_cpp(root)
  for _, m in ipairs(C_MARKERS) do
    if vim.uv.fs_stat(root .. "/" .. m) then return true end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and C_FT[vim.bo[buf].filetype] then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:sub(1, #root + 1) == root .. "/" then return true end
    end
  end
  return false
end

---@type table<string, devcontainer.ToolSet>
M.sets = {
  clangd = {
    desc = "clangd, clang-tidy and clang-format",
    bins = { "clangd", "clang-tidy", "clang-format" },
    script = M.LLVM_SCRIPT,
    wanted = M.is_cpp,
  },
}

--- Executables of every tool set (looked up in one go when a container is attached).
function M.bins()
  local out = {}
  for _, set in vim.spairs(M.sets) do vim.list_extend(out, set.bins) end
  return out
end

--- Install tool set `name` in the container of `session` (as root), then restart its LSP clients.
---@param done? fun(ok: boolean)
function M.install(session, name, done)
  local set = M.sets[name]
  if not set then
    log.error("devcontainer: unknown tool set " .. tostring(name))
    return done and done(false)
  end
  local version = config.get(session.local_folder).lsp.llvm_version
  local progress, unsubscribe
  async.run(function()
    log.info(("installing %s in %s (progress: :Devcontainer log)"):format(set.desc, session.name))
    progress = require("devcontainer.progress").start("devcontainer " .. session.name)
    progress:report("installing " .. set.desc)
    unsubscribe = log.subscribe(function(lines) progress:feed(lines) end)
    local stream = function(_, data) log.append(data) end
    local res = async.system(session:exec_argv({ "/bin/sh", "-c", set.script, "sh", version and tostring(version) or "" },
      { user = "root" }), { text = true, stdout = stream, stderr = stream })
    for _, b in ipairs(set.bins) do session._which[b] = nil end
    session:prefetch(set.bins)
    local missing = vim.tbl_filter(function(b) return not session:which(b) end, set.bins)
    if res.code ~= 0 or #missing > 0 then
      error(("installing %s failed%s (see :Devcontainer log)"):format(set.desc,
        #missing > 0 and (": " .. table.concat(missing, ", ") .. " still missing") or ""), 0)
    end
    for _, b in ipairs(set.bins) do session.warned[b] = nil end
    log.info(("%s: installed %s"):format(session.name, table.concat(vim.tbl_map(function(b) return session:which(b) end, set.bins), ", ")))
    require("devcontainer.lsp").restart(session.local_folder)
  end, function(err)
    if unsubscribe then unsubscribe() end
    if progress then progress:finish(not err, err and "failed" or "installed") end
    if err then log.error("devcontainer: " .. tostring(err)) end
    if done then done(not err) end
  end)
end

local asked = {} -- session key .. set name -> true

--- Offer the tool sets the workspace of `session` needs and the container lacks (once per
--- container and Neovim session; "Never" is remembered per project).
---@param opts? { force?: boolean }  force: also without an attached UI (tests)
function M.offer(session, opts)
  opts = opts or {}
  local mode = config.get(session.local_folder).lsp.install_tools
  if mode == false or mode == nil then return end
  if mode ~= true and not opts.force and #vim.api.nvim_list_uis() == 0 then return end
  local root = session.local_folder
  for name, set in vim.spairs(M.sets) do
    local key = session.key .. ":" .. name
    if not asked[key] and set.wanted(root) and not session:which(set.bins[1])
      and (store.get(root).install_tools or {})[name] ~= "never" then
      asked[key] = true
      if mode == true then return M.install(session, name) end
      local version = config.get(root).lsp.llvm_version
      vim.ui.select({
        { label = ("Install %s (LLVM %s)"):format(set.desc, version or "latest"), action = "install" },
        { label = "Not now", action = "skip" },
        { label = "Never for this project", action = "never" },
      }, {
        prompt = ("%s is not installed in %s"):format(set.bins[1], session.name),
        format_item = function(c) return c.label end,
        kind = "devcontainer.install_tools",
      }, function(choice)
        if not choice then return end
        if choice.action == "install" then
          M.install(session, name)
        elseif choice.action == "never" then
          local remembered = vim.deepcopy(store.get(root).install_tools or {})
          remembered[name] = "never"
          store.set(root, "install_tools", remembered)
        end
      end)
      return
    end
  end
end

return M
