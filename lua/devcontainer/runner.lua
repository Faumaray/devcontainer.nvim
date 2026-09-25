--- Runs project tasks (configure/build/test/run) in the devcontainer, or on the host when the
--- project has none. Uses overseer.nvim when available, otherwise a built-in output split.
---
--- A task spec:
---   { name, cmd = argv, cwd = <host dir>, exec_cwd? = <cwd in the container/host exec space>,
---     env?, efm?, interactive?, session?, after? = { provider, root, action } }
--- A step may also be a function(cb) that calls cb(ok, more_specs) — used for work that depends
--- on a previous step (e.g. finding the executable after configuring).
local config = require("devcontainer.config")
local log = require("devcontainer.log")
local registry = require("devcontainer.session")

local M = {}

-- errorformats -----------------------------------------------------------------------------

local efm_cache = {}

--- 'errorformat' of one of Neovim's `:compiler` plugins (gcc, cargo, ...).
function M.efm(compiler)
  if efm_cache[compiler] == nil then
    local buf = vim.api.nvim_create_buf(false, true)
    local ok = pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("silent compiler " .. compiler)
    end)
    local efm = ok and vim.bo[buf].errorformat or ""
    efm_cache[compiler] = efm ~= "" and efm or vim.go.errorformat
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  return efm_cache[compiler]
end

-- paths --------------------------------------------------------------------------------------

--- Replace container workspace paths in a line of output with host paths.
function M.map_line(session, line)
  if not session then return line end
  return require("devcontainer.paths").replace_root(line, session.remote_folder, session.local_folder)
end

--- Host name for a file reported by a task that ran in `session`, or nil to keep it.
local function host_name(session, name)
  if not session or name:sub(1, 1) ~= "/" then return nil end
  for _, root in ipairs(session.local_roots) do
    if name == root or vim.startswith(name, root .. "/") then return nil end
  end
  local mapped = session:local_path(name)
  if mapped then return mapped end
  if config.options.remote_fs then return "devcontainer://" .. session.key .. name end
end

--- Point quickfix items at files the host can open (in place). Returns true if any changed.
function M.fix_items(items, session)
  if not session then return false end
  local changed, stale = false, {}
  for _, item in ipairs(items) do
    local bufnr = item.bufnr or 0
    local name = bufnr > 0 and vim.api.nvim_buf_get_name(bufnr) or item.filename
    local mapped = name and host_name(session, name)
    if mapped then
      item.filename, item.bufnr, changed = mapped, nil, true
      if bufnr > 0 then stale[bufnr] = true end
    end
  end
  -- buffers the errorformat created for container paths that don't exist here
  vim.schedule(function()
    for bufnr in pairs(stale) do
      if vim.api.nvim_buf_is_valid(bufnr) and not vim.api.nvim_buf_is_loaded(bufnr)
        and #vim.fn.win_findbuf(bufnr) == 0 and not vim.uv.fs_stat(vim.api.nvim_buf_get_name(bufnr)) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end)
  return changed
end

--- Parse output lines with an errorformat, resolving relative file names against `cwd`.
function M.parse(lines, efm, cwd)
  local items = {}
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", row = 0, col = 0, width = 1, height = 1,
    hide = true, focusable = false, noautocmd = true, style = "minimal",
  })
  pcall(vim.api.nvim_win_call, win, function()
    if cwd and vim.uv.fs_stat(cwd) then
      vim.cmd.lcd({ args = { cwd }, mods = { noautocmd = true, silent = true } })
    end
    items = vim.fn.getqflist({ lines = lines, efm = efm or vim.go.errorformat }).items
  end)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return items
end

--- A task in the container failed on git over SSH: point at the check that tells why.
---@param lines string[] its output
function M.ssh_hint(lines)
  for _, l in ipairs(lines) do
    if l:find("Permission denied (publickey", 1, true) or l:find("Host key verification failed", 1, true) then
      log.warn("git over SSH failed in the container — :checkhealth devcontainer shows the agent and known_hosts it sees")
      return true
    end
  end
  return false
end

-- specs --------------------------------------------------------------------------------------

local function session_of(spec)
  if spec.session == false then return nil end
  return spec.session or registry.find(spec.cwd)
end

--- argv that runs the spec where it belongs.
function M.argv(spec, tty)
  local s = session_of(spec)
  if not s then return spec.cmd end
  return s:exec_argv(spec.cmd, {
    tty = tty,
    stdin = tty,
    cwd = spec.exec_cwd or s:remote_path(spec.cwd) or s.remote_folder,
    env = spec.env,
  })
end

local function display(spec)
  local s = session_of(spec)
  return ("%s$ %s"):format(s and ("[" .. s.name .. "] ") or "", table.concat(spec.cmd, " "))
end

local function after(spec, ok)
  if ok and spec.after then
    local done, err = pcall(require("devcontainer.project").after, spec.after)
    if not done then log.warn(tostring(err)) end
  end
end

-- builtin backend ----------------------------------------------------------------------------

local outputs = {} -- name -> { buf, job }

local function show(buf, focus)
  local win = vim.fn.win_findbuf(buf)[1]
  if win then return win end
  local cur = vim.api.nvim_get_current_win()
  vim.cmd(("botright %dsplit"):format(config.options.project.output_height))
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].winfixheight = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  if not focus then vim.api.nvim_set_current_win(cur) end
  return win
end

local function output_buf(name)
  local o = outputs[name]
  if o and vim.api.nvim_buf_is_valid(o.buf) then return o end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "[devcontainer] " .. name)
  vim.bo[buf].filetype = "devcontainer_output"
  outputs[name] = { buf = buf }
  return outputs[name]
end

local function append(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local follow = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    follow[win] = vim.api.nvim_win_get_cursor(win)[1] >= vim.api.nvim_buf_line_count(buf) - 1
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.bo[buf].modifiable = false
  local last = vim.api.nvim_buf_line_count(buf)
  for win, yes in pairs(follow) do
    if yes then vim.api.nvim_win_set_cursor(win, { last, 0 }) end
  end
end

local function set_qf(spec, items)
  local cur = vim.fn.getqflist({ title = 0, context = 0 })
  local action = (type(cur.context) == "table" and cur.context.devcontainer_task == spec.name) and "r" or " "
  vim.fn.setqflist({}, action, { title = spec.name, items = items, context = { devcontainer_task = spec.name } })
end

local function builtin_interactive(spec, done)
  local s = session_of(spec)
  require("devcontainer.terminal").open(M.argv(spec, true), {
    cwd = s and spec.cwd or (spec.exec_cwd or spec.cwd),
    env = not s and spec.env or nil,
    title = spec.name,
    height = config.options.project.output_height,
    on_exit = function(code)
      after(spec, code == 0)
      done(code == 0)
    end,
  })
end

local function builtin(spec, done)
  if spec.interactive then return builtin_interactive(spec, done) end
  local s = session_of(spec)
  local o = output_buf(spec.name)
  if o.job then pcall(vim.fn.jobstop, o.job) end
  vim.bo[o.buf].modifiable = true
  vim.api.nvim_buf_set_lines(o.buf, 0, -1, false, { display(spec), "" })
  vim.bo[o.buf].modifiable = false
  if config.options.project.open_output == "always" then show(o.buf) end

  local lines, partial, started = {}, {}, vim.uv.hrtime()
  local function feed(stream)
    return function(_, data)
      if not data then return end
      data[1] = (partial[stream] or "") .. data[1]
      partial[stream] = table.remove(data)
      local mapped = {}
      for _, l in ipairs(data) do
        l = M.map_line(s, (l:gsub("\r$", ""):gsub("\27%[[%d;?]*[A-Za-z]", "")))
        lines[#lines + 1] = l
        mapped[#mapped + 1] = l
      end
      if #mapped > 0 then append(o.buf, mapped) end
    end
  end

  local job
  job = vim.fn.jobstart(M.argv(spec, false), {
    cwd = s and spec.cwd or (spec.exec_cwd or spec.cwd),
    env = not s and spec.env or nil,
    stdin = "null",
    on_stdout = feed("stdout"),
    on_stderr = feed("stderr"),
    on_exit = function(_, code)
      if o.job ~= job then return done(false) end -- replaced by a newer run
      o.job = nil
      local rest = {}
      for _, stream in ipairs({ "stdout", "stderr" }) do
        if partial[stream] and partial[stream] ~= "" then rest[#rest + 1] = M.map_line(s, partial[stream]) end
      end
      vim.list_extend(lines, rest)
      local secs = (vim.uv.hrtime() - started) / 1e9
      append(o.buf, vim.list_extend(rest, { "", ("[%s in %.1fs, exit code %d]"):format(code == 0 and "done" or "failed", secs, code) }))

      local items = M.parse(lines, spec.efm, spec.cwd)
      M.fix_items(items, s)
      set_qf(spec, items)
      local errors = #vim.tbl_filter(function(i) return i.valid == 1 end, items)
      if code == 0 then
        log.info(("%s: done (%.1fs)"):format(spec.name, secs))
      else
        log.error(("%s: failed with exit code %d%s"):format(spec.name, code,
          errors > 0 and (" — %d quickfix entries"):format(errors) or ""))
        if s then M.ssh_hint(lines) end
        if config.options.project.open_output == "on_failure" then show(o.buf) end
        if errors > 0 and config.options.project.open_quickfix then
          local cur = vim.api.nvim_get_current_win()
          vim.cmd("botright copen")
          vim.api.nvim_set_current_win(cur)
        end
      end
      after(spec, code == 0)
      done(code == 0)
    end,
  })
  if job <= 0 then
    log.error(("%s: cannot start %s"):format(spec.name, M.argv(spec)[1]))
    return done(false)
  end
  o.job = job
end

-- overseer backend ---------------------------------------------------------------------------

--- overseer TaskDefinition for a spec.
function M.task_definition(spec)
  local s = session_of(spec)
  local components = {}
  if spec.interactive then
    table.insert(components, { "open_output", on_start = "always", focus = true })
  else
    table.insert(components, {
      "on_output_quickfix",
      errorformat = spec.efm,
      open_on_exit = config.options.project.open_quickfix and "failure" or "never",
    })
  end
  table.insert(components, { "devcontainer", cwd = s and spec.exec_cwd or nil, session = s and s.key or false })
  table.insert(components, { "unique", replace = true })
  table.insert(components, "default")
  return {
    name = spec.name,
    cmd = spec.cmd,
    cwd = s and spec.cwd or (spec.exec_cwd or spec.cwd),
    env = spec.env,
    components = components,
    metadata = { devcontainer_after = spec.after },
  }
end

local function overseer_run(spec, done)
  local overseer = require("overseer")
  local task = overseer.new_task(M.task_definition(spec))
  task:subscribe("on_complete", function(_, status)
    done(status == "SUCCESS")
    return true
  end)
  task:start()
end

-- sequencing ---------------------------------------------------------------------------------

function M.backend()
  local r = config.options.project.runner
  if r == "overseer" or (r == "auto" and pcall(require, "overseer")) then return "overseer" end
  return "builtin"
end

--- Run steps one after another, stopping at the first failure.
---@param steps (table|fun(cb: fun(ok: boolean, more?: table[])))[]
---@param on_done? fun(ok: boolean)
function M.run(steps, on_done)
  steps = vim.list_extend({}, steps)
  local backend = M.backend() == "overseer" and overseer_run or builtin
  local i, last_name = 0, nil
  local function finish(ok)
    if on_done then on_done(ok) end
    vim.api.nvim_exec_autocmds("User", {
      pattern = "DevcontainerTaskDone",
      modeline = false,
      data = { ok = ok, name = last_name },
    })
  end
  local function step(ok, more)
    if ok == false then return finish(false) end
    for j = #(more or {}), 1, -1 do table.insert(steps, i + 1, more[j]) end
    i = i + 1
    local s = steps[i]
    if not s then return finish(true) end
    if type(s) == "table" then last_name = s.name end
    vim.schedule(function()
      if type(s) == "function" then
        local ok2, err = pcall(s, step)
        if not ok2 then
          log.error(tostring(err))
          step(false)
        end
      else
        local ok2, err = pcall(backend, s, step)
        if not ok2 then
          log.error(("%s: %s"):format(s.name, err))
          step(false)
        end
      end
    end)
  end
  step(true)
end

return M
