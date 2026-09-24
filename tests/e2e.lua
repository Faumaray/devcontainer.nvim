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
  "remoteEnv": { "MY_VAR": "${containerWorkspaceFolder}/x", },
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

require("devcontainer").setup({ backend = "docker", docker = E .. "/bin/docker" })
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

io.stdout:write(failures == 0 and "\nall e2e checks passed\n" or ("\n%d e2e checks failed\n"):format(failures))
for _, c in ipairs(vim.lsp.get_clients()) do c:stop(true) end
vim.wait(500)
os.exit(failures == 0 and 0 or 1)
