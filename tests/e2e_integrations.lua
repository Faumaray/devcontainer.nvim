-- End-to-end test of the plugin integrations (conform.nvim, nvim-lint, neotest) with the fake
-- docker CLI: tools that exist only on the container PATH, output with container paths.
--
--   PLUGINS=/path/with/plugins nvim --headless --clean -l tests/e2e_integrations.lua
-- $PLUGINS holds conform.nvim, nvim-lint, neotest, nvim-nio and plenary.nvim (missing ones are skipped).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
vim.cmd.runtime("plugin/devcontainer.lua")

local plugins = vim.env.PLUGINS or ""
local function have(name)
  local dir = plugins .. "/" .. name
  if plugins ~= "" and vim.uv.fs_stat(dir) then
    vim.opt.rtp:append(dir)
    return true
  end
  return false
end

local E = "/tmp/dc-int"
local HOST, REMOTE = E .. "/host/proj", E .. "/workspaces/proj"
vim.fn.delete(E, "rf")
vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME = E .. "/data", E .. "/state"
for _, d in ipairs({ HOST .. "/.devcontainer", REMOTE, E .. "/bin", E .. "/cbin" }) do vim.fn.mkdir(d, "p") end

local function write(path, text, mode)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
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
-- tools only "the container" has: on the remote PATH, not on Neovim's
write(E .. "/cbin/upfmt", "#!/bin/sh\ntr a-z A-Z\n", 493)
write(E .. "/cbin/fakelint", '#!/bin/sh\necho "$1:2:3: bad thing (in=$IN_CONTAINER)"\nexit 1\n', 493)
write(HOST .. "/.devcontainer/devcontainer.json", vim.json.encode({
  name = "int", image = "fake:latest", workspaceFolder = REMOTE,
  remoteEnv = { PATH = E .. "/cbin:${containerEnv:PATH}", IN_CONTAINER = "yes" },
}))
write(HOST .. "/a.txt", "hello\nworld\n")

require("devcontainer").setup({ backend = "docker", docker = E .. "/bin/docker", autostart = false })
vim.cmd.edit(HOST .. "/a.txt")
local main_buf = vim.api.nvim_get_current_buf()
vim.cmd("Devcontainer up")
local session
check("attached", wait(20000, function()
  session = require("devcontainer").get(HOST)
  return session ~= nil
end))
if not session then os.exit(1) end
check("tools are container-only", vim.fn.executable("upfmt") == 0 and session:which("upfmt") ~= nil)

-- conform.nvim ----------------------------------------------------------------------------------
if have("conform.nvim") then
  local conform = require("conform")
  conform.setup({ formatters_by_ft = { text = { "upfmt" } }, formatters = { upfmt = { command = "upfmt" } } })
  require("devcontainer.integrations.conform").setup()
  vim.bo[main_buf].filetype = "text"
  local done, err
  conform.format({ bufnr = main_buf, async = true }, function(e) done, err = true, e end)
  check("conform: formatted by the container-only tool", wait(10000, function() return done end) and not err
    and vim.deep_equal(vim.api.nvim_buf_get_lines(main_buf, 0, -1, false), { "HELLO", "WORLD" }),
    { err = err, lines = vim.api.nvim_buf_get_lines(main_buf, 0, -1, false) })
  check("conform: through docker exec", (read(E .. "/docker.log") or ""):find(E .. "/cbin/upfmt", 1, true) ~= nil)
else
  io.stdout:write("skip conform.nvim (not in $PLUGINS)\n")
end

-- nvim-lint -------------------------------------------------------------------------------------
if have("nvim-lint") then
  local lint = require("lint")
  lint.linters.fakelint = {
    cmd = "fakelint",
    stdin = false,
    ignore_exitcode = true,
    parser = require("lint.parser").from_errorformat("%f:%l:%c: %m"),
  }
  lint.linters_by_ft = { text = { "fakelint" } }
  require("devcontainer.integrations.lint").setup()
  vim.api.nvim_set_current_buf(main_buf)
  lint.try_lint()
  local diags
  check("nvim-lint: diagnostics from the container land on the host buffer", wait(10000, function()
    diags = vim.diagnostic.get(main_buf)
    return #diags > 0
  end) and diags[1].lnum == 1 and diags[1].col == 2 and diags[1].message:find("in=yes", 1, true) ~= nil, diags)
else
  io.stdout:write("skip nvim-lint (not in $PLUGINS)\n")
end

-- neotest ---------------------------------------------------------------------------------------
if have("neotest") and have("nvim-nio") and have("plenary.nvim") then
  local nio = require("nio")
  local Tree = require("neotest.types").Tree
  local test_file = HOST .. "/test_a.txt"
  write(test_file, "t1\n")
  local seen
  local adapter = {
    name = "fake-tests",
    root = function() return HOST end,
    filter_dir = function() return true end,
    is_test_file = function(f) return f:match("test_[^/]*%.txt$") ~= nil end,
    discover_positions = function(path)
      return Tree.from_list({
        { type = "file", path = path, name = vim.fs.basename(path), id = path, range = { 0, 0, 1, 0 } },
        { { type = "test", path = path, name = "t1", id = path .. "::t1", range = { 0, 0, 0, 2 } } },
      }, function(pos) return pos.id end)
    end,
    build_spec = function(args)
      local results = nio.fn.tempname()
      local id = args.tree:data().id
      return {
        -- writes the id it was given (a container path) and a container-only variable
        command = { "sh", "-c", 'printf "%s\\n%s\\n" "$1" "$IN_CONTAINER" > "$2"; echo "ran $1"', "sh", id, results },
        cwd = HOST,
        context = { results = results, id = id },
      }
    end,
    results = function(spec, result)
      local f = io.open(spec.context.results)
      local lines = f and vim.split(f:read("*a"), "\n") or {}
      if f then f:close() end
      local output = io.open(result.output) and io.open(result.output):read("*a") or ""
      seen = { id = lines[1], in_container = lines[2], code = result.code, output = output }
      return { [lines[1] or "?"] = { status = result.code == 0 and "passed" or "failed" } }
    end,
  }
  require("neotest").setup({ adapters = { adapter }, default_strategy = "devcontainer", log_level = vim.log.levels.ERROR })
  vim.cmd.edit(test_file)
  require("neotest").run.run(test_file .. "::t1")
  check("neotest: test ran in the container", wait(20000, function() return seen ~= nil end)
    and seen.code == 0 and seen.in_container == "yes", seen)
  check("neotest: results file copied back with host paths", seen and seen.id == test_file .. "::t1", seen)
  check("neotest: output mapped to host paths", seen and seen.output:find("ran " .. test_file .. "::t1", 1, true) ~= nil, seen)
  check("neotest: command went through docker exec -it", (read(E .. "/docker.log") or ""):find('"exec", "-it"', 1, true) ~= nil)
else
  io.stdout:write("skip neotest (needs neotest, nvim-nio and plenary.nvim in $PLUGINS)\n")
end

-- snacks.nvim: picker, terminal, notifier progress ------------------------------------------------
local dcm = require("devcontainer")
local o = require("devcontainer.config").options
local function buf_text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
if have("snacks.nvim") then
  require("snacks").setup({ picker = { enabled = true }, terminal = { enabled = true }, notifier = { enabled = true } })
  o.picker = "snacks"
  vim.cmd("Devcontainer files " .. E .. "/cbin")
  local picker
  check("snacks: picker lists container-only files", wait(10000, function()
    picker = Snacks.picker.get({ source = "devcontainer_files" })[1]
    return picker ~= nil and #picker:items() == 2
  end), picker and picker:items())
  if picker then
    picker:action("confirm")
    check("snacks: confirm opens a devcontainer:// buffer", wait(5000, function()
      return vim.api.nvim_buf_get_name(0):find("^devcontainer://" .. session.key .. vim.pesc(E) .. "/cbin/") ~= nil
    end), vim.api.nvim_buf_get_name(0))
  end
  o.terminal.provider = "snacks"
  vim.cmd.buffer(main_buf)
  vim.cmd("Devcontainer exec echo hi-from-snacks-$IN_CONTAINER")
  local tbuf = vim.api.nvim_get_current_buf()
  check("snacks: exec opens a snacks terminal in the container", wait(5000, function()
    return vim.b[tbuf].snacks_terminal ~= nil and buf_text(tbuf):find("hi-from-snacks-yes", 1, true) ~= nil
  end), buf_text(tbuf))
  vim.cmd("stopinsert")
  pcall(vim.api.nvim_buf_delete, tbuf, { force = true })
  o.progress = "snacks"
  local p = require("devcontainer.progress").start("devcontainer test")
  p:report("building", 10)
  check("snacks: progress shown by the notifier", wait(2000, function()
    for _, n in ipairs(Snacks.notifier.get_history({ filter = function(n) return n.id == "devcontainer_progress_devcontainer test" end }) or {}) do
      if tostring(n.msg):find("building", 1, true) then return true end
    end
    return false
  end))
  p:finish(true)
  o.progress, o.picker, o.terminal.provider = "auto", "auto", "builtin"
else
  io.stdout:write("skip snacks.nvim (not in $PLUGINS)\n")
end

-- telescope ---------------------------------------------------------------------------------------
if have("plenary.nvim") and have("telescope.nvim") then
  o.picker = "telescope"
  vim.cmd.buffer(main_buf)
  vim.cmd("Devcontainer files " .. E .. "/cbin")
  local prompt
  check("telescope: picker lists container-only files", wait(10000, function()
    prompt = vim.bo.filetype == "TelescopePrompt" and vim.api.nvim_get_current_buf() or nil
    if not prompt then return false end
    local picker = require("telescope.actions.state").get_current_picker(prompt)
    return picker and picker.manager and picker.manager:num_results() == 2 and picker:get_selection() ~= nil
  end))
  if prompt then
    vim.cmd("stopinsert")
    require("telescope.actions").select_default(prompt)
    check("telescope: selection opens a devcontainer:// buffer", wait(5000, function()
      return vim.api.nvim_buf_get_name(0):find("^devcontainer://" .. session.key) ~= nil
    end), vim.api.nvim_buf_get_name(0))
  end
  o.picker = "auto"
else
  io.stdout:write("skip telescope.nvim (not in $PLUGINS)\n")
end

-- toggleterm --------------------------------------------------------------------------------------
if have("toggleterm.nvim") then
  require("toggleterm").setup({})
  o.terminal.provider = "toggleterm"
  vim.cmd.buffer(main_buf)
  vim.cmd("Devcontainer exec echo hi-from-toggleterm-$IN_CONTAINER")
  local tbuf = vim.api.nvim_get_current_buf()
  check("toggleterm: exec runs in the container", wait(5000, function()
    return vim.bo[tbuf].filetype == "toggleterm" and buf_text(tbuf):find("hi-from-toggleterm-yes", 1, true) ~= nil
  end), buf_text(tbuf))
  o.terminal.provider = "builtin"
else
  io.stdout:write("skip toggleterm.nvim (not in $PLUGINS)\n")
end

-- fidget ------------------------------------------------------------------------------------------
if have("fidget.nvim") then
  require("fidget").setup({})
  check("fidget: picked by progress = auto", require("devcontainer.progress").backend() == "fidget")
  -- fidget keeps no history without a UI: look at the handle itself
  local handle_mod = require("fidget.progress.handle")
  local orig_create, handle = handle_mod.create, nil
  handle_mod.create = function(m)
    handle = orig_create(m)
    return handle
  end
  local p = require("devcontainer.progress").start("devcontainer test")
  p:feed({ "#5 [2/4] RUN make" })
  check("fidget: progress reported", wait(2000, function()
    return handle ~= nil and handle.message == "[2/4] RUN make" and handle.percentage == 50
  end), handle and { handle.message, handle.percentage })
  p:finish(true, "attached")
  check("fidget: progress finished", wait(2000, function() return handle ~= nil and handle.done == true end))
  handle_mod.create = orig_create
else
  io.stdout:write("skip fidget.nvim (not in $PLUGINS)\n")
end

check("checkhealth runs with the integrations loaded", pcall(vim.cmd, "checkhealth devcontainer"))
local health = ""
wait(10000, function() -- filled asynchronously on newer Neovim
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == "checkhealth" then health = buf_text(b) end
  end
  return health:find("attached containers", 1, true) ~= nil
end)
check("checkhealth reports the relay and the integrations", health:find("port forwarding relay", 1, true) ~= nil
  and health:find("conform.nvim found", 1, true) ~= nil and not health:find("ERROR", 1, true), health)

io.stdout:write(failures == 0 and "\nall integration e2e checks passed\n" or ("\n%d integration e2e checks failed\n"):format(failures))
os.exit(failures == 0 and 0 or 1)
