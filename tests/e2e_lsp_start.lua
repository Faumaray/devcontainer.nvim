-- End-to-end test: a file is open before the container starts, and the language server is only
-- installed in the container. Once attached, the server has to start in the container for the
-- buffers that are already open (vim.lsp.enable never started it on the host).
--
--   nvim --headless --clean -l tests/e2e_lsp_start.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
vim.cmd.runtime("plugin/devcontainer.lua")

local E = "/tmp/dc-lspstart"
local HOST, REMOTE = E .. "/host/proj", E .. "/workspaces/proj"
vim.fn.delete(E, "rf")
vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME = E .. "/data", E .. "/state"
for _, d in ipairs({ HOST .. "/.devcontainer", REMOTE, E .. "/bin", E .. "/cbin" }) do vim.fn.mkdir(d, "p") end

local function write(path, text, mode)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
  if mode then vim.uv.fs_chmod(path, mode) end
end
local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local failures = 0
local function check(name, cond, detail)
  if cond then
    io.stdout:write("ok   " .. name .. "\n")
  else
    failures = failures + 1
    io.stdout:write("FAIL " .. name .. (detail ~= nil and ("\n  " .. vim.inspect(detail)) or "") .. "\n")
  end
end
local function wait(ms, fn) return vim.wait(ms, fn, 50) end

write(E .. "/bin/docker", read(root .. "/tests/fake-docker.py"), 493)
vim.env.FAKE_DOCKER_STATE = E .. "/state.json"
vim.env.FAKE_DOCKER_LOG = E .. "/docker.log"
vim.env.FAKE_DOCKER_BIND = HOST .. ":" .. REMOTE
-- servers that only exist "in the container": on the remote PATH, not on Neovim's
local clangd = vim.fn.exepath("clangd")
write(E .. "/cbin/clangd-plain", '#!/bin/sh\nexec "' .. clangd .. '" "$@"\n', 493)
write(E .. "/cbin/clangd-helper", '#!/bin/sh\nexec "' .. clangd .. '" "$@"\n', 493)
write(HOST .. "/.devcontainer/devcontainer.json", vim.json.encode({
  name = "lspstart", image = "fake:latest", workspaceFolder = REMOTE,
  remoteEnv = { PATH = E .. "/cbin:${containerEnv:PATH}" },
}))
write(HOST .. "/compile_commands.json", vim.json.encode({
  { directory = REMOTE, file = REMOTE .. "/main.cpp", arguments = { "clang++", "-c", REMOTE .. "/main.cpp" } },
}))
write(HOST .. "/main.cpp", "int main() {\n  int bad = \"x\";\n  return 0;\n}\n")
write(HOST .. "/other.cpp", "int other() { return 1; }\n")

local errors = {}
local orig_notify = vim.notify
vim.notify = function(msg, level, o)
  if level == vim.log.levels.ERROR then table.insert(errors, msg) end
  return orig_notify(msg, level, o)
end

require("devcontainer").setup({ backend = "docker", docker = E .. "/bin/docker", autostart = true })
local markers = { ".devcontainer", "compile_commands.json" }
-- 1. a plain command that isn't executable on the host
vim.lsp.config("clangd_plain", { cmd = { "clangd-plain", "--log=error" }, filetypes = { "cpp" }, root_markers = markers })
-- 2. the documented wrapper for host-less servers
vim.lsp.config("clangd_helper", {
  cmd = require("devcontainer").lsp_cmd({ "clangd-helper", "--log=error" }), filetypes = { "cpp" }, root_markers = markers,
})
vim.lsp.enable({ "clangd_plain", "clangd_helper" })

-- the file is open before the container runs
vim.cmd.edit(HOST .. "/main.cpp")
local buf = vim.api.nvim_get_current_buf()
wait(1000, function() return false end)
check("before up: no server on the host", #vim.lsp.get_clients({ bufnr = buf }) == 0, vim.lsp.get_clients({ bufnr = buf }))
check("before up: no spawn errors for host-less servers", #errors == 0, errors)

-- the container starts like on opening Neovim with autostart = true
require("devcontainer.autostart").check(HOST .. "/main.cpp", { force = true })
local session
check("attached", wait(20000, function()
  session = require("devcontainer").get(HOST)
  return session ~= nil
end))
if not session then os.exit(1) end

local function client(name, bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = name })[1]
end
for _, name in ipairs({ "clangd_plain", "clangd_helper" }) do
  check(name .. ": started in the container for the open buffer", wait(15000, function()
    local c = client(name, buf)
    return c ~= nil and c.config._devcontainer_key == session.key and c.initialized
  end), vim.tbl_map(function(c) return { c.name, c.config._devcontainer_key } end, vim.lsp.get_clients()))
end
check("diagnostics from the container server", wait(15000, function()
  return #vim.diagnostic.get(buf, { severity = vim.diagnostic.severity.ERROR }) > 0
end))
check("one client per server", #vim.lsp.get_clients({ bufnr = buf }) == 2, #vim.lsp.get_clients({ bufnr = buf }))

-- a buffer opened after attaching joins the same clients
vim.cmd.edit(HOST .. "/other.cpp")
local other = vim.api.nvim_get_current_buf()
check("later buffers reuse the container clients", wait(10000, function()
  local a, b = client("clangd_plain", other), client("clangd_plain", buf)
  return a ~= nil and a == b
end))

-- stop: host-less servers can't move back, and nothing errors
vim.cmd.buffer(buf)
vim.cmd("Devcontainer stop")
check("stop: servers gone, no host restart", wait(10000, function()
  return #vim.lsp.get_clients({ bufnr = buf }) == 0
end), vim.lsp.get_clients({ bufnr = buf }))
vim.cmd.edit(E .. "/host/proj/third.cpp")
wait(1000, function() return false end)
check("detached: new buffers don't try to spawn host-less servers", #errors == 0, errors)

io.stdout:write(failures == 0 and "\nall lsp start e2e checks passed\n" or ("\n%d lsp start e2e checks failed\n"):format(failures))
for _, c in ipairs(vim.lsp.get_clients()) do c:stop(true) end
vim.wait(500)
os.exit(failures == 0 and 0 or 1)
