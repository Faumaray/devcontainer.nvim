-- nvim --headless -l tests/unit.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local failures, count = 0, 0
local function test(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if not ok then
    failures = failures + 1
    io.stdout:write(("FAIL %s\n  %s\n"):format(name, err))
  else
    io.stdout:write(("ok   %s\n"):format(name))
  end
end
local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error(("%s\nexpected: %s\n     got: %s"):format(msg or "", vim.inspect(b), vim.inspect(a)), 2)
  end
end

for _, m in ipairs({
  "devcontainer", "devcontainer.config", "devcontainer.log", "devcontainer.async", "devcontainer.jsonc",
  "devcontainer.spec", "devcontainer.paths", "devcontainer.session", "devcontainer.lsp", "devcontainer.dap",
  "devcontainer.remote_fs", "devcontainer.health", "devcontainer.backend.cli", "devcontainer.backend.docker",
}) do
  test("require " .. m, function() require(m) end)
end

local jsonc = require("devcontainer.jsonc")
test("jsonc comments, trailing commas, strings", function()
  local v = jsonc.decode([[
  // comment
  {
    "name": "a // not a comment", /* block */
    "url": "http://x/*y*/",
    "esc": "q\"// still string",
    "list": [1, 2, 3,],
    "obj": { "k": "v", },
  }]])
  eq(v.name, "a // not a comment")
  eq(v.url, "http://x/*y*/")
  eq(v.esc, 'q"// still string')
  eq(v.list, { 1, 2, 3 })
  eq(v.obj, { k = "v" })
end)

local spec = require("devcontainer.spec")
test("spec.substitute", function()
  vim.env.DC_TEST = "hello"
  local out = spec.substitute({
    a = "${localWorkspaceFolder}/x",
    b = "${containerWorkspaceFolderBasename}",
    c = { "${localEnv:DC_TEST}", "${localEnv:NOPE:dflt}" },
    d = "${containerEnv:PATH}:/extra",
    e = "${unknown}",
  }, { local_folder = "/home/me/proj", remote_folder = "/workspaces/proj", container_env = { PATH = "/usr/bin" } })
  eq(out, { a = "/home/me/proj/x", b = "proj", c = { "hello", "dflt" }, d = "/usr/bin:/extra", e = "${unknown}" })
end)

test("spec.commands", function()
  eq(spec.commands("make"), { { "/bin/sh", "-c", "make" } })
  eq(spec.commands({ "a", "b" }), { { "a", "b" } })
  eq(spec.commands({ z = "two", a = { "one" } }), { { "one" }, { "/bin/sh", "-c", "two" } })
  eq(spec.commands(nil), {})
end)

local paths = require("devcontainer.paths")
local tr = paths.new({ local_roots = { "/home/me/proj" }, remote_root = "/workspaces/proj", scheme = "devcontainer://abc" })

test("translator: workspace URIs both ways", function()
  local params = {
    textDocument = { uri = "file:///home/me/proj/src/a.cpp", text = "#include \"/home/me/proj/x.h\"" },
    rootUri = "file:///home/me/proj",
    rootPath = "/home/me/proj",
    other = "file:///etc/hosts",
  }
  local r = tr:to_remote(params)
  eq(r.textDocument.uri, "file:///workspaces/proj/src/a.cpp")
  eq(r.textDocument.text, params.textDocument.text, "document text must be verbatim")
  eq(r.rootUri, "file:///workspaces/proj")
  eq(r.rootPath, "/workspaces/proj")
  eq(r.other, "file:///etc/hosts")
  eq(params.textDocument.uri, "file:///home/me/proj/src/a.cpp", "input must not be mutated")
  eq(tr:to_local(r).textDocument.uri, "file:///home/me/proj/src/a.cpp")
end)

test("translator: container-only files -> devcontainer:// and back", function()
  local loc = tr:to_local({ uri = "file:///usr/include/c++/13/vector", range = {} })
  eq(loc.uri, "devcontainer://abc/usr/include/c++/13/vector")
  eq(tr:to_remote(loc).uri, "file:///usr/include/c++/13/vector")
end)

test("translator: WorkspaceEdit.changes keys", function()
  local edit = tr:to_local({ changes = { ["file:///workspaces/proj/a.cpp"] = { { newText = "/workspaces/proj" } } } })
  eq(next(edit.changes), "file:///home/me/proj/a.cpp")
  eq(edit.changes["file:///home/me/proj/a.cpp"][1].newText, "/workspaces/proj")
end)

test("translator: markdown links in hover", function()
  local h = tr:to_local({ contents = { kind = "markdown", value = "see [a](file:///workspaces/proj/a.h#L3)" } })
  eq(h.contents.value, "see [a](file:///home/me/proj/a.h#L3)")
end)

test("translator: keeps empty dicts / metatables through json", function()
  local msg = vim.json.decode('{"a":{},"b":[],"c":{"uri":"file:///home/me/proj/x"}}')
  local out = vim.json.encode(tr:to_remote(msg))
  assert(out:find('"a":{}', 1, true), out)
  assert(out:find('"b":[]', 1, true), out)
  assert(out:find("/workspaces/proj/x", 1, true), out)
end)

test("translator: root prefix must end at a path boundary", function()
  eq(tr:path_to_remote("/home/me/project2/x"), nil)
  eq(tr:path_to_remote("/home/me/proj"), "/workspaces/proj")
end)

local session_mod = require("devcontainer.session")
local function fake_session(which)
  local s = session_mod.new({
    container_id = "0123456789abcdef", local_folder = "/home/me/proj", remote_folder = "/workspaces/proj/",
    remote_user = "vscode", docker = "docker",
  })
  s.env = { PATH = "/usr/local/bin:/usr/bin" }
  s.which = function(_, bin) return which[bin] end
  return s
end

test("session.exec_argv", function()
  local s = fake_session({})
  eq(s.remote_folder, "/workspaces/proj")
  eq(s:exec_argv({ "clangd" }, { stdin = true }), {
    "docker", "exec", "-i", "-u", "vscode", "-w", "/workspaces/proj", "-e", "PATH=/usr/local/bin:/usr/bin",
    "0123456789abcdef", "clangd",
  })
  eq(s:exec_argv({ "sh" }, { tty = true, env = false, cwd = "/tmp" }), {
    "docker", "exec", "-it", "-u", "vscode", "-w", "/tmp", "0123456789abcdef", "sh",
  })
end)

test("session registry find", function()
  local s = fake_session({})
  session_mod.register(s)
  eq(session_mod.find("/home/me/proj/src/a.cpp"), s)
  eq(session_mod.find("/home/me/proj"), s)
  eq(session_mod.find("/home/me/proj2/a.cpp"), nil)
  eq(session_mod.find("devcontainer://0123456789ab/usr/include/stdio.h"), s)
  session_mod.unregister(s)
end)

local lsp = require("devcontainer.lsp")
require("devcontainer.config").set({})
test("lsp.rewrite: runs managed server in the container", function()
  local s = fake_session({ clangd = "/usr/bin/clangd" })
  session_mod.register(s)
  local cfg = { name = "clangd", cmd = { "/home/me/.local/share/nvim/mason/bin/clangd", "--compile-commands-dir=/home/me/proj/build" }, root_dir = "/home/me/proj" }
  s.which = function(_, bin) return bin == "clangd" and "/usr/bin/clangd" or nil end
  local new = lsp.rewrite(cfg)
  eq(type(new.cmd), "function")
  eq(new._devcontainer_key, s.key)
  eq(new._devcontainer_host_cmd, cfg.cmd)
  eq(type(cfg.cmd), "table", "original config untouched")
  -- restart after the container is gone: back to the host command when the host has it
  session_mod.unregister(s)
  eq(lsp.rewrite(new), nil, "not installed on the host: not started")
  local sh = vim.fn.exepath("sh")
  session_mod.register(s)
  local moved = lsp.rewrite({ name = "clangd", cmd = { sh, "-c", "true" }, root_dir = "/home/me/proj" })
  session_mod.unregister(s)
  local back = lsp.rewrite(moved)
  eq(back.cmd, { sh, "-c", "true" })
  eq(back._devcontainer_key, nil)
end)

test("lsp.rewrite: fallback + exclude", function()
  local s = fake_session({})
  session_mod.register(s)
  local cfg = { name = "clangd", cmd = { "clangd" }, root_dir = "/home/me/proj/sub" }
  eq(lsp.rewrite(cfg).cmd, cfg.cmd)
  require("devcontainer.config").set({ lsp = { fallback = "none" } })
  s.warned = {}
  eq(lsp.rewrite(cfg), nil)
  require("devcontainer.config").set({ lsp = { exclude = { "clangd" } } })
  eq(lsp.rewrite(cfg), cfg)
  require("devcontainer.config").set({})
  session_mod.unregister(s)
end)

test("lsp.cmd helper: host-less servers still move into the container", function()
  local s = fake_session({ clangd = "/usr/bin/clangd" })
  session_mod.register(s)
  local fn = lsp.cmd({ "clangd", "--background-index" })
  local new = lsp.rewrite({ name = "clangd", cmd = fn, root_dir = "/home/me/proj" })
  eq(new._devcontainer_key, s.key)
  eq(new._devcontainer_host_cmd, { "clangd", "--background-index" })
  session_mod.unregister(s)
  -- detached: the host command when the host has it, else nothing (no spawn error)
  local missing = lsp.cmd({ "definitely-not-on-this-host" })
  eq(lsp.rewrite({ name = "clangd", cmd = missing, root_dir = "/home/me/proj" }), nil)
  local on_host = lsp.cmd({ vim.fn.exepath("sh") })
  eq(lsp.rewrite({ name = "clangd", cmd = on_host, root_dir = "/home/me/proj" }).cmd, on_host)
end)

local dap = require("devcontainer.dap")
test("dap framer handles split and merged chunks", function()
  local got = {}
  local feed = dap.framer(function(b) got[#got + 1] = b end)
  local a, b = dap.frame('{"seq":1}'), dap.frame('{"seq":2,"x":"é"}')
  local all = a .. b
  feed(all:sub(1, 5))
  feed(all:sub(6, #a + 3))
  feed(all:sub(#a + 4))
  eq(got, { '{"seq":1}', '{"seq":2,"x":"é"}' })
end)

test("dap rewrite: launch args + runInTerminal", function()
  local s = fake_session({})
  local state = { run_in_terminal = {} }
  local launch = dap.rewrite_to_adapter(s, vim.json.decode([[{"seq":2,"type":"request","command":"launch",
    "arguments":{"program":"/home/me/proj/build/app","cwd":"/home/me/proj","args":["--cfg","/home/me/proj/a.cfg"]}}]]), state)
  eq(launch.arguments.program, "/workspaces/proj/build/app")
  eq(launch.arguments.cwd, "/workspaces/proj")
  eq(launch.arguments.args[2], "/workspaces/proj/a.cfg")

  local frame = dap.rewrite_to_client(s, vim.json.decode([[{"seq":9,"type":"response","command":"stackTrace",
    "body":{"stackFrames":[{"name":"main","source":{"path":"/workspaces/proj/main.cpp"}}]}}]]), state)
  eq(frame.body.stackFrames[1].source.path, "/home/me/proj/main.cpp")

  local rit = dap.rewrite_to_client(s, vim.json.decode([[{"seq":5,"type":"request","command":"runInTerminal",
    "arguments":{"kind":"integrated","cwd":"/workspaces/proj","args":["/workspaces/proj/build/app"],"env":{"A":"1","B":null}}}]]), state)
  eq(rit.arguments.cwd, "/home/me/proj")
  eq(rit.arguments.env, nil)
  eq(rit.arguments.args, {
    "docker", "exec", "-it", "-u", "vscode", "-w", "/workspaces/proj", "-e", "A=1", "-e", "PATH=/usr/local/bin:/usr/bin",
    "0123456789abcdef", "/workspaces/proj/build/app",
  })
  local resp = dap.rewrite_to_adapter(s, { type = "response", request_seq = 5, body = { processId = 42 } }, state)
  eq(resp.body.processId, nil)
end)

-- project layer ------------------------------------------------------------------------------

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local function writef(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end
require("devcontainer.store")._reset(tmp .. "/state.json")

test("store: set/get/clear per project", function()
  local store = require("devcontainer.store")
  store.set("/p", "cmake.preset", "debug")
  store.set("/p", "autostart", "always")
  require("devcontainer.store")._reset()
  eq(store.get("/p"), { cmake = { preset = "debug" }, autostart = "always" })
  store.clear("/p", "autostart")
  eq(store.get("/p").autostart, nil)
  store.clear("/p")
  eq(store.get("/p"), {})
end)

local cmake = require("devcontainer.project.cmake")
local project = require("devcontainer.project")

test("cmake: topmost CMakeLists.txt within the boundary", function()
  writef(tmp .. "/mono/CMakeLists.txt", "")
  writef(tmp .. "/mono/sgsn/CMakeLists.txt", "")
  writef(tmp .. "/mono/sgsn/src/gtp/CMakeLists.txt", "")
  eq(cmake.detect(tmp .. "/mono/sgsn/src/gtp", tmp .. "/mono"), tmp .. "/mono")
  eq(cmake.detect(tmp .. "/mono/sgsn/src/gtp", tmp .. "/mono/sgsn"), tmp .. "/mono/sgsn")
end)

test("cmake presets: include, inherits, macros, hidden", function()
  local root = tmp .. "/presets"
  writef(root .. "/CMakeLists.txt", "")
  writef(root .. "/CMakePresets.json", vim.json.encode({
    version = 6,
    include = { "cmake/base.json" },
    configurePresets = {
      { name = "debug", inherits = "base", displayName = "Debug", cacheVariables = { CMAKE_BUILD_TYPE = "Debug" } },
      { name = "release", inherits = { "base" }, binaryDir = "${sourceDir}/out/rel-${sourceDirName}",
        cacheVariables = { CMAKE_BUILD_TYPE = { type = "STRING", value = "Release" } } },
    },
    buildPresets = { { name = "build-debug", configurePreset = "debug" } },
    testPresets = { { name = "test-debug", configurePreset = "debug" } },
  }))
  writef(root .. "/cmake/base.json", vim.json.encode({
    version = 6,
    configurePresets = { { name = "base", hidden = true, generator = "Ninja", binaryDir = "${sourceDir}/build/${presetName}" } },
  }))
  local p = cmake.presets(root)
  eq(p.order, { "debug", "release" })
  eq(p.configure.base, nil, "hidden presets are not offered")
  eq(p.configure.debug.generator, "Ninja")

  local ctx = setmetatable({ root = root, provider = cmake, state = {}, opts = require("devcontainer.config").options.project.cmake }, { __index = {
    exec_path = function(_, x) return x end, host_path = function(_, x) return x end,
    task = function(_, t) t.cwd = root; return t end, set = function(self, k, v) self.state[k] = v end,
  } })
  local r = cmake.resolve(ctx)
  eq({ r.preset, r.build_type, r.host_build, r.build_arg, r.build_preset, r.test_preset },
     { "debug", "Debug", root .. "/build/debug", "build/debug", "build-debug", "test-debug" })
  ctx.state.preset = "release"
  r = cmake.resolve(ctx)
  eq({ r.build_type, r.host_build, r.build_preset }, { "Release", root .. "/out/rel-presets", nil })

  local steps = cmake.actions[2].run(ctx, { extra = {} }) -- build, not configured yet
  local cmds = vim.tbl_map(function(st) return type(st) == "table" and st.cmd or "fn" end, steps)
  eq(cmds, { "fn", { "cmake", "--preset", "release", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON" },
    { "cmake", "--build", "out/rel-presets", "--config", "Release", "--parallel" } })
end)

test("cmake without presets: build type dir, ctest, generator on first configure", function()
  local root = tmp .. "/plain"
  writef(root .. "/CMakeLists.txt", "")
  local opts = vim.deepcopy(require("devcontainer.config").options.project.cmake)
  opts.generator = "Ninja"
  local ctx = setmetatable({ root = root, provider = cmake, state = { build_type = "Release" }, opts = opts }, { __index = {
    exec_path = function(_, x) return x end, task = function(_, t) t.cwd = root; return t end,
  } })
  local steps = cmake.actions[1].run(ctx, { extra = { "-DFOO=1" } })
  eq(steps[#steps].cmd, { "cmake", "-S", ".", "-B", "build/Release", "-DCMAKE_BUILD_TYPE=Release", "-G", "Ninja",
    "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON", "-DFOO=1" })
  eq(steps[#steps].after, { provider = "cmake", root = root, action = "configure" })
  local test_steps = cmake.actions[4].run(ctx, { extra = { "-R", "gtp" }, template = true })
  eq(test_steps[1].cmd, { "ctest", "--test-dir", "build/Release", "-C", "Release", "--output-on-failure", "-R", "gtp" })
end)

local cargo = require("devcontainer.project.cargo")
test("cargo: workspace root wins over member crate", function()
  writef(tmp .. "/ws/Cargo.toml", '[workspace]\nmembers = ["crates/*"]\n')
  writef(tmp .. "/ws/crates/gtp/Cargo.toml", '[package]\nname = "gtp"\n')
  writef(tmp .. "/single/Cargo.toml", '[package]\nname = "single"\n')
  eq(cargo.detect(tmp .. "/ws/crates/gtp/src", tmp .. "/ws"), tmp .. "/ws")
  eq(cargo.detect(tmp .. "/single/src", tmp .. "/single"), tmp .. "/single")
end)

test("cargo: commands follow the profile", function()
  local ctx = setmetatable({ root = "/r", provider = cargo, state = { profile = "release" }, opts = { build_args = {}, test_args = { "--no-fail-fast" } } }, { __index = {
    task = function(_, t) t.cwd = "/r"; return t end,
  } })
  eq(cargo.actions[2].run(ctx, { extra = {} })[1].cmd, { "cargo", "build", "--release" })
  eq(cargo.actions[4].run(ctx, { extra = { "gtp::" } })[1].cmd, { "cargo", "test", "--release", "--no-fail-fast", "gtp::" })
  ctx.state.profile = "ci"
  eq(cargo.actions[2].run(ctx, { extra = {} })[1].cmd, { "cargo", "build", "--profile", "ci" })
end)

test("project.parse_args", function()
  eq(project.parse_args("run", "app -- --port 2123"), { target = "app", extra = { "--port", "2123" } })
  eq(project.parse_args("build", "--verbose"), { extra = { "--verbose" } })
  eq(project.parse_args("test", "gtp -- --nocapture"), { extra = { "gtp", "--nocapture" } })
end)

local runner = require("devcontainer.runner")
test("runner.map_line only rewrites whole workspace paths", function()
  local s = fake_session({})
  eq(runner.map_line(s, "/workspaces/proj/src/a.cpp:3:5: error: x"), "/home/me/proj/src/a.cpp:3:5: error: x")
  eq(runner.map_line(s, "In file included from /workspaces/proj/a.h:1,"), "In file included from /home/me/proj/a.h:1,")
  eq(runner.map_line(s, "/workspaces/project2/a.cpp"), "/workspaces/project2/a.cpp")
  eq(runner.map_line(s, "/x/workspaces/proj/a.cpp"), "/x/workspaces/proj/a.cpp")
  eq(runner.map_line(nil, "/workspaces/proj/a"), "/workspaces/proj/a")
end)

test("runner.parse + fix_items: relative names, container-only headers", function()
  local root = tmp .. "/qf"
  local s = session_mod.new({ container_id = "0123456789abcdef", local_folder = root, remote_folder = "/workspaces/qf", docker = "docker" })
  writef(root .. "/src/main.rs", "")
  local items = runner.parse({
    "error[E0308]: mismatched types",
    " --> src/main.rs:4:18",
    "/usr/lib/gcc/x86_64-linux-gnu/13/include/foo.h:1:2: error: boom",
  }, runner.efm("cargo") .. "," .. runner.efm("gcc"), root)
  local valid = vim.tbl_filter(function(i) return i.valid == 1 end, items)
  eq(vim.api.nvim_buf_get_name(valid[1].bufnr), root .. "/src/main.rs")
  eq(valid[1].lnum, 4)
  assert(runner.fix_items(valid, s))
  eq(valid[1].bufnr ~= nil, true, "host files keep their buffer")
  eq(valid[2].filename, "devcontainer://0123456789ab/usr/lib/gcc/x86_64-linux-gnu/13/include/foo.h")
end)

test("autostart: ask once, remember always/never", function()
  local autostart = require("devcontainer.autostart")
  local dcm = require("devcontainer")
  local started, answers, prompts = {}, {}, 0
  local orig_up, orig_select = dcm.up, vim.ui.select
  dcm.up = function(o) table.insert(started, o.path) end
  vim.ui.select = function(items, _, cb)
    prompts = prompts + 1
    local want = table.remove(answers, 1)
    for _, it in ipairs(items) do if it.action == want then return cb(it) end end
    cb(nil)
  end
  for _, n in ipairs({ "a", "b", "c" }) do writef(tmp .. "/as/" .. n .. "/.devcontainer/devcontainer.json", "{}") end
  local root = function(n) return tmp .. "/as/" .. n end
  require("devcontainer.config").set({})
  autostart._reset()
  answers = { "skip", "always", "never" }
  autostart.check(root("a") .. "/src/x.cpp", { force = true })
  autostart.check(root("a"), { force = true }) -- same project: not asked again this session
  autostart.check(root("b"), { force = true })
  autostart.check(root("c"), { force = true })
  eq(prompts, 3)
  eq(started, { root("b") })
  autostart._reset()
  started = {}
  autostart.check(root("a"), { force = true }) -- "not now" is not remembered
  autostart.check(root("b"), { force = true }) -- always
  autostart.check(root("c"), { force = true }) -- never
  eq(prompts, 4)
  eq(started, { root("b") })
  autostart.forget(root("c"))
  autostart.check(root("c"), { force = true })
  eq(prompts, 5)
  require("devcontainer.config").set({ autostart = false })
  autostart._reset()
  autostart.check(root("b"), { force = true })
  eq(#started, 1)
  require("devcontainer.config").set({})
  dcm.up, vim.ui.select = orig_up, orig_select
end)

test("lsp: host-less servers adopted while attached, not spawned on the host when detached", function()
  require("devcontainer.config").set({ lsp = { exclude = { "excluded_srv" } } })
  lsp.patch()
  vim.lsp.config("hostless_srv", { cmd = { "definitely-not-on-this-host" }, filetypes = { "hostless" } })
  vim.lsp.config("excluded_srv", { cmd = { "definitely-not-on-this-host" }, filetypes = { "hostless" } })
  vim.lsp.enable({ "hostless_srv", "excluded_srv" })
  eq(type(vim.lsp.config.hostless_srv.cmd), "table", "nothing attached: config untouched")
  local s = fake_session({})
  session_mod.register(s)
  vim.lsp.enable({ "hostless_srv", "excluded_srv" })
  eq(type(vim.lsp.config.hostless_srv.cmd), "function", "adopted: vim.lsp.enable accepts it now")
  eq(type(vim.lsp.config.excluded_srv.cmd), "table", "excluded servers are left alone")
  session_mod.unregister(s)
  local cfg = { name = "hostless_srv", cmd = lsp.cmd({ "definitely-not-on-this-host" }), root_dir = "/home/me/proj" }
  eq(lsp.rewrite(cfg), nil, "detached: not started (no spawn error)")
  vim.lsp.enable({ "hostless_srv", "excluded_srv" }, false)
  require("devcontainer.config").set({})
end)

-- fixes ----------------------------------------------------------------------------------------

test("spec.find_root needs a config, not just a .devcontainer folder", function()
  local base = tmp .. "/roots"
  writef(base .. "/outer/.devcontainer/devcontainer.json", "{}")
  writef(base .. "/outer/inner/.devcontainer/Dockerfile", "FROM x")
  vim.fn.mkdir(base .. "/outer/inner/src", "p")
  eq(spec.find_root(base .. "/outer/inner/src"), base .. "/outer")
  writef(base .. "/outer/inner/.devcontainer/cpp/devcontainer.json", "{}")
  eq(spec.find_root(base .. "/outer/inner/src"), base .. "/outer/inner")
  eq(spec.find_root_cached(base .. "/outer/inner/src"), base .. "/outer/inner")
end)

test("paths.replace_root / session:map_arg replace whole paths only", function()
  eq(paths.replace_root("a /ws/p:1 /ws/p/x '/ws/p' /ws/p2 /x/ws/p", "/ws/p", "/h"), "a /h:1 /h/x '/h' /ws/p2 /x/ws/p")
  local s = fake_session({})
  eq(s:map_arg("--compile-commands-dir=/home/me/proj/build"), "--compile-commands-dir=/workspaces/proj/build")
  eq(s:map_arg("cd /home/me/proj && make -C /home/me/proj/sub"), "cd /workspaces/proj && make -C /workspaces/proj/sub")
  eq(s:map_arg("/home/me/project2/x"), "/home/me/project2/x")
  eq(s:map_arg(42), 42)
end)

test("get(path) does not fall back to the current session", function()
  local s = fake_session({})
  session_mod.register(s)
  local dcm = require("devcontainer")
  eq(dcm.get("/home/me/proj/a.c"), s)
  eq(dcm.get("/somewhere/else"), nil)
  session_mod.unregister(s)
end)

test("registry.pick: current, only one, or ask", function()
  local a, b = fake_session({}), session_mod.new({ container_id = "fedcba9876543210", local_folder = "/other", remote_folder = "/w/o", docker = "docker" })
  local got, asked = "unset", 0
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb) asked = asked + 1; cb(items[2]) end
  session_mod.pick(function(s) got = s end)
  eq(got, nil)
  session_mod.register(a)
  session_mod.pick(function(s) got = s end)
  eq({ got, asked }, { a, 0 })
  session_mod.register(b)
  session_mod.pick(function(s) got = s end)
  eq(asked, 1)
  session_mod.unregister(a)
  session_mod.unregister(b)
  vim.ui.select = orig
end)

test("cargo: custom profiles from Cargo.toml", function()
  writef(tmp .. "/prof/Cargo.toml", '[profile.ci]\ninherits = "release"\n[profile.ci.package.foo]\nopt-level = 1\n[profile.fast]\n')
  eq(cargo.profiles(tmp .. "/prof"), { "dev", "release", "ci", "fast" })
end)

-- profiles -------------------------------------------------------------------------------------

local config = require("devcontainer.config")
local profiles = require("devcontainer.profiles")

test("config.merge: dicts merge, lists replace, *_args append in profile layers", function()
  local base = { a = { x = 1, l = { 1, 2 } }, build_args = { "-j" }, s = "*" }
  eq(config.merge(base, { a = { y = 2, l = { 3 } }, build_args = { "-v" }, s = { "clangd" } }),
    { a = { x = 1, y = 2, l = { 3 } }, build_args = { "-v" }, s = { "clangd" } })
  eq(config.merge(base, { build_args = { "-v" }, a = { l = {} } }, true), { a = { x = 1, l = {} }, build_args = { "-j", "-v" }, s = "*" })
  eq(base.build_args, { "-j" }, "base untouched")
end)

vim.env.XDG_STATE_HOME = tmp .. "/state"
vim.fn.mkdir(tmp .. "/state/nvim", "p")
test("profiles: match, extends, customizations, selection", function()
  local ws = tmp .. "/prof-ws"
  local file = ws .. "/.devcontainer/devcontainer.json"
  writef(file, vim.json.encode({
    image = "x",
    customizations = { ["devcontainer.nvim"] = {
      profile = "team",
      settings = { docker = "/tmp/evil", project = { cmake = { generator = "Ninja" }, debug = { command = { "rm" }, adapter = "lldb" } } },
      profiles = { team = { desc = "shared", cli = "/tmp/evil", project = { cmake = { configure_args = { "-DTEAM=1" } } } } },
    } },
  }))
  config.set({ profiles = {
    base = { project = { cmake = { configure_args = { "-DBASE=1" } } } },
    asan = { desc = "ASan", extends = "base", project = { cmake = { configure_args = { "-DASAN=1" }, build_type = "RelWithDebInfo" } } },
    work = { match = ws, project = { env = { WORK = "1" } } },
  } })
  -- untrusted: customizations ignored
  local o = config.get(ws)
  eq(o.project.env, { WORK = "1" }, "folder profile applied")
  eq(o.project.cmake.generator, nil, "untrusted customizations ignored")
  eq(profiles.describe(ws).matched, { "work" })

  vim.cmd.edit(file)
  vim.secure.trust({ action = "allow", bufnr = 0 })
  vim.cmd.bwipeout()
  profiles.invalidate()
  o = config.get(ws)
  eq(o.project.cmake.generator, "Ninja", "trusted customization settings")
  eq(o.docker, config.options.docker, "docker path can't come from the repository")
  eq(o.project.debug.command, config.options.project.debug.command, "debug command can't come from the repository")
  eq(o.project.debug.adapter, "lldb")
  eq(profiles.describe(ws).selected, "team", "devcontainer.json default profile")
  eq(o.project.cmake.configure_args, { "-DTEAM=1" })
  eq(o.cli, config.options.cli)

  profiles.set(ws, "asan")
  o = config.get(ws)
  eq(o.project.cmake.configure_args, { "-DBASE=1", "-DASAN=1" }, "extends chain, _args appended")
  eq(o.project.cmake.build_type, "RelWithDebInfo")
  eq(o.project.env, { WORK = "1" })
  eq(profiles.active_name(ws), "asan")
  eq(config.get(ws .. "/sub").project.cmake.build_type, "RelWithDebInfo", "subfolder uses the workspace selection")

  profiles.set(ws, "none")
  eq(profiles.describe(ws).selected, nil)
  eq(config.get(ws).project.cmake.configure_args, {})
  profiles.set(ws, nil)
  eq(profiles.describe(ws).selected, "team")

  eq(profiles.matches({ "~/nope", function(r) return r == "/x" end }, { "/x" }), true)
  eq(profiles.matches(tmp .. "/*", { tmp .. "/a" }), true)
  eq(profiles.matches(tmp .. "/*", { tmp .. "/a/b" }), false)
  eq(profiles.matches(tmp, { tmp .. "/a/b" }), true, "plain folder matches below it")
  config.set({})
end)

test("cmake: ${profile} macro and reconfigure when the configure settings change", function()
  local root = tmp .. "/recfg"
  writef(root .. "/CMakeLists.txt", "")
  local opts = vim.deepcopy(config.options.project.cmake)
  opts.build_dir = "build/${profile}-${buildType}"
  local ctx = setmetatable({ root = root, provider = cmake, state = {}, opts = opts, profile = "asan",
    options = config.options }, { __index = {
      exec_path = function(_, x) return x end, task = function(_, t) t.cwd = root; return t end,
    } })
  local r = cmake.resolve(ctx)
  eq(r.build_arg, "build/asan-Debug")
  writef(r.host_build .. "/CMakeCache.txt", "")
  local build = cmake.actions[2]
  eq(#build.run(ctx, { extra = {} }), 1, "configured, nothing stored: just build")
  cmake.after(ctx, "configure")
  eq(#build.run(ctx, { extra = {} }), 1, "same settings: just build")
  opts.configure_args = { "-DNEW=1" }
  local steps = build.run(ctx, { extra = {} })
  eq(steps[#steps - 1].cmd[#steps[#steps - 1].cmd], "-DNEW=1", "reconfigure before building")
end)

test("cargo: features and custom profile flags", function()
  local ctx = setmetatable({ root = "/r", provider = cargo, state = {}, opts = { profile = "ci", features = { "a", "b" },
    no_default_features = true, build_args = {}, test_args = {} } }, { __index = { task = function(_, t) return t end } })
  eq(cargo.actions[2].run(ctx, { extra = {} })[1].cmd, { "cargo", "build", "--profile", "ci", "--features", "a,b", "--no-default-features" })
  eq(cargo.actions[4].run(ctx, { extra = {} })[1].cmd, { "cargo", "test", "--profile", "ci", "--features", "a,b", "--no-default-features" })
end)

-- ports ----------------------------------------------------------------------------------------

local ports = require("devcontainer.ports")
test("ports.parse: forwardPorts + portsAttributes", function()
  local specs = ports.parse({
    forwardPorts = { 3000, "db:5432", "8080", "bogus" },
    portsAttributes = {
      ["3000"] = { label = "Web", onAutoForward = "openBrowser", protocol = "https" },
      ["5000-6000"] = { label = "Range", requireLocalPort = true },
    },
    otherPortsAttributes = { onAutoForward = "silent" },
  })
  eq(#specs, 3)
  eq(specs[1], { host = "localhost", port = 3000, label = "Web", on_auto_forward = "openBrowser", require_local_port = false, protocol = "https" })
  eq(specs[2], { host = "db", port = 5432, label = "Range", on_auto_forward = "notify", require_local_port = true })
  eq(specs[3].on_auto_forward, "silent")
  eq({ ports.parse_arg("db:5432") }, { "db", 5432 })
  eq({ ports.parse_arg(" 3000 ") }, { "localhost", 3000 })
  eq(ports.parse_arg("x"), nil)
end)

test("ports: relay and readiness argv", function()
  eq(ports.relay_argv("socat", "db", 5432), { "socat", "-", "TCP:db:5432" })
  eq(ports.relay_argv("nc", "localhost", 80, "/bin/nc"), { "/bin/nc", "localhost", "80" })
  local bash = ports.relay_argv("bash", "localhost", 80)
  eq({ bash[1], bash[2], bash[4], bash[5] }, { "bash", "-c", "localhost", "80" })
  local s = fake_session({ python3 = "/usr/bin/python3" })
  local argv, kind = ports.relay_for(s, "localhost", 1)
  eq({ argv[1], kind }, { "/usr/bin/python3", "python3" })
  eq(ports.relay_for(fake_session({}), "localhost", 1), nil)
  eq(ports.listening_argv(8080)[4], "8080")
  local res = vim.system({ "sh", "-c", ports.listening_argv(1)[3], "1" }):wait()
  eq(res.code ~= 0, true, "nothing listens on port 1")
end)

test("docker backend: appPort published, forwardPorts tunnelled instead", function()
  local docker = require("devcontainer.backend.docker")
  local args = docker.run_args({ docker = "docker", local_folder = "/p", remote_folder = "/w" },
    { forwardPorts = { 3000 }, appPort = { 8000, "9000:9001" } }, "img", { "l1", "l2" })
  local s = table.concat(args, " ")
  eq(s:find("3000", 1, true), nil)
  assert(s:find("-p 127.0.0.1:8000:8000", 1, true), s)
  assert(s:find("-p 9000:9001", 1, true), s)
end)

-- command API + integrations (against stub plugins) ------------------------------------------

local function scratch_named(name)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

test("wrap_cmd: exec argv with mapped paths, unchanged without a container", function()
  local dcm = require("devcontainer")
  local s = fake_session({})
  session_mod.register(s)
  local argv, got = dcm.wrap_cmd({ "/home/me/.local/share/nvim/mason/bin/ruff", "check", "/home/me/proj/a.py" },
    { path = "/home/me/proj/a.py", cwd = "/home/me/proj/sub" })
  eq(got, s)
  eq(argv, { "docker", "exec", "-i", "-u", "vscode", "-w", "/workspaces/proj/sub", "-e", "PATH=/usr/local/bin:/usr/bin",
    "0123456789abcdef", "ruff", "check", "/workspaces/proj/a.py" })
  eq(dcm.wrap_cmd({ "./run.sh" }, { path = "/home/me/proj" })[11], "./run.sh", "relative paths are kept")
  eq({ dcm.wrap_cmd({ "ls" }, { path = "/elsewhere" }) }, { { "ls" } })
  eq(dcm.shell_cmd({ path = "/elsewhere" }), nil)
  eq(dcm.shell_cmd({ path = "/home/me/proj" })[3], "-it")
  session_mod.unregister(s)
end)

test("conform: formatters run in the container, host config outside", function()
  local util = { merge_formatter_configs = function(a, b) return vim.tbl_deep_extend("force", a, b) end }
  local conform = { formatters = { black = { prepend_args = { "-q" } } }, formatters_by_ft = { cpp = { "clang_format" }, py = { { "black" } } } }
  package.loaded["conform"], package.loaded["conform.util"] = conform, util
  package.loaded["conform.formatters.clang_format"] = { command = "clang-format", args = { "--assume-filename", "$FILENAME" } }
  package.loaded["conform.formatters.black"] = { command = "black", args = { "--stdin-filename", "$FILENAME", "-" } }
  local s = fake_session({ ["clang-format"] = "/usr/bin/clang-format" })
  session_mod.register(s)
  require("devcontainer.integrations.conform").setup()
  eq(type(conform.formatters.clang_format), "function")
  eq(type(conform.formatters.black), "function")
  local buf = scratch_named("/home/me/proj/src/a.cpp")
  local cfg = conform.formatters.clang_format(buf)
  eq({ cfg.command, cfg.inherit }, { "docker", false })
  local args = cfg.args(cfg, { filename = "/home/me/proj/src/a.cpp", dirname = "/home/me/proj/src", buf = buf })
  eq(vim.list_slice(args, #args - 2), { "/usr/bin/clang-format", "--assume-filename", "/workspaces/proj/src/a.cpp" })
  eq(args[1], "exec")
  -- black isn't in the container: host definition (with the user's override merged)
  local b = conform.formatters.black(buf)
  eq({ b.command, b.inherit }, { "black", false })
  local out = scratch_named("/elsewhere/a.cpp")
  eq(conform.formatters.clang_format(out).command, "clang-format")
  require("devcontainer.integrations.conform").setup() -- idempotent
  eq(conform.formatters.clang_format(buf).command, "docker")
  session_mod.unregister(s)
  package.loaded["conform"], package.loaded["conform.util"] = nil, nil
end)

test("nvim-lint: linters run in the container, output mapped back", function()
  local lint = { linters_by_ft = { python = { "mypy" } }, linters = {
    mypy = { cmd = "mypy", args = { "--show-column-numbers", function() return "--x" end }, stdin = false,
      parser = function(output) return output end },
  } }
  package.loaded["lint"] = lint
  local s = fake_session({ mypy = "/usr/local/bin/mypy" })
  session_mod.register(s)
  require("devcontainer.integrations.lint").setup()
  local buf = scratch_named("/home/me/proj/a.py")
  vim.api.nvim_set_current_buf(buf)
  local l = lint.linters.mypy()
  eq({ l.cmd, l.append_fname, l.name }, { "docker", false, "mypy" })
  eq(vim.list_slice(l.args, #l.args - 3), { "/usr/local/bin/mypy", "--show-column-numbers", "--x", "/workspaces/proj/a.py" })
  eq(l.parser("/workspaces/proj/a.py:1:2: error: x"), "/home/me/proj/a.py:1:2: error: x")
  vim.api.nvim_set_current_buf(scratch_named("/elsewhere/b.py"))
  eq(lint.linters.mypy().cmd, "mypy")
  session_mod.unregister(s)
  package.loaded["lint"] = nil
end)

test("neotest: spec transform maps workspace, temp files and host-only scripts", function()
  local s = fake_session({})
  local run = require("devcontainer.integrations.neotest").transform({
    command = { "python3", "/plugins/neotest-python/neotest.py", "--results-file", "/tmp/nvim.me/x/5", "--",
      "/home/me/proj/tests/test_a.py::test_x" },
    cwd = "/home/me/proj",
    env = { OUT = "/tmp/nvim.me/x/6" },
  }, s, "/tmp/nvim.me/x", "/tmp/dcn/1", function(p) return p == "/plugins/neotest-python/neotest.py" end)
  local hash = vim.fn.sha256("/plugins/neotest-python"):sub(1, 12)
  eq(run.copy_in, { { host = "/plugins/neotest-python", remote = "/tmp/dcn/1/in/" .. hash } })
  eq(run.cwd, "/home/me/proj")
  local cmd = table.concat(run.command, " ")
  assert(cmd:find("exec -it -u vscode -w /workspaces/proj -e OUT=/tmp/dcn/1/tmp/6", 1, true), cmd)
  assert(cmd:find("python3 /tmp/dcn/1/in/" .. hash .. "/neotest.py --results-file /tmp/dcn/1/tmp/5 -- /workspaces/proj/tests/test_a.py::test_x", 1, true), cmd)
end)

test("terminal providers: builtin fallback, snacks, toggleterm, function", function()
  local terminal = require("devcontainer.terminal")
  config.set({ terminal = { provider = "snacks" } })
  eq(terminal.provider(), "builtin", "snacks not installed")
  local calls = {}
  _G.Snacks = { terminal = { open = function(argv, o) table.insert(calls, { "snacks", argv, o.cwd }); return { buf = vim.api.nvim_create_buf(false, true) } end } }
  terminal.open({ "a", "b c" }, { cwd = "/x" })
  eq(calls[1], { "snacks", { "a", "b c" }, "/x" })
  package.loaded["toggleterm.terminal"] = { Terminal = { new = function(_, o)
    table.insert(calls, { "toggleterm", o.cmd, o.dir })
    return { toggle = function() end }
  end } }
  config.set({ terminal = { provider = "toggleterm" } })
  terminal.open({ "a", "b c" }, { cwd = "/x" })
  eq(calls[2], { "toggleterm", "'a' 'b c'", "/x" })
  config.set({ terminal = { provider = function(argv) table.insert(calls, { "fn", argv }) end } })
  terminal.open({ "z" })
  eq(calls[3], { "fn", { "z" } })
  _G.Snacks, package.loaded["toggleterm.terminal"] = nil, nil
  config.set({})
end)

-- progress, templates, picker, git ------------------------------------------------------------

test("progress.parse_line: CLI json/text, BuildKit and classic steps", function()
  local progress = require("devcontainer.progress")
  eq({ progress.parse_line('{"type":"text","level":2,"text":"Start: Run: docker build"}') }, { "Start: Run: docker build" })
  eq({ progress.parse_line("[1234 ms] Resolving features") }, { "Resolving features" })
  eq({ progress.parse_line("#8 [build 3/4] RUN apt-get install -y cmake") }, { "[build 3/4] RUN apt-get install -y cmake", 75 })
  eq({ progress.parse_line("Step 1/2 : FROM ubuntu") }, { "Step 1/2 : FROM ubuntu", 50 })
  eq(progress.parse_line("#8 0.312 Reading package lists..."), nil)
  eq(progress.parse_line('{"outcome":"success","containerId":"x"}'), nil)
  eq(progress.parse_line("   "), nil)
end)

test("progress backends: fidget, snacks, echo, off", function()
  local progress = require("devcontainer.progress")
  local calls = {}
  package.loaded["fidget.progress.handle"] = { create = function(m)
    table.insert(calls, { "create", m.title })
    return { report = function(_, p) table.insert(calls, { "report", p.message, p.percentage }) end,
      finish = function() table.insert(calls, { "finish" }) end }
  end }
  config.set({})
  eq(progress.backend(), "fidget")
  local p = progress.start("dc")
  p:feed({ "#3 [2/4] RUN make", "noise" })
  p:finish(true, "attached")
  vim.wait(500, function() return #calls >= 4 end)
  eq(calls[1], { "create", "dc" })
  eq(calls[2], { "report", "attached", nil }, "throttled updates superseded by the final message")
  eq(calls[#calls], { "finish" })
  package.loaded["fidget.progress.handle"] = nil
  eq(progress.backend(), "echo")
  config.set({ progress = false })
  eq(progress.backend(), nil)
  progress.start("x"):report("nothing happens")
  config.set({})
end)

test("templates: refs and the minimal config", function()
  local templates = require("devcontainer.templates")
  eq(templates.template_ref("cpp"), "ghcr.io/devcontainers/templates/cpp")
  eq(templates.template_ref("ghcr.io/me/t/x:1"), "ghcr.io/me/t/x:1")
  local conf = jsonc.decode(templates.minimal_config("proj", "base:ubuntu"))
  eq(conf, { name = "proj", image = "mcr.microsoft.com/devcontainers/base:ubuntu" })
  eq(jsonc.decode(templates.minimal_config("p", "ghcr.io/x/y:1")).image, "ghcr.io/x/y:1")
end)

test("picker: backend selection and argv", function()
  local picker = require("devcontainer.picker")
  config.set({ picker = "telescope" })
  eq(picker.backend(), "telescope")
  config.set({})
  eq(picker.backend(), "select")
  local s = fake_session({})
  local argv = picker.list_argv(s, "/usr/include")
  eq({ argv[#argv - 4], argv[#argv] }, { "/bin/sh", "/usr/include" })
  eq(picker.buffer_name(s, "/usr/include/stdio.h"), "devcontainer://0123456789ab/usr/include/stdio.h")
end)

test("git: dotfiles url, CLI flags, SSH agent mount", function()
  local git = require("devcontainer.git")
  eq(git.dotfiles_url("me/dotfiles"), "https://github.com/me/dotfiles.git")
  eq(git.dotfiles_url("me/dotfiles.git"), "https://github.com/me/dotfiles.git")
  eq(git.dotfiles_url("git@host:me/d.git"), "git@host:me/d.git")
  eq(git.cli_dotfiles_args({ dotfiles = { repository = "me/d", target_path = "~/d", install_command = "i.sh" } }),
    { "--dotfiles-repository", "https://github.com/me/d.git", "--dotfiles-target-path", "~/d", "--dotfiles-install-command", "i.sh" })
  eq(git.cli_dotfiles_args({ dotfiles = {} }), {})
  eq(git.agent_mount({ git = { ssh_agent = false } }), nil)
  eq(git.agent_mount({ git = { ssh_agent = true } }, true), "type=bind,source=/run/host-services/ssh-auth.sock,target=" .. git.AGENT_SOCK)
  local linux = git.agent_mount({ git = { ssh_agent = true } }, false)
  eq(linux, ("type=bind,source=%s,target=%s"):format(git.host_agent_dir(), git.AGENT_DIR))
  local docker = require("devcontainer.backend.docker")
  local args = table.concat(docker.run_args({ docker = "docker", local_folder = "/p", remote_folder = "/w", options = config.options }, {}, "img", { "a", "b" }), " ")
  assert(args:find("SSH_AUTH_SOCK=" .. git.AGENT_SOCK, 1, true), args)
end)

test("git: dotfiles script clones, runs the install script / links dotfiles once", function()
  local git = require("devcontainer.git")
  local home, repo = tmp .. "/dot-home", tmp .. "/dot-repo"
  vim.fn.mkdir(home, "p")
  writef(repo .. "/.vimrc", "set nocp\n")
  writef(repo .. "/.git-keep", "")
  vim.system({ "sh", "-c", 'cd "$1" && git init -q && git add -A && git -c user.email=a@b -c user.name=t commit -qm x', "sh", repo }):wait()
  local function run(target, cmd)
    return vim.system({ "sh", "-c", git.DOTFILES_SCRIPT, "sh", repo, target, cmd or "" }, { env = { HOME = home } }):wait()
  end
  eq(run("~/dotfiles").code, 0)
  eq(vim.uv.fs_readlink(home .. "/.vimrc"), home .. "/dotfiles/.vimrc", "no install script: dotfiles linked")
  writef(repo .. "/install.sh", '#!/bin/sh\ntouch "$HOME/installed"\n')
  vim.system({ "sh", "-c", 'cd "$1" && git add -A && git -c user.email=a@b -c user.name=t commit -qm y', "sh", repo }):wait()
  eq(run("~/dot2").code, 0)
  eq(vim.uv.fs_stat(home .. "/installed") ~= nil, true, "install.sh ran")
  eq(run("~/dot3", "touch \"$HOME/custom\"").code, 0)
  eq(vim.uv.fs_stat(home .. "/custom") ~= nil, true, "install command ran")
  vim.fn.delete(home .. "/custom")
  eq(run("~/dot3", "touch \"$HOME/custom\"").code, 0)
  eq(vim.uv.fs_stat(home .. "/custom"), nil, "only installed once")
end)

test("git: SSH agent relay forwards to $SSH_AUTH_SOCK", function()
  local git = require("devcontainer.git")
  local upstream = tmp .. "/agent-upstream.sock"
  local server = vim.uv.new_pipe(false)
  assert(server:bind(upstream))
  server:listen(4, function()
    local c = vim.uv.new_pipe(false)
    server:accept(c)
    c:read_start(function(_, d) if d then c:write("agent:" .. d) else c:close() end end)
  end)
  local orig = vim.env.SSH_AUTH_SOCK
  vim.env.SSH_AUTH_SOCK = upstream
  eq(git.start_agent_relay(), true)
  local got
  local client = vim.uv.new_pipe(false)
  client:connect(git.host_agent_dir() .. "/agent.sock", function(err)
    assert(not err, err)
    client:read_start(function(_, d) if d then got = (got or "") .. d end end)
    client:write("hello")
  end)
  vim.wait(3000, function() return got == "agent:hello" end)
  eq(got, "agent:hello")
  client:close()
  git.stop_agent_relay()
  server:close()
  vim.env.SSH_AUTH_SOCK = orig
end)

test("lsp.start_clients: waits for the clients to exit; a newer move takes over the pending one", function()
  -- like Neovim's: is_stopped() right after stop(), while the server is still exiting (and attached)
  local alive = true
  local client = { id = 4242, is_stopped = function() return true end, stop = function() end }
  local orig_get = vim.lsp.get_client_by_id
  vim.lsp.get_client_by_id = function(id)
    if id == client.id then return alive and client or nil end
    return orig_get(id)
  end
  local buf = scratch_named("/moves/w/a.c")
  local calls = {}
  local orig = vim.lsp.start
  vim.lsp.start = function(cfg, o) table.insert(calls, { cfg.name, o.bufnr }) end
  local entry = { client = client, config = { name = "srv", cmd = { vim.fn.exepath("sh") } }, bufs = { buf } }
  local after = 0
  lsp.start_clients({ entry }, function() after = after + 1 end, "/moves/w") -- e.g. up
  lsp.start_clients({}, nil, "/moves/w") -- e.g. stop right after: takes the client over
  vim.wait(400)
  local early = #calls
  alive = false
  vim.wait(1000, function() return #calls > 0 end)
  vim.wait(300)
  vim.lsp.start, vim.lsp.get_client_by_id = orig, orig_get
  eq(early, 0, "not started while the old client is still running")
  eq(calls, { { "srv", buf } }, "started once")
  eq(after, 1, "the superseded move's callback runs once, after the merged move")
end)

test("lsp.start_clients: a client that won't exit is killed, then taken off its buffers", function()
  local buf = scratch_named("/moves/stuck/a.c")
  local terminated, detached, calls = 0, {}, {}
  local client = {
    id = 4343, is_stopped = function() return true end, stop = function() end,
    attached_buffers = { [buf] = true },
    rpc = { terminate = function() terminated = terminated + 1 end },
  }
  local orig_get, orig_detach, orig_start = vim.lsp.get_client_by_id, vim.lsp.buf_detach_client, vim.lsp.start
  vim.lsp.get_client_by_id = function(id) if id == client.id then return client end return orig_get(id) end
  vim.lsp.buf_detach_client = function(b, id)
    table.insert(detached, { b, id, #calls })
    client.attached_buffers[b] = nil
  end
  vim.lsp.start = function(cfg, o) table.insert(calls, { cfg.name, o.bufnr }) end
  lsp.move_timeouts = { kill_after = 200, give_up = 500 }
  lsp.start_clients({ { client = client, config = { name = "srv", cmd = { vim.fn.exepath("sh") } }, bufs = { buf } } },
    nil, "/moves/stuck")
  vim.wait(2000, function() return #calls > 0 end)
  lsp.move_timeouts = { kill_after = 3000, give_up = 5000 }
  vim.lsp.get_client_by_id, vim.lsp.buf_detach_client, vim.lsp.start = orig_get, orig_detach, orig_start
  eq(terminated, 1, "killed once")
  eq(detached, { { buf, 4343, 0 } }, "detached before the new client starts")
  eq(calls, { { "srv", buf } })
end)

test("lsp: --compile-commands-dir / compilationDatabasePath follow the active build dir", function()
  local root = tmp .. "/ccd"
  writef(root .. "/CMakeLists.txt", "")
  config.set({})
  local cfg = { name = "clangd", cmd = { "clangd", "--compile-commands-dir=build", "--background-index" }, root_dir = root }
  local argv, _, cdb = lsp.remap_compile_commands(cfg.cmd, cfg)
  eq(argv, { "clangd", "--compile-commands-dir=" .. root .. "/build/Debug", "--background-index" })
  eq(cdb, { dir = root .. "/build/Debug", ready = false })
  eq(cfg.cmd[2], "--compile-commands-dir=build", "config untouched")
  writef(root .. "/build/Debug/compile_commands.json", "[]")
  eq(select(3, lsp.remap_compile_commands(cfg.cmd, cfg)).ready, true)
  eq(lsp.remap_compile_commands({ "clangd", "--compile-commands-dir", "build" }, cfg)[3], root .. "/build/Debug")
  eq(lsp.remap_compile_commands({ "clangd", "--compile-commands-dir=" .. root .. "/build" }, cfg)[2],
    "--compile-commands-dir=" .. root .. "/build/Debug", "absolute dir inside the project")
  local _, io = lsp.remap_compile_commands({ "clangd" },
    vim.tbl_extend("force", cfg, { init_options = { compilationDatabasePath = "build", fallbackFlags = {} } }))
  eq(io, { compilationDatabasePath = root .. "/build/Debug", fallbackFlags = {} })
  local elsewhere = { "clangd", "--compile-commands-dir=/opt/elsewhere" }
  eq(lsp.remap_compile_commands(elsewhere, cfg), elsewhere, "a dir outside the project is kept")
  local plain = { "clangd" }
  eq(lsp.remap_compile_commands(plain, cfg), plain)

  config.set({ profiles = { p = { project = { cmake = { build_dir = "build/${profile}-${buildType}" } } } } })
  profiles.set(root, "p")
  eq(lsp.remap_compile_commands(cfg.cmd, cfg)[2], "--compile-commands-dir=" .. root .. "/build/p-Debug", "profile build dir")
  profiles.set(root, nil)
  config.set({ lsp = { follow_build_dir = false } })
  eq(lsp.remap_compile_commands(cfg.cmd, cfg), cfg.cmd, "follow_build_dir = false")
  config.set({})
end)

test("lsp.rewrite: the container argv names the build dir in container paths", function()
  local root = tmp .. "/ccd"
  local s = session_mod.new({ container_id = "abcdef0123456789", local_folder = root, remote_folder = "/workspaces/ccd", docker = "docker" })
  s.which = function(_, b) return b == "clangd" and "/usr/bin/clangd" or nil end
  session_mod.register(s)
  local new = lsp.rewrite({ name = "clangd", cmd = { "clangd", "--compile-commands-dir=build" }, root_dir = root })
  eq(new._devcontainer_argv, { "/usr/bin/clangd", "--compile-commands-dir=/workspaces/ccd/build/Debug" })
  eq(new._devcontainer_cdb, { dir = root .. "/build/Debug", ready = true })
  eq(new._devcontainer_host_cmd, { "clangd", "--compile-commands-dir=build" }, "restarts recompute from the original")
  config.set({ lsp = { remote_cmd = { clangd = { "clangd-18", "--compile-commands-dir=build" } } } })
  new = lsp.rewrite({ name = "clangd", cmd = { "clangd" }, root_dir = root })
  eq(new._devcontainer_argv, { "clangd-18", "--compile-commands-dir=/workspaces/ccd/build/Debug" }, "remote_cmd too")
  eq(new._devcontainer_cdb.dir, root .. "/build/Debug")
  config.set({ lsp = { remote_cmd = { clangd = { "clangd-18", "--compile-commands-dir=/workspaces/ccd/build" } } } })
  new = lsp.rewrite({ name = "clangd", cmd = { "clangd" }, root_dir = root })
  eq(new._devcontainer_argv, { "clangd-18", "--compile-commands-dir=/workspaces/ccd/build/Debug" }, "container path in remote_cmd")
  config.set({ lsp = { remote_cmd = { clangd = { "clangd-18", "--compile-commands-dir=/opt/db" } } } })
  new = lsp.rewrite({ name = "clangd", cmd = { "clangd" }, root_dir = root })
  eq(new._devcontainer_argv, { "clangd-18", "--compile-commands-dir=/opt/db" }, "outside the project: kept")
  config.set({})
  session_mod.unregister(s)
  local host = lsp.rewrite({ name = "clangd", cmd = { vim.fn.exepath("sh"), "--compile-commands-dir=build" }, root_dir = root })
  eq(host.cmd, { vim.fn.exepath("sh"), "--compile-commands-dir=" .. root .. "/build/Debug" }, "on the host too")
end)

test("lsp.refresh_compile_commands restarts only servers whose database moved or appeared", function()
  local root = tmp .. "/ccd"
  local function client(id, cdb)
    return { id = id, config = { root_dir = root, _devcontainer_cdb = cdb }, attached_buffers = {},
      is_stopped = function() return false end, stop = function() end }
  end
  local current = root .. "/build/Debug" -- has compile_commands.json (previous test)
  local clients = {
    client(1, { dir = current, ready = true }), -- up to date
    client(2, { dir = current, ready = false }), -- started before the first configure
    client(3, { dir = root .. "/build/Release", ready = true }), -- another profile / build type
    client(4, nil), -- doesn't follow the build dir
  }
  local orig_get, orig_start = vim.lsp.get_clients, lsp.start_clients
  local restarted
  vim.lsp.get_clients = function() return clients end
  lsp.start_clients = function(entries) restarted = vim.tbl_map(function(e) return e.client.id end, entries) end
  lsp.refresh_compile_commands(root)
  vim.lsp.get_clients, lsp.start_clients = orig_get, orig_start
  eq(restarted, { 2, 3 })
end)

test("git: the agent relay is shared between Neovims and taken over when its server is gone", function()
  local git = require("devcontainer.git")
  local uv = vim.uv
  local upstream = tmp .. "/agent-upstream2.sock"
  local agent = uv.new_pipe(false)
  assert(agent:bind(upstream))
  agent:listen(4, function()
    local c = uv.new_pipe(false)
    agent:accept(c)
    c:read_start(function(_, d) if d then c:write("agent:" .. d) else c:close() end end)
  end)
  local orig = vim.env.SSH_AUTH_SOCK
  vim.env.SSH_AUTH_SOCK = upstream
  local path = git.host_agent_dir() .. "/agent.sock"
  local function ask(msg)
    local got
    local c = uv.new_pipe(false)
    c:connect(path, function(err)
      if err then got = "error" return end
      c:read_start(function(_, d) if d then got = (got or "") .. d end end)
      c:write(msg)
    end)
    vim.wait(2000, function() return got ~= nil end)
    c:close()
    return got
  end

  eq(git.start_agent_relay(), true)
  local st = git.relay_status()
  eq({ st.state, st.pid, st.upstream }, { "self", uv.os_getpid(), upstream })
  git.stop_agent_relay()
  eq(uv.fs_stat(path), nil, "socket removed on stop, so another Neovim can take over")

  -- another Neovim serves the socket: shared, not taken over
  local other = uv.new_pipe(false)
  assert(other:bind(path))
  other:listen(4, function()
    local c = uv.new_pipe(false)
    other:accept(c)
    c:read_start(function(_, d) if d then c:write("other:" .. d) else c:close() end end)
  end)
  git.takeover_interval = 100
  eq(git.start_agent_relay(), true)
  eq(git.relay_status().state, "other")
  eq(ask("x"), "other:x")
  -- ... until it's gone
  other:close()
  uv.fs_unlink(path)
  vim.wait(3000, function() return git.relay_status().state == "self" end)
  eq(git.relay_status().state, "self", "taken over")
  eq(ask("y"), "agent:y")
  git.stop_agent_relay()

  -- a socket left behind by a Neovim that crashed is replaced
  vim.system({ "python3", "-c", "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])", path }):wait()
  eq(uv.fs_stat(path).type, "socket")
  eq(git.start_agent_relay(), true)
  eq(git.relay_status().state, "self")
  eq(ask("z"), "agent:z")
  git.stop_agent_relay()
  git.takeover_interval = 10000
  agent:close()
  vim.env.SSH_AUTH_SOCK = orig
end)

test("git: known_hosts lines missing in the container are appended", function()
  local git = require("devcontainer.git")
  local home = tmp .. "/kh-home"
  vim.fn.mkdir(home, "p")
  local function run(input)
    return vim.system({ "sh", "-c", git.KNOWN_HOSTS_SCRIPT }, { env = { HOME = home }, stdin = input }):wait()
  end
  eq(run("a.example ssh-ed25519 AAA\n# comment\n\n|1|salt|hash ssh-rsa BBB\n").code, 0)
  eq(vim.fn.readfile(home .. "/.ssh/known_hosts"), { "a.example ssh-ed25519 AAA", "|1|salt|hash ssh-rsa BBB" })
  eq(vim.uv.fs_stat(home .. "/.ssh").mode % 512, 448, "~/.ssh is 0700")
  eq(vim.uv.fs_stat(home .. "/.ssh/known_hosts").mode % 512, 384, "known_hosts is 0600")
  vim.fn.writefile({ "mine ssh-ed25519 CCC", "a.example ssh-ed25519 AAA" }, home .. "/.ssh/known_hosts")
  eq(run("a.example ssh-ed25519 AAA\nb.example ssh-ed25519 DDD").code, 0)
  eq(vim.fn.readfile(home .. "/.ssh/known_hosts"), { "mine ssh-ed25519 CCC", "a.example ssh-ed25519 AAA", "b.example ssh-ed25519 DDD" })
end)

test("tools.offer: asks once for C/C++ workspaces without clangd, remembers never", function()
  local tools = require("devcontainer.tools")
  local store = require("devcontainer.store")
  local root = tmp .. "/tools-ws"
  vim.fn.mkdir(root, "p")
  config.set({})
  local has = {}
  local function session(key)
    return { key = key, name = key, local_folder = root, which = function(_, b) return has[b] end }
  end
  local asked, installed = {}, {}
  local orig_select, orig_install = vim.ui.select, tools.install
  local answer = "skip"
  vim.ui.select = function(items, o, cb)
    table.insert(asked, o.kind)
    for _, it in ipairs(items) do
      if it.action == answer then return cb(it) end
    end
  end
  tools.install = function(s, name) table.insert(installed, s.key .. ":" .. name) end

  tools.offer(session("s1"), { force = true })
  eq(#asked, 0, "not a C/C++ workspace")
  writef(root .. "/CMakeLists.txt", "")
  has.clangd = "/usr/bin/clangd"
  tools.offer(session("s1"), { force = true })
  eq(#asked, 0, "clangd is there")
  has.clangd = nil
  tools.offer(session("s1"), { force = true })
  eq(asked, { "devcontainer.install_tools" })
  tools.offer(session("s1"), { force = true })
  eq(#asked, 1, "once per container")
  tools.offer(session("s2"))
  eq(#asked, 1, "no UI: not asked")

  answer = "install"
  tools.offer(session("s3"), { force = true })
  eq(installed, { "s3:clangd" })
  answer = "never"
  tools.offer(session("s4"), { force = true })
  eq(store.get(root).install_tools, { clangd = "never" })
  tools.offer(session("s5"), { force = true })
  eq(#asked, 3, "never asked again for this project")
  store.clear(root, "install_tools")

  config.set({ lsp = { install_tools = false } })
  tools.offer(session("s6"), { force = true })
  eq(#asked, 3, "install_tools = false")
  config.set({ lsp = { install_tools = true } })
  tools.offer(session("s7"))
  eq(installed, { "s3:clangd", "s7:clangd" }, "install_tools = true: without asking")
  config.set({})
  vim.ui.select, tools.install = orig_select, orig_install
end)

test("tools: the LLVM install script (llvm.sh, distribution fallback, dnf)", function()
  local tools = require("devcontainer.tools")
  local dir = tmp .. "/llvm-inst"
  local sys, stubs, root, bin, log = dir .. "/sys", dir .. "/stubs", dir .. "/root", dir .. "/bin", dir .. "/calls"
  vim.fn.mkdir(sys, "p")
  for _, t in ipairs({ "sh", "sed", "head", "mktemp", "rm", "mkdir", "ln", "touch", "chmod", "cat" }) do
    vim.uv.fs_symlink(vim.fn.exepath(t), sys .. "/" .. t)
  end
  local function stub(name, body)
    writef(stubs .. "/" .. name, "#!/bin/sh\necho \"" .. name .. " $*\" >> \"$LOG\"\n" .. (body or "") .. "\n")
    vim.uv.fs_chmod(stubs .. "/" .. name, 493)
  end
  local function run(env, version)
    vim.fn.delete(log)
    vim.fn.delete(root, "rf")
    vim.fn.delete(bin, "rf")
    local res = vim.system({ sys .. "/sh", "-c", tools.LLVM_SCRIPT, "sh", version or "" }, {
      env = vim.tbl_extend("force", { PATH = stubs .. ":" .. sys, LOG = log, DEVCONTAINER_ROOT = root, DEVCONTAINER_BIN_DIR = bin }, env or {}),
      clear_env = true,
    }):wait()
    return res.code, vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}
  end
  -- apt: llvm.sh with its CURRENT_LLVM_STABLE, then clang-tidy / clang-format, linked by plain name
  stub("apt-get", [[
for a; do case "$a" in clang-tidy-*|clang-format-*) v=${a##*-}; t=${a%-*}
  mkdir -p "$DEVCONTAINER_ROOT/usr/lib/llvm-$v/bin" && touch "$DEVCONTAINER_ROOT/usr/lib/llvm-$v/bin/$t" && chmod +x "$DEVCONTAINER_ROOT/usr/lib/llvm-$v/bin/$t";; esac; done]])
  stub("wget", [[[ -n "$FAIL_WGET" ] && exit 1; printf 'CURRENT_LLVM_STABLE=21\nCURRENT_LLVM_TRUNK=22\n' > "$2"]])
  stub("bash", [[[ -n "$FAIL_LLVM" ] && exit 1; mkdir -p "$DEVCONTAINER_ROOT/usr/lib/llvm-$2/bin"
touch "$DEVCONTAINER_ROOT/usr/lib/llvm-$2/bin/clangd"; chmod +x "$DEVCONTAINER_ROOT/usr/lib/llvm-$2/bin/clangd"]])
  local code, calls = run()
  eq(code, 0)
  eq(calls[1], "apt-get update")
  assert(calls[2]:find("lsb-release", 1, true) and calls[2]:find("software-properties-common", 1, true), calls[2])
  assert(calls[3]:match("^wget %-qO .*/llvm%.sh https://apt%.llvm%.org/llvm%.sh$"), calls[3])
  assert(calls[4]:match("^bash .*/llvm%.sh 21$"), calls[4])
  eq(calls[5], "apt-get install -y --no-install-recommends clang-tidy-21 clang-format-21")
  for _, t in ipairs({ "clangd", "clang-tidy", "clang-format" }) do
    eq(vim.uv.fs_readlink(bin .. "/" .. t), root .. "/usr/lib/llvm-21/bin/" .. t)
  end
  code, calls = run(nil, "19")
  assert(calls[4]:match("^bash .*/llvm%.sh 19$"), "lsp.llvm_version: " .. calls[4])
  -- llvm.sh fails (unsupported release): the distribution's packages
  code, calls = run({ FAIL_LLVM = "1" })
  eq(code, 0)
  eq(calls[#calls], "apt-get install -y --no-install-recommends clangd clang-tidy clang-format")
  code, calls = run({ FAIL_WGET = "1" })
  eq(calls[#calls], "apt-get install -y --no-install-recommends clangd clang-tidy clang-format", "no network to apt.llvm.org")
  -- no apt: dnf
  vim.fn.delete(stubs, "rf")
  stub("dnf")
  code, calls = run()
  eq({ code, calls }, { 0, { "dnf install -y clang-tools-extra" } })
  vim.fn.delete(stubs, "rf")
  vim.fn.mkdir(stubs, "p")
  code = run()
  eq(code, 1, "no package manager")
end)

test("runner.ssh_hint: git over SSH failures point at checkhealth", function()
  local runner = require("devcontainer.runner")
  eq(runner.ssh_hint({ "Cloning into 'dep'...", "git@git.example: Permission denied (publickey)." }), true)
  eq(runner.ssh_hint({ "Host key verification failed.", "fatal: Could not read from remote repository." }), true)
  eq(runner.ssh_hint({ "main.cpp:3:1: error: expected ';'" }), false)
end)

io.stdout:write(("\n%d/%d passed\n"):format(count - failures, count))
os.exit(failures == 0 and 0 or 1)
