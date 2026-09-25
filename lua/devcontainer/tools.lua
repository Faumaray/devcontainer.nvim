--- Language tools missing in the container: when a C/C++ workspace is attached to a container
--- without clangd, offer to install clangd, clang-tidy and clang-format (the newest there is:
--- apt.llvm.org, PyPI wheels, the distribution's). They are installed into the running container,
--- so after a rebuild they are offered again.
local async = require("devcontainer.async")
local config = require("devcontainer.config")
local log = require("devcontainer.log")
local store = require("devcontainer.store")

local M = {}

--- sh script, run as root: $1 = LLVM major version ("" = the latest release), $2 = apt.llvm.org
--- mirror. Newest first:
---  1. apt.llvm.org (Debian / Ubuntu): the release llvm.sh installs, but only clangd-N, clang-tidy-N
---     and clang-format-N, and without add-apt-repository (it breaks when python3 isn't the
---     distribution's)
---  2. PyPI wheels (glibc systems) in a venv
---  3. the distribution's newest versioned packages (apt), else its clang tools package
--- Versioned binaries are linked by their plain names into $DEVCONTAINER_BIN_DIR (/usr/local/bin);
--- $DEVCONTAINER_ROOT prefixes the system paths used, for tests.
M.LLVM_SCRIPT = [[
PIN="${1:-}"
MIRROR="${2:-https://apt.llvm.org}"
BIN="${DEVCONTAINER_BIN_DIR:-/usr/local/bin}"
ROOT="${DEVCONTAINER_ROOT:-}"
VENV="${DEVCONTAINER_LLVM_VENV:-/opt/devcontainer-nvim/llvm}"
TOOLS="clangd clang-tidy clang-format"
export DEBIAN_FRONTEND=noninteractive
have() { command -v "$1" >/dev/null 2>&1; }
say() { echo "devcontainer.nvim: $*" >&2; }
fetch() { if have wget; then wget -qO "$2" "$1"; else curl -fsSL -o "$2" "$1"; fi; }
osr() { sed -n "s/^$1=//p" "$ROOT/etc/os-release" 2>/dev/null | tr -d '"' | head -n 1; }
# $BIN/<tool> -> the first of the dirs given that has it
link() {
  mkdir -p "$BIN" || return 1
  for t in $TOOLS; do
    found=
    for d; do
      if [ -x "$d/$t" ]; then ln -sf "$d/$t" "$BIN/$t"; found=1; break; fi
    done
    [ -n "$found" ] || { say "$t missing after the installation"; return 1; }
  done
}

apt_llvm() {
  have apt-get || return 1
  have wget || have curl || apt-get install -y --no-install-recommends ca-certificates wget || return 1
  code=$(osr UBUNTU_CODENAME)
  [ -n "$code" ] || code=$(osr VERSION_CODENAME)
  [ -n "$code" ] || { say "unknown release (no codename in /etc/os-release)"; return 1; }
  v="$PIN"
  if [ -z "$v" ]; then
    tmp=$(mktemp) && fetch "$MIRROR/llvm.sh" "$tmp" \
      && v=$(sed -n 's/^CURRENT_LLVM_STABLE=\([0-9][0-9]*\).*/\1/p' "$tmp" | head -n 1)
    rm -f "$tmp"
    [ -n "$v" ] || { say "can't read the current LLVM release from $MIRROR/llvm.sh"; return 1; }
  fi
  case "$code" in
    sid|unstable|forky) code=unstable; suite="llvm-toolchain-$v" ;;
    *) suite="llvm-toolchain-$code-$v" ;;
  esac
  fetch "$MIRROR/$code/dists/$suite/Release" /dev/null || { say "$MIRROR has no $code/$suite"; return 1; }
  mkdir -p "$ROOT/etc/apt/trusted.gpg.d" "$ROOT/etc/apt/sources.list.d"
  fetch "$MIRROR/llvm-snapshot.gpg.key" "$ROOT/etc/apt/trusted.gpg.d/apt.llvm.org.asc" || return 1
  list="$ROOT/etc/apt/sources.list.d/apt.llvm.org-$v.list"
  echo "deb $MIRROR/$code/ $suite main" > "$list"
  if apt-get update -o Dir::Etc::sourcelist="$list" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 \
    && apt-get install -y --no-install-recommends "clangd-$v" "clang-tidy-$v" "clang-format-$v" \
    && link "$ROOT/usr/lib/llvm-$v/bin"; then
    say "installed LLVM $v from $MIRROR"
    return 0
  fi
  rm -f "$list"
  return 1
}

pypi() {
  if ! have python3; then
    if have apt-get; then apt-get install -y --no-install-recommends python3 python3-venv
    elif have dnf; then dnf install -y python3
    elif have yum; then yum install -y python3
    elif have zypper; then zypper --non-interactive install python3
    fi
  fi
  have python3 || return 1
  if ! python3 -m venv --clear "$VENV"; then
    have apt-get && apt-get install -y --no-install-recommends python3-venv && python3 -m venv --clear "$VENV" || return 1
  fi
  spec=
  for t in $TOOLS; do spec="$spec $t${PIN:+==$PIN.*}"; done
  "$VENV/bin/python" -m pip install --upgrade --only-binary=:all: $spec || return 1
  dirs=
  for p in clangd clang_tidy clang_format; do
    dirs="$dirs $(find "$VENV" -type d -path "*/site-packages/$p/data/bin" | head -n 1)"
  done
  link $dirs || return 1
  say "installed from PyPI into $VENV"
}

distro() {
  if have apt-get; then
    for n in $(apt-cache search --names-only '^clangd-[0-9]+$' 2>/dev/null | sed -n 's/^clangd-\([0-9][0-9]*\) .*/\1/p' | sort -rnu); do
      if [ -z "$PIN" ] || [ "$n" = "$PIN" ]; then
        if apt-cache show "clang-tidy-$n" "clang-format-$n" >/dev/null 2>&1 \
          && apt-get install -y --no-install-recommends "clangd-$n" "clang-tidy-$n" "clang-format-$n" \
          && link "$ROOT/usr/lib/llvm-$n/bin"; then
          say "installed LLVM $n from the distribution"
          return 0
        fi
      fi
    done
    apt-get install -y --no-install-recommends clangd clang-tidy clang-format
  elif have dnf; then dnf install -y clang-tools-extra
  elif have yum; then yum install -y clang-tools-extra
  elif have zypper; then zypper --non-interactive install clang-tools
  elif have apk; then apk add --no-cache clang-extra-tools
  elif have pacman; then pacman -Sy --noconfirm clang
  else say "no supported package manager (apt-get, dnf, yum, zypper, apk, pacman)"; return 1
  fi
}

if have apt-get; then apt-get update || say "apt-get update failed, going on with the package lists there are"; fi
# rolling (Arch) or musl (Alpine: no PyPI wheels): the distribution's are the ones to use
if have pacman || have apk; then distro; exit $?; fi
apt_llvm && exit 0
have apt-get && say "apt.llvm.org didn't work here, trying PyPI"
pypi && exit 0
say "PyPI didn't work here, installing the distribution's packages"
distro]]

---@class devcontainer.ToolSet
---@field desc string
---@field bins string[]  what it provides (the first one decides whether it's missing)
---@field script string  sh script run as root; $1 = lsp.llvm_version or "", $2 = lsp.llvm_mirror or ""
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
  local o = config.get(session.local_folder).lsp
  local progress, unsubscribe
  async.run(function()
    log.info(("installing %s in %s (progress: :Devcontainer log)"):format(set.desc, session.name))
    progress = require("devcontainer.progress").start("devcontainer " .. session.name)
    progress:report("installing " .. set.desc)
    unsubscribe = log.subscribe(function(lines) progress:feed(lines) end)
    local stream = function(_, data) log.append(data) end
    local res = async.system(session:exec_argv({ "/bin/sh", "-c", set.script, "sh",
      o.llvm_version and tostring(o.llvm_version) or "", o.llvm_mirror or "" }, { user = "root" }),
      { text = true, stdout = stream, stderr = stream })
    for _, b in ipairs(set.bins) do session._which[b] = nil end
    session:prefetch(set.bins)
    local missing = vim.tbl_filter(function(b) return not session:which(b) end, set.bins)
    if res.code ~= 0 or #missing > 0 then
      error(("installing %s failed%s (see :Devcontainer log)"):format(set.desc,
        #missing > 0 and (": " .. table.concat(missing, ", ") .. " still missing") or ""), 0)
    end
    for _, b in ipairs(set.bins) do session.warned[b] = nil end
    local v = async.system(session:exec_argv({ session:which(set.bins[1]), "--version" }), { text = true })
    local version = vim.trim(((v.stdout or ""):match("[^\n]*")) or "")
    log.info(("%s: installed %s%s"):format(session.name, table.concat(vim.tbl_map(function(b) return session:which(b) end, set.bins), ", "),
      version ~= "" and (" (" .. version .. ")") or ""))
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
