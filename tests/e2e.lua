-- End-to-end test with a fake docker CLI (tests/fake-docker.py), a real clangd and a fake DAP
-- adapter. Commands "in the container" run in a mount namespace where the host workspace
-- /tmp/dc-e2e/host-proj is bind-mounted at /tmp/dc-e2e/workspaces/proj (needs root / unshare).
--
--   nvim --headless --clean -l tests/e2e.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
vim.cmd.runtime("plugin/devcontainer.lua")

local E = "/tmp/dc-e2e"
local HOST = E .. "/host-proj"
local REMOTE = E .. "/workspaces/proj"

vim.fn.delete(E, "rf")
vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME = E .. "/data", E .. "/state"
vim.fn.mkdir(HOST .. "/.devcontainer", "p")
vim.fn.mkdir(REMOTE, "p")
vim.fn.mkdir(E .. "/bin", "p")
vim.fn.mkdir(E .. "/container-only", "p")

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end
local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

write(E .. "/bin/docker", read(root .. "/tests/fake-docker.py"))
vim.uv.fs_chmod(E .. "/bin/docker", 493)
vim.env.FAKE_DOCKER_STATE = E .. "/state.json"
vim.env.FAKE_DOCKER_LOG = E .. "/docker.log"
vim.env.FAKE_DOCKER_BIND = HOST .. ":" .. REMOTE

write(HOST .. "/.devcontainer/devcontainer.json", [[
{
  // comments and trailing commas are fine
  "name": "e2e",
  "image": "fake:latest",
  "workspaceFolder": "/tmp/dc-e2e/workspaces/proj",
  "postCreateCommand": "touch /tmp/dc-e2e/post-create-ran",
  "remoteEnv": { "MY_VAR": "${containerWorkspaceFolder}/x", "HOME": "/tmp/dc-e2e/home" },
}
]])
write(HOST .. "/util.h", "#pragma once\nint helper(int x);\n")
write(HOST .. "/main.cpp", table.concat({
  '#include <stdio.h>',
  '#include "util.h"',
  'int main() {',
  '  printf("%d\\n", helper(1));',
  '  int bad = "not an int";',
  '  return 0;',
  '}',
  '',
}, "\n"))
-- generated "inside the container", so it contains container paths
write(HOST .. "/compile_commands.json", vim.json.encode({
  { directory = REMOTE, file = REMOTE .. "/main.cpp", arguments = { "clang++", "-std=c++23", "-c", REMOTE .. "/main.cpp" } },
}))
write(E .. "/container-only/note.txt", "old\n")

local failures = 0
local function check(name, cond, detail)
  if cond then
    io.stdout:write("ok   " .. name .. "\n")
  else
    failures = failures + 1
    io.stdout:write("FAIL " .. name .. (detail and ("\n  " .. vim.inspect(detail)) or "") .. "\n")
  end
end
local function wait(ms, fn)
  return vim.wait(ms, fn, 50)
end

-- git conveniences: gitconfig copied, dotfiles installed when the container is created
write(E .. "/host.gitconfig", "[user]\n\tname = e2e\n")
vim.fn.mkdir(E .. "/home", "p")
vim.fn.mkdir(E .. "/dotrepo", "p")
write(E .. "/dotrepo/.e2erc", "x\n")
vim.system({ "sh", "-c", 'cd "$1" && git init -q && git add -A && git -c user.email=a@b -c user.name=t commit -qm x', "sh", E .. "/dotrepo" }):wait()

require("devcontainer").setup({ backend = "docker", docker = E .. "/bin/docker",
  git = { gitconfig = E .. "/host.gitconfig" }, dotfiles = { repository = E .. "/dotrepo" } })
vim.lsp.config("clangd", {
  cmd = { "clangd", "--log=error" },
  filetypes = { "c", "cpp" },
  root_markers = { ".devcontainer", "compile_commands.json" },
})
vim.lsp.enable("clangd")

-- 1. before `up`: clangd runs on the host -----------------------------------------------------
vim.cmd.edit(HOST .. "/main.cpp")
local main_buf = vim.api.nvim_get_current_buf()
check("host clangd attached", wait(10000, function() return #vim.lsp.get_clients({ bufnr = main_buf }) == 1 end))
check("host client is not in a container", vim.lsp.get_clients({ bufnr = main_buf })[1].config._devcontainer_key == nil)

local events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = { "DevcontainerStarting", "DevcontainerAttached", "DevcontainerDetached" },
  callback = function(ev) table.insert(events, { ev.match, ev.data }) end,
})
local answers = {} -- kind -> answer (or fun(items) -> answer) for vim.ui.select
local orig_select = vim.ui.select
vim.ui.select = function(items, o, cb)
  local want = answers[o.kind or ""]
  if want == nil then return orig_select(items, o, cb) end
  answers[o.kind] = nil
  if type(want) == "function" then want = want(items) end
  cb(want)
end

-- a devcontainer:// buffer restored (by a session manager) before the container runs
local restored = "devcontainer://fc0123456789" .. E .. "/container-only/note.txt"
vim.cmd.edit(restored)
local restored_buf = vim.api.nvim_get_current_buf()
check("restored buffer waits for the container", vim.b[restored_buf].devcontainer_unread == true)
vim.cmd.buffer(main_buf)

-- 2. :Devcontainer up ------------------------------------------------------------------------
vim.cmd("Devcontainer up")
local session
check("session attached", wait(20000, function()
  session = require("devcontainer").get(HOST)
  return session ~= nil
end))
if not session then os.exit(1) end
check("remoteUser from image metadata", session.remote_user == "vscode", session.remote_user)
check("remoteEnv substituted", session.env.MY_VAR == REMOTE .. "/x", session.env.MY_VAR)
check("remoteEnv from metadata uses ${containerEnv}", session.env.FROM_META == vim.env.HOME .. "/meta", session.env.FROM_META)
check("postCreateCommand ran", vim.uv.fs_stat(E .. "/post-create-ran") ~= nil)
check("~/.gitconfig copied into the container", read(E .. "/home/.gitconfig") == "[user]\n\tname = e2e\n", read(E .. "/home/.gitconfig"))
check("dotfiles cloned and linked", vim.uv.fs_readlink(E .. "/home/.e2erc") == E .. "/home/dotfiles/.e2erc")
check("Starting and Attached events", wait(2000, function() return #events >= 2 end) and events[1][1] == "DevcontainerStarting"
  and events[2][1] == "DevcontainerAttached" and events[2][2].local_folder == HOST and events[2][2].key == session.key, events)
check("published ports read from docker inspect", session.published and session.published[9999] == 19999, session.published)
check("restored devcontainer:// buffer read after attach", wait(2000, function()
  return vim.api.nvim_buf_get_lines(restored_buf, 0, -1, false)[1] == "old" and not vim.b[restored_buf].devcontainer_unread
end), vim.api.nvim_buf_get_lines(restored_buf, 0, -1, false))

local client
check("clangd restarted inside the container", wait(15000, function()
  client = vim.lsp.get_clients({ bufnr = main_buf })[1]
  return client and client.config._devcontainer_key == session.key and client.initialized
end))
check("only one clangd attached", #vim.lsp.get_clients({ bufnr = main_buf }) == 1)
local docker_log = read(E .. "/docker.log") or ""
check("server spawned through docker exec -i", docker_log:find('"exec", "-i", "-u", "vscode"', 1, true)
  and docker_log:find("clangd", 1, true) ~= nil)
check("server binary looked up by the prefetch, not one exec per server",
  docker_log:find("for b; do", 1, true) ~= nil and docker_log:find('"sh", "clangd"]', 1, true) == nil)

-- 3. diagnostics come back with host URIs ----------------------------------------------------
check("diagnostics on host buffer", wait(15000, function()
  return #vim.diagnostic.get(main_buf, { severity = vim.diagnostic.severity.ERROR }) > 0
end), vim.diagnostic.get(main_buf))

local function definition(line, col)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(0) },
    position = { line = line, character = col },
  }
  local res = vim.lsp.buf_request_sync(0, "textDocument/definition", params, 10000) or {}
  for _, r in pairs(res) do
    local loc = r.result and (r.result[1] or r.result)
    if loc and (loc.uri or loc.targetUri) then return loc end
  end
end

-- 4. go to definition inside the workspace ---------------------------------------------------
local loc = definition(3, 20) -- helper
check("definition in workspace maps to host path", loc and loc.uri == vim.uri_from_fname(HOST .. "/util.h"), loc)

-- 5. go to definition of a system header -> devcontainer:// ----------------------------------
loc = definition(3, 3) -- printf
local prefix = "devcontainer://" .. session.key .. "/"
check("definition outside workspace is devcontainer://", loc and vim.startswith(loc.uri, prefix), loc)
if loc then
  vim.lsp.util.show_document(loc, client.offset_encoding, { focus = true })
  local rbuf = vim.api.nvim_get_current_buf()
  check("remote buffer loaded from container", vim.api.nvim_buf_line_count(rbuf) > 10
    and vim.bo[rbuf].buftype == "acwrite" and not vim.bo[rbuf].modified)
  check("remote buffer filetype detected", vim.bo[rbuf].filetype == "cpp" or vim.bo[rbuf].filetype == "c", vim.bo[rbuf].filetype)
  check("clangd attached to remote buffer", wait(5000, function()
    return #vim.lsp.get_clients({ bufnr = rbuf, name = "clangd" }) == 1
  end))
  local hover = vim.lsp.buf_request_sync(rbuf, "textDocument/hover", {
    textDocument = { uri = vim.uri_from_bufnr(rbuf) },
    position = { line = loc.range.start.line, character = loc.range.start.character },
  }, 10000)
  local ok_hover = false
  for _, r in pairs(hover or {}) do ok_hover = ok_hover or (r.result ~= nil and r.err == nil) end
  check("requests from remote buffer are answered", ok_hover, hover)
end

-- 6. writing a container-only file -----------------------------------------------------------
vim.cmd.edit(prefix .. E .. "/container-only/note.txt")
check("remote file read", vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "old")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "new", "content" })
vim.cmd("silent write")
check("remote file written", read(E .. "/container-only/note.txt") == "new\ncontent\n", read(E .. "/container-only/note.txt"))
check("buffer not modified after write", not vim.bo.modified)

vim.cmd.edit(prefix .. E .. "/container-only/")
local listing = vim.api.nvim_buf_get_lines(0, 0, -1, false)
check("remote directory listed", vim.tbl_contains(listing, "note.txt") and vim.bo.filetype == "devcontainer_dir", listing)
for i, l in ipairs(listing) do
  if l == "note.txt" then vim.api.nvim_win_set_cursor(0, { i, 0 }) end
end
vim.cmd.normal(vim.keycode("<CR>"))
check("<CR> in a listing opens the file", vim.api.nvim_buf_get_name(0) == prefix .. E .. "/container-only/note.txt", vim.api.nvim_buf_get_name(0))
vim.cmd.edit(prefix .. E .. "/container-only/brand-new.txt")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "fresh" })
vim.cmd("silent write")
check("new remote file created", read(E .. "/container-only/brand-new.txt") == "fresh\n", read(E .. "/container-only/brand-new.txt"))

-- 7. DAP proxy -------------------------------------------------------------------------------
local adapter = require("devcontainer").dap_adapter({ command = "python3", args = { root .. "/tests/fake-dap.py" } })
local resolved
adapter(function(a) resolved = a end, { cwd = HOST, program = HOST .. "/build/app" })
check("dap adapter resolved to local server", resolved and resolved.type == "server" and resolved.port > 0, resolved)

local dap = require("devcontainer.dap")
local msgs, seq = {}, 0
local feed = dap.framer(function(body) table.insert(msgs, vim.json.decode(body)) end)
local sock = vim.uv.new_tcp()
local connected = false
sock:connect("127.0.0.1", resolved.port, function(err)
  assert(not err, err)
  connected = true
  sock:read_start(function(_, data)
    if data then feed(data) end
  end)
end)
local function send(msg)
  seq = seq + 1
  msg.seq = seq
  sock:write(dap.frame(vim.json.encode(msg)))
  return seq
end
local function find(pred)
  for _, m in ipairs(msgs) do
    if pred(m) then return m end
  end
end
wait(5000, function() return connected end)
send({ type = "request", command = "initialize", arguments = { adapterID = "fake" } })
send({ type = "request", command = "launch", arguments = { program = HOST .. "/build/app", cwd = HOST, args = { HOST .. "/in.txt" } } })
local rit
wait(5000, function()
  rit = find(function(m) return m.type == "request" and m.command == "runInTerminal" end)
  return rit ~= nil
end)
local seen = find(function(m) return m.type == "event" and m.body and m.body.category == "seen" end)
local seen_args = seen and vim.json.decode(seen.body.output)
check("adapter received container paths", seen_args and seen_args.args.program == REMOTE .. "/build/app"
  and seen_args.args.cwd == REMOTE and seen_args.args.args[1] == REMOTE .. "/in.txt", seen_args)
check("adapter runs in the container workspace", seen_args and seen_args.cwd == REMOTE, seen_args)
check("runInTerminal rewritten to docker exec -it", rit and rit.arguments.args[1] == E .. "/bin/docker"
  and rit.arguments.args[3] == "-it" and rit.arguments.cwd == HOST
  and rit.arguments.args[#rit.arguments.args - 1] == REMOTE .. "/build/app", rit and rit.arguments)
if rit then
  sock:write(dap.frame(vim.json.encode({
    seq = 100, type = "response", request_seq = rit.seq, command = "runInTerminal", success = true,
    body = { processId = 4242 },
  })))
end
send({ type = "request", command = "stackTrace", arguments = { threadId = 1 } })
local st
wait(5000, function()
  st = find(function(m) return m.type == "response" and m.command == "stackTrace" end)
  return st ~= nil
end)
check("stack frames mapped back to host paths", st and st.body.stackFrames[1].source.path == HOST .. "/main.cpp"
  and st.body.stackFrames[2].source.path == "/usr/include/stdio.h", st)
local rit_reply = find(function(m) return m.type == "event" and m.body and m.body.output and not m.body.category end)
check("host pid stripped from runInTerminal response", rit_reply and not rit_reply.body.output:find("4242"), rit_reply)
send({ type = "request", command = "disconnect", arguments = {} })

-- 7a. TCP (server) adapters like codelldb: started in the container, reached through a relay ---
local tcp_resolved
require("devcontainer").dap_adapter({
  type = "server", port = "${port}",
  executable = { command = "python3", args = { root .. "/tests/fake-dap.py", "--port", "${port}" } },
})(function(a) tcp_resolved = a end, { cwd = HOST })
check("tcp adapter started in the container and proxied", wait(15000, function() return tcp_resolved ~= nil end)
  and tcp_resolved.type == "server" and tcp_resolved.port > 0, tcp_resolved)
if tcp_resolved then
  local tmsgs, tconnected = {}, false
  local tfeed = dap.framer(function(body) table.insert(tmsgs, vim.json.decode(body)) end)
  local tsock = vim.uv.new_tcp()
  tsock:connect("127.0.0.1", tcp_resolved.port, function(err)
    assert(not err, err)
    tconnected = true
    tsock:read_start(function(_, data) if data then tfeed(data) end end)
  end)
  wait(5000, function() return tconnected end)
  tsock:write(dap.frame(vim.json.encode({ seq = 1, type = "request", command = "initialize", arguments = {} })))
  tsock:write(dap.frame(vim.json.encode({ seq = 2, type = "request", command = "launch",
    arguments = { program = HOST .. "/build/app", cwd = HOST } })))
  local tseen
  wait(10000, function()
    for _, m in ipairs(tmsgs) do
      if m.type == "event" and m.body and m.body.category == "seen" then tseen = vim.json.decode(m.body.output) end
    end
    return tseen ~= nil
  end)
  check("tcp adapter got container paths", tseen and tseen.args.program == REMOTE .. "/build/app" and tseen.cwd == REMOTE, tseen)
  tsock:write(dap.frame(vim.json.encode({ seq = 3, type = "request", command = "disconnect", arguments = {} })))
  tsock:close()
end

-- 7d. port forwarding ----------------------------------------------------------------------------
local ports = require("devcontainer.ports")
local echo_port
-- a server "in the container" (same network as the host in this fake), bound to a port that is
-- therefore also taken on the host: the forward has to pick another local port
local echo = vim.system({ "python3", "-c", [[
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(5)
print(s.getsockname()[1], flush=True)
while True:
    c, _ = s.accept()
    c.sendall(b"echo:" + c.recv(1024))
    c.close()
]] }, { stdout = function(_, d) if d and not echo_port then echo_port = tonumber(d:match("%d+")) end end })
wait(5000, function() return echo_port ~= nil end)
local function roundtrip(local_port)
  local got, c = nil, vim.uv.new_tcp()
  c:connect("127.0.0.1", local_port, function(err)
    if err then got = "connect: " .. err return end
    c:read_start(function(_, d)
      if d then got = (got or "") .. d else c:close() end
    end)
    c:write("hi")
  end)
  wait(10000, function() return got == "echo:hi" end)
  return got
end
for _, kind in ipairs({ "bash", "python3" }) do
  require("devcontainer.config").options.ports.relay = function(h, p) return ports.relay_argv(kind, h, p) end
  require("devcontainer.profiles").invalidate()
  vim.cmd("Devcontainer forward " .. echo_port)
  local fwd
  for _, f in ipairs(ports.list(session)) do
    if f.port == echo_port then fwd = f end
  end
  check(kind .. " relay: forwarded to another local port", fwd and fwd.local_port ~= echo_port, fwd)
  if fwd then check(kind .. " relay: data goes through the container", roundtrip(fwd.local_port) == "echo:hi") end
  vim.cmd("Devcontainer unforward " .. echo_port)
  check(kind .. " relay: unforward stops it", #vim.tbl_filter(function(f) return f.port == echo_port end, ports.list(session)) == 0)
end
require("devcontainer.config").options.ports.relay = nil
require("devcontainer.profiles").invalidate()
echo:kill(9)

-- 7e. :Devcontainer files (vim.ui.select picker) ---------------------------------------------------
answers["devcontainer.files"] = function(items)
  for _, p in ipairs(items) do
    if p:match("note%.txt$") then return p end
  end
end
vim.cmd("Devcontainer files " .. E .. "/container-only")
check("files: container file opened as devcontainer://", vim.api.nvim_buf_get_name(0) == "devcontainer://" .. session.key .. E .. "/container-only/note.txt",
  vim.api.nvim_buf_get_name(0))

-- 7f. :Devcontainer init (no CLI: a minimal image config) -----------------------------------------
vim.fn.mkdir(E .. "/newproj/.git", "p")
answers["devcontainer.template"] = function(items) return items[1] end
answers["devcontainer.start"] = "Later"
require("devcontainer.templates").init(E .. "/newproj")
local created
check("init: devcontainer.json written and opened", wait(5000, function()
  created = read(E .. "/newproj/.devcontainer/devcontainer.json")
  return created ~= nil and vim.api.nvim_buf_get_name(0) == E .. "/newproj/.devcontainer/devcontainer.json"
end) and created:find('"image": "mcr.microsoft.com/devcontainers/cpp:latest"', 1, true) ~= nil, created)

-- 7b. :Devcontainer exec -----------------------------------------------------------------------
vim.cmd.buffer(main_buf)
vim.cmd("Devcontainer exec echo hi-from-$PWD")
local term_buf = vim.api.nvim_get_current_buf()
check("exec opens a terminal in the container workspace", wait(5000, function()
  return table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n"):find("hi-from-" .. REMOTE, 1, true) ~= nil
end), vim.api.nvim_buf_get_lines(term_buf, 0, -1, false))
vim.cmd("stopinsert")
vim.api.nvim_buf_delete(term_buf, { force = true })
check("info/statusline/checkhealth run", pcall(function()
  vim.cmd.buffer(main_buf)
  require("devcontainer").info()
  assert(require("devcontainer").statusline() == "e2e")
  vim.cmd("checkhealth devcontainer")
  vim.cmd("close")
end))

-- 7c. saving devcontainer.json offers a rebuild --------------------------------------------------
vim.cmd.edit(HOST .. "/.devcontainer/devcontainer.json")
answers["devcontainer.rebuild"] = "Rebuild now"
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// edited" })
vim.cmd("silent write")
check("rebuild offered and done after saving the config", wait(20000, function()
  local log_now = read(E .. "/docker.log") or ""
  return answers["devcontainer.rebuild"] == nil and select(2, log_now:gsub('"run", "%-d"', "")) == 2
    and require("devcontainer").get(HOST) ~= nil
end), answers)
session = require("devcontainer").get(HOST)
check("clangd back in the rebuilt container", wait(15000, function()
  local c = vim.lsp.get_clients({ bufnr = main_buf })[1]
  return c and c.config._devcontainer_key == session.key and c.initialized
end))

-- 8. :Devcontainer stop moves clangd back to the host ----------------------------------------
vim.cmd.buffer(main_buf)
vim.cmd("Devcontainer stop")
check("session detached", require("devcontainer").get(HOST) == nil)
check("remote buffers of the session wiped", #vim.tbl_filter(function(b)
  return vim.startswith(vim.api.nvim_buf_get_name(b), prefix) and vim.api.nvim_buf_is_loaded(b)
end, vim.api.nvim_list_bufs()) == 0)
check("clangd back on the host", wait(10000, function()
  local c = vim.lsp.get_clients({ bufnr = main_buf })[1]
  return c and c.config._devcontainer_key == nil and c.initialized
end))
check("Detached event", events[#events][1] == "DevcontainerDetached" and events[#events][2].local_folder == HOST, events[#events])

-- 8b. the config changed while no Neovim was watching: `up` asks before reusing the container --
write(HOST .. "/.devcontainer/devcontainer.json", (read(HOST .. "/.devcontainer/devcontainer.json") or "") .. "\n// changed on disk\n")
answers["devcontainer.rebuild"] = "Start the existing container"
vim.cmd.buffer(main_buf)
vim.cmd("Devcontainer up")
check("up asks about a container older than its config", wait(20000, function()
  return answers["devcontainer.rebuild"] == nil and require("devcontainer").get(HOST) ~= nil
end))
check("existing container reused", select(2, (read(E .. "/docker.log") or ""):gsub('"run", "%-d"', "")) == 2)
vim.cmd("Devcontainer stop")
wait(10000, function()
  local c = vim.lsp.get_clients({ bufnr = main_buf })[1]
  return c and c.config._devcontainer_key == nil and c.initialized
end)

-- 9. devcontainer CLI backend ----------------------------------------------------------------
write(E .. "/bin/devcontainer", read(root .. "/tests/fake-devcontainer-cli.py"))
vim.uv.fs_chmod(E .. "/bin/devcontainer", 493)
vim.env.FAKE_CLI_REMOTE = REMOTE
require("devcontainer").setup({ backend = "cli", cli = E .. "/bin/devcontainer", docker = E .. "/bin/docker" })
vim.cmd.buffer(main_buf)
vim.cmd("Devcontainer up")
check("cli backend attached", wait(20000, function()
  session = require("devcontainer").get(HOST)
  return session ~= nil
end))
if session then
  check("cli: container id / user / folder from `up` JSON", session.backend == "cli" and session.key == "cc0123456789"
    and session.remote_user == "vscode" and session.remote_folder == REMOTE, session)
  check("cli: merged configuration used", session.name == "e2e-cli" and session.env.FROM_CLI == REMOTE, session.env.FROM_CLI)
  check("cli: postAttachCommand ran", wait(5000, function() return vim.uv.fs_stat(E .. "/post-attach-ran") ~= nil end))
  check("cli: clangd moved into the new container", wait(15000, function()
    local c = vim.lsp.get_clients({ bufnr = main_buf })[1]
    return c and c.config._devcontainer_key == session.key and c.initialized
  end))
  loc = definition(3, 20)
  check("cli: definitions still map to host paths", loc and loc.uri == vim.uri_from_fname(HOST .. "/util.h"), loc)
end

-- 10. :Devcontainer down removes the container -------------------------------------------------
vim.cmd.buffer(main_buf)
require("devcontainer").down({ confirm = false })
check("down: detached and container removed", require("devcontainer").get(HOST) == nil and wait(5000, function()
  return (read(E .. "/docker.log") or ""):find('"rm", "-f", "cc0123456789', 1, true) ~= nil
end))

io.stdout:write(failures == 0 and "\nall e2e checks passed\n" or ("\n%d e2e checks failed\n"):format(failures))
for _, c in ipairs(vim.lsp.get_clients()) do c:stop(true) end
vim.wait(500)
os.exit(failures == 0 and 0 or 1)
