-- End-to-end test of the project layer: CMake and Cargo projects built, run, tested and
-- debugged "inside the container" (fake docker + mount namespace, see tests/fake-docker.py),
-- with the builtin runner and with overseer.nvim (OVERSEER=/path/to/overseer.nvim).
--
--   OVERSEER=/tmp/overseer.nvim nvim --headless --clean -l tests/e2e_project.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
vim.cmd.runtime("plugin/devcontainer.lua")

local E = "/tmp/dc-proj"
vim.fn.delete(E, "rf")
vim.fn.mkdir(E .. "/bin", "p")
vim.env.XDG_DATA_HOME = E .. "/data"
vim.env.XDG_STATE_HOME = E .. "/state"

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
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
vim.env.FAKE_DOCKER_LOG = E .. "/docker.log"
vim.env.FAKE_DOCKER_UNIQUE = "1"
local binds = {}

-- a real ssh-agent with a key; its relay dir is bind-mounted like git.agent_mount() does
local have_ssh = vim.fn.executable("ssh-agent") == 1 and vim.fn.executable("ssh-add") == 1
local agent_pid
if have_ssh then
  local sock = E .. "/agent.sock"
  agent_pid = tonumber((vim.system({ "ssh-agent", "-s", "-a", sock }, { text = true }):wait().stdout or "")
    :match("SSH_AGENT_PID=(%d+)"))
  vim.system({ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "e2e-key", "-f", E .. "/id_e2e" }):wait()
  vim.system({ "ssh-add", "-q", E .. "/id_e2e" }, { env = { SSH_AUTH_SOCK = sock } }):wait()
  vim.env.SSH_AUTH_SOCK = sock
  local dir = require("devcontainer.git").host_agent_dir()
  vim.fn.mkdir(dir, "p", 448)
  vim.fn.mkdir("/tmp/devcontainer-nvim-ssh", "p")
  table.insert(binds, dir .. ":/tmp/devcontainer-nvim-ssh")
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

-- one "container" per project: fake docker binds HOST at REMOTE for exec'd commands
local function project(name)
  local host, remote = E .. "/host/" .. name, E .. "/workspaces/" .. name
  vim.fn.mkdir(remote, "p")
  table.insert(binds, host .. ":" .. remote)
  vim.env.FAKE_DOCKER_BIND = table.concat(binds, ";")
  write(host .. "/.devcontainer/devcontainer.json", vim.json.encode({
    name = name,
    image = "fake:latest",
    workspaceFolder = remote,
    remoteEnv = { PATH = vim.env.HOME .. "/.cargo/bin:/usr/local/bin:${containerEnv:PATH}" },
  }))
  return host, remote
end

local done_events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "DevcontainerTaskDone",
  callback = function(ev) table.insert(done_events, ev.data) end,
})
--- run an ex command and wait for the task sequence to finish
local function run(cmd, ms)
  local n = #done_events
  vim.cmd(cmd)
  wait(ms or 120000, function() return #done_events > n end)
  return done_events[n + 1] or { ok = "timeout" }
end
local function attach(host)
  vim.cmd.edit(host .. "/.devcontainer/devcontainer.json")
  vim.env.FAKE_DOCKER_STATE = vim.fs.dirname(host) .. "/" .. vim.fs.basename(host) .. ".state.json"
  vim.cmd("Devcontainer up")
  local s
  wait(20000, function()
    s = require("devcontainer").get(host)
    return s ~= nil
  end)
  return s
end
local function qf_files()
  return vim.tbl_map(function(i)
    return i.bufnr > 0 and vim.api.nvim_buf_get_name(i.bufnr) or ""
  end, vim.tbl_filter(function(i) return i.valid == 1 end, vim.fn.getqflist()))
end

local dap_runs = {}
package.loaded.dap = {
  adapters = {},
  listeners = { on_config = {}, after = { event_terminated = {} } },
  run = function(cfg) table.insert(dap_runs, cfg) end,
}

require("devcontainer").setup({ backend = "docker", docker = E .. "/bin/docker", autostart = false,
  project = { runner = "builtin", cmake = { generator = "Ninja" } } })

-- CMake ---------------------------------------------------------------------------------------
local CM, CM_REMOTE = project("cm")
write(CM .. "/CMakeLists.txt", [[
cmake_minimum_required(VERSION 3.20)
project(sgsn CXX)
set(CMAKE_CXX_STANDARD 23)
add_executable(sgsn_app src/main.cpp)
target_include_directories(sgsn_app PRIVATE include)
enable_testing()
add_test(NAME smoke COMMAND sgsn_app)
]] .. (have_ssh and [[
# like FetchContent from a private repository over SSH: configure needs the agent
execute_process(COMMAND ssh-add -l RESULT_VARIABLE ssh_rc OUTPUT_VARIABLE ssh_out ERROR_VARIABLE ssh_err)
if(NOT ssh_rc EQUAL 0)
  message(FATAL_ERROR "no SSH agent in configure (${ssh_rc}): ${ssh_out}${ssh_err}")
endif()
file(WRITE ${CMAKE_BINARY_DIR}/ssh-agent.txt "${ssh_out}")
]] or ""))
local GOOD_CPP = [[
#include <cstdio>
#include <unistd.h>
#include "proj_only.h"
int main(int argc, char**) {
  char buf[4096];
  getcwd(buf, sizeof buf);
  std::printf("hello from sgsn cwd=%s args=%d\n", buf, argc - 1);
  return proj_only();
}
]]
write(CM .. "/src/main.cpp", GOOD_CPP)
-- only reachable through the compile database (-I include)
write(CM .. "/include/proj_only.h", "#pragma once\ninline int proj_only() { return 0; }\n")

-- clangd told to use `build`, while the build dir is build/Debug (or a profile's)
local have_clangd = vim.fn.executable("clangd") == 1
if have_clangd then
  vim.lsp.config("clangd", {
    cmd = { "clangd", "--compile-commands-dir=build", "--log=error" },
    filetypes = { "cpp" },
    root_markers = { ".devcontainer" },
  })
  vim.lsp.enable("clangd")
end
local function clangd(buf)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "clangd" })) do
    if not c:is_stopped() and c.initialized then return c end
  end
end
local function cdb_dir(buf)
  local c = clangd(buf)
  for _, a in ipairs(c and c.config._devcontainer_argv or {}) do
    local d = a:match("^%-%-compile%-commands%-dir=(.*)$")
    if d then return d end
  end
end
--- go to definition of proj_only(): resolves only when clangd has the compile flags
local function proj_only_definition(buf)
  local c = clangd(buf)
  if not c then return nil end
  local res = c:request_sync("textDocument/definition", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 7, character = 10 },
  }, 15000, buf)
  local r = res and res.result
  local loc = r and (r[1] or r)
  return loc and (loc.uri or loc.targetUri)
end

local s = attach(CM)
check("cmake: container attached", s ~= nil)
vim.cmd.edit(CM .. "/src/main.cpp")
local main_buf = vim.api.nvim_get_current_buf()
if have_clangd then
  check("clangd: --compile-commands-dir points at the build dir in the container", wait(15000, function()
    return cdb_dir(main_buf) == CM_REMOTE .. "/build/Debug"
  end), cdb_dir(main_buf))
  check("clangd: not configured yet, so no compile flags", proj_only_definition(main_buf) == nil)
end

local res = run("Devcontainer build")
check("cmake: build (auto-configure) succeeds", res.ok == true, res)
check("cmake: built in the container build dir", vim.uv.fs_stat(CM .. "/build/Debug/sgsn_app") ~= nil)
local log = read(E .. "/docker.log") or ""
check("cmake: cmake ran through docker exec", log:find('"cmake", "-S", ".", "-B", "build/Debug"', 1, true) ~= nil)
check("cmake: Ninja generator used", vim.uv.fs_stat(CM .. "/build/Debug/build.ninja") ~= nil)
check("cmake: compile_commands.json linked for clangd",
  vim.uv.fs_readlink(CM .. "/compile_commands.json") == "build/Debug/compile_commands.json")
check("cmake: compile database has container paths", (read(CM .. "/compile_commands.json") or ""):find(CM_REMOTE .. "/src/main.cpp", 1, true) ~= nil)
check("cmake: targets for completion", vim.tbl_contains(require("devcontainer.project").complete_targets("sgsn"), "sgsn_app"))
if have_ssh then
  check("ssh: configure in the container used the host's agent", (read(CM .. "/build/Debug/ssh-agent.txt") or ""):find("e2e-key", 1, true) ~= nil,
    read(CM .. "/build/Debug/ssh-agent.txt"))
  local health = {}
  local orig = vim.health
  vim.health = setmetatable({}, { __index = function(_, k)
    return function(msg) table.insert(health, k .. ": " .. msg) end
  end })
  pcall(require("devcontainer.health").check_ssh, s)
  vim.health = orig
  check("ssh: checkhealth reports what tasks see", vim.tbl_contains(health, "ok: tasks in the container reach the SSH agent (1 key)")
    and vim.tbl_contains(health, ("ok: SSH agent relay: this Neovim -> %s"):format(vim.env.SSH_AUTH_SOCK)), health)
end
if have_clangd then
  local def
  check("clangd: restarted after the first configure, uses the build dir's database", wait(20000, function()
    local c = clangd(main_buf)
    if not (c and c.config._devcontainer_cdb and c.config._devcontainer_cdb.ready) then return false end
    def = proj_only_definition(main_buf)
    return def == vim.uri_from_fname(CM .. "/include/proj_only.h")
  end), def)
end

-- profiles: the selected profile picks the build dir and adds configure args
require("devcontainer").add_profiles({
  asan = { desc = "sanitizers", project = { cmake = { build_dir = "build/${profile}-${buildType}", configure_args = { "-DDC_PROFILE=asan" } } } },
})
vim.cmd("Devcontainer profile asan")
check("profile: statusline shows it", require("devcontainer").statusline() == "cm [asan]", require("devcontainer").statusline())
res = run("Devcontainer build")
log = read(E .. "/docker.log") or ""
check("profile: build configured the profile's build dir with its args", res.ok == true
  and log:find('"build/asan%-Debug"[^\n]*"%-DDC_PROFILE=asan"') ~= nil and res.name == "cmake build (Debug, asan)", res)
check("profile: compile_commands.json follows the profile", vim.uv.fs_readlink(CM .. "/compile_commands.json") == "build/asan-Debug/compile_commands.json")
if have_clangd then
  check("clangd: follows the profile's build dir", wait(20000, function()
    return cdb_dir(main_buf) == CM_REMOTE .. "/build/asan-Debug"
  end), cdb_dir(main_buf))
end
vim.cmd("Devcontainer profile none")
if have_clangd then
  check("clangd: back to build/Debug with the profile", wait(20000, function()
    return cdb_dir(main_buf) == CM_REMOTE .. "/build/Debug"
  end), cdb_dir(main_buf))
end
local n_configure = select(2, log:gsub('"cmake", "%-S"', ""))
res = run("Devcontainer build")
log = read(E .. "/docker.log") or ""
check("profile: back to the default build dir without reconfiguring", res.ok == true
  and select(2, log:gsub('"cmake", "%-S"', "")) == n_configure and log:find('"cmake", "--build", "build/Debug"', #log - 2000, true) ~= nil)

write(CM .. "/src/main.cpp", 'int main() {\n  int x = "not an int";\n  return x;\n}\n')
res = run("Devcontainer build")
check("cmake: broken build fails", res.ok == false, res)
check("cmake: compiler error mapped to the host file", vim.tbl_contains(qf_files(), CM .. "/src/main.cpp"), vim.fn.getqflist())
check("cmake: no buffers for container paths", vim.fn.bufnr(CM_REMOTE .. "/src/main.cpp") == -1)
write(CM .. "/src/main.cpp", GOOD_CPP)

res = run("Devcontainer run sgsn_app -- a b")
local term = vim.api.nvim_get_current_buf()
local out = table.concat(vim.api.nvim_buf_get_lines(term, 0, -1, false), "\n")
check("cmake: run shows program output", out:find("hello from sgsn", 1, true) ~= nil, out)
check("cmake: program runs in the container exe dir with args",
  out:find("cwd=" .. CM_REMOTE .. "/build/Debug args=2", 1, true) ~= nil, out)
vim.cmd("stopinsert")
vim.cmd("bwipeout!")

res = run("Devcontainer test")
check("cmake: ctest passes", res.ok == true, res)

res = run("Devcontainer debug")
check("cmake: debug builds then starts nvim-dap", res.ok == true and #dap_runs == 1, res)
local cfg = dap_runs[1] or {}
check("cmake: launch config uses host paths (the DAP proxy maps them)",
  cfg.program == CM .. "/build/Debug/sgsn_app" and cfg.cwd == CM .. "/build/Debug" and cfg.type == "gdb", cfg)
check("cmake: gdb adapter registered", type(package.loaded.dap.adapters.gdb) == "function")

-- Cargo ---------------------------------------------------------------------------------------
local RS, RS_REMOTE = project("rs")
write(RS .. "/Cargo.toml", '[workspace]\nmembers = ["gtpd", "tools"]\nresolver = "2"\n')
write(RS .. "/gtpd/Cargo.toml", '[package]\nname = "gtpd"\nversion = "0.1.0"\nedition = "2021"\n')
local GOOD_RS = 'fn main() {\n    println!("gtpd up in {}", std::env::current_dir().unwrap().display());\n}\n'
write(RS .. "/gtpd/src/main.rs", GOOD_RS)
write(RS .. "/tools/Cargo.toml", '[package]\nname = "tools"\nversion = "0.1.0"\nedition = "2021"\n')
write(RS .. "/tools/src/main.rs", 'fn main() {}\n#[test]\nfn works() { assert_eq!(2 + 2, 4); }\n')
s = attach(RS)
check("cargo: container attached", s ~= nil)
vim.cmd.edit(RS .. "/gtpd/src/main.rs")

res = run("Devcontainer build")
check("cargo: workspace build succeeds", res.ok == true, res)
check("cargo: binaries in target/debug", vim.uv.fs_stat(RS .. "/target/debug/gtpd") ~= nil)

write(RS .. "/gtpd/src/main.rs", 'fn main() {\n    let x: i32 = "nope";\n}\n')
res = run("Devcontainer build")
check("cargo: broken build fails", res.ok == false, res)
check("cargo: rustc error points at the host file", vim.tbl_contains(qf_files(), RS .. "/gtpd/src/main.rs"), vim.fn.getqflist())
write(RS .. "/gtpd/src/main.rs", GOOD_RS)

res = run("Devcontainer run gtpd")
out = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
check("cargo: cargo run in the container", res.ok == true and out:find("gtpd up in " .. RS_REMOTE, 1, true) ~= nil, out)
vim.cmd("stopinsert")
vim.cmd("bwipeout!")

res = run("Devcontainer test")
check("cargo: cargo test passes", res.ok == true, res)

dap_runs = {}
res = run("Devcontainer debug gtpd")
cfg = dap_runs[1] or {}
check("cargo: debug launches target/debug/gtpd", cfg.program == RS .. "/target/debug/gtpd", cfg)

-- overseer ------------------------------------------------------------------------------------
if vim.env.OVERSEER and vim.uv.fs_stat(vim.env.OVERSEER) then
  vim.opt.rtp:append(vim.env.OVERSEER)
  local overseer = require("overseer")
  overseer.setup({ dap = false })
  require("devcontainer.config").options.project.runner = "overseer"

  vim.cmd.edit(CM .. "/src/main.cpp")
  write(CM .. "/src/main.cpp", 'int main() {\n  int x = "not an int";\n  return x;\n}\n')
  res = run("Devcontainer build")
  check("overseer: failing build reported", res.ok == false, res)
  check("overseer: quickfix entries mapped to host files", vim.tbl_contains(qf_files(), CM .. "/src/main.cpp"), vim.fn.getqflist())
  write(CM .. "/src/main.cpp", GOOD_CPP)
  res = run("Devcontainer build")
  check("overseer: build succeeds", res.ok == true, res)

  -- our templates show up in :OverseerRun, and other templates get wrapped too
  overseer.register_template({
    name = "print pwd",
    builder = function() return { cmd = { "sh", "-c", "echo PWD=$PWD" }, cwd = CM } end,
  })
  local names, listed = {}, false
  require("overseer.template").list({ dir = CM }, function(tmpls)
    for _, t in ipairs(tmpls) do names[t.name] = true end
    listed = true
  end)
  wait(10000, function() return listed end)
  check("overseer: project templates listed", names["cmake build"] and names["cmake test"] and names["cmake configure"], vim.tbl_keys(names))
  local task
  overseer.run_task({ name = "print pwd" }, function(t) task = t end)
  wait(10000, function() return task and task:is_complete() end)
  local lines = task and vim.api.nvim_buf_get_lines(task:get_bufnr(), 0, -1, false) or {}
  check("overseer: other templates run in the container", table.concat(lines, "\n"):find("PWD=" .. CM_REMOTE, 1, true) ~= nil, lines)
  check("overseer: task definition stays container-agnostic", task and task.cmd[1] == "sh", task and task.cmd)
else
  io.stdout:write("skip overseer checks (set OVERSEER=/path/to/overseer.nvim)\n")
end

if agent_pid then vim.uv.kill(agent_pid, 15) end
io.stdout:write(failures == 0 and "\nall project e2e checks passed\n" or ("\n%d project e2e checks failed\n"):format(failures))
os.exit(failures == 0 and 0 or 1)
