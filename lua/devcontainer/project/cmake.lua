--- CMake projects: CMakePresets.json (configure/build/test presets) or plain build types,
--- executable targets from the CMake File API, compile_commands.json for clangd.
local async = require("devcontainer.async")
local jsonc = require("devcontainer.jsonc")
local runner = require("devcontainer.runner")

local M = { name = "cmake" }

-- detection ----------------------------------------------------------------------------------

--- Topmost directory with a CMakeLists.txt between `path` and `boundary`.
function M.detect(path, boundary)
  local stop = boundary and vim.fs.dirname(boundary) or vim.env.HOME
  local found = vim.fs.find("CMakeLists.txt", { upward = true, path = path, stop = stop, type = "file", limit = math.huge })
  if #found == 0 then return nil end
  return vim.fs.dirname(found[#found])
end

-- presets ------------------------------------------------------------------------------------

local function read_json(path)
  local ok, v = pcall(jsonc.read_file, path)
  return ok and v or nil
end

--- Load CMakePresets.json + CMakeUserPresets.json (with `include`), inheritance resolved.
---@return { configure: table<string,table>, build: table<string,table>, test: table<string,table>, order: string[] }?
function M.presets(root)
  local raw = { configurePresets = {}, buildPresets = {}, testPresets = {} }
  local order, seen, any = {}, {}, false
  local function load(path)
    if seen[path] then return end
    seen[path] = true
    local data = read_json(path)
    if type(data) ~= "table" then return end
    any = true
    local dir = vim.fs.dirname(path)
    for _, inc in ipairs(data.include or {}) do
      load(inc:sub(1, 1) == "/" and inc or vim.fs.normalize(dir .. "/" .. inc))
    end
    for kind in pairs(raw) do
      for _, p in ipairs(data[kind] or {}) do
        if type(p) == "table" and p.name then
          p.__file_dir = dir
          raw[kind][p.name] = p
          if kind == "configurePresets" then table.insert(order, p.name) end
        end
      end
    end
  end
  load(root .. "/CMakePresets.json")
  load(root .. "/CMakeUserPresets.json")
  if not any then return nil end

  local function resolve(kind, name, depth)
    local p = raw[kind][name]
    if not p or (depth or 0) > 20 then return nil end
    local parents = type(p.inherits) == "string" and { p.inherits } or (p.inherits or {})
    local out = { cacheVariables = {}, environment = {} }
    -- later parents first so that earlier ones win, then the preset itself
    for i = #parents, 1, -1 do
      local parent = resolve(kind, parents[i], (depth or 0) + 1)
      for k, v in pairs(parent or {}) do
        if k == "cacheVariables" or k == "environment" then
          out[k] = vim.tbl_extend("force", out[k], v)
        elseif k ~= "hidden" and k ~= "name" then
          out[k] = v
        end
      end
    end
    for k, v in pairs(p) do
      if k == "cacheVariables" or k == "environment" then
        out[k] = vim.tbl_extend("force", out[k], v)
      elseif k ~= "inherits" then
        out[k] = v
      end
    end
    out.hidden = p.hidden
    return out
  end

  local res = { configure = {}, build = {}, test = {}, order = {} }
  for kind, key in pairs({ configurePresets = "configure", buildPresets = "build", testPresets = "test" }) do
    for name in pairs(raw[kind]) do
      local p = resolve(kind, name)
      if p and not p.hidden then res[key][name] = p end
    end
  end
  for _, name in ipairs(order) do
    if res.configure[name] then table.insert(res.order, name) end
  end
  return res
end

--- Expand the macros CMake allows in binaryDir.
function M.expand(s, vars)
  s = s:gsub("%$(p?)env{([^}]*)}", function(_, name) return vim.env[name] or "" end)
  s = s:gsub("%${([%w]+)}", function(name)
    local v = vars[name]
    if v == nil then
      if name == "hostSystemName" then return jit and jit.os or "Linux" end
      if name == "dollar" then return "$" end
      if name == "pathListSep" then return ":" end
      return nil
    end
    return v
  end)
  return s
end

local function cache_var(p, name)
  local v = p and p.cacheVariables and p.cacheVariables[name]
  if type(v) == "table" then v = v.value end
  return type(v) == "string" and v or nil
end

-- configuration state ------------------------------------------------------------------------

--- Resolved configuration of the project: preset or build type, build dir (host + exec space).
function M.resolve(ctx)
  local o = ctx.opts
  local presets = M.presets(ctx.root)
  local r = { presets = presets }
  if presets and #presets.order > 0 then
    local name = ctx.state.preset
    if not presets.configure[name] then name = presets.order[1] end
    local p = presets.configure[name]
    r.preset = name
    r.build_type = cache_var(p, "CMAKE_BUILD_TYPE")
    if p.binaryDir then
      local dir = M.expand(p.binaryDir, {
        sourceDir = ctx.root,
        sourceParentDir = vim.fs.dirname(ctx.root),
        sourceDirName = vim.fs.basename(ctx.root),
        presetName = name,
        generator = p.generator or "",
        fileDir = p.__file_dir or ctx.root,
      })
      r.host_build = vim.fs.normalize(dir:sub(1, 1) == "/" and dir or (ctx.root .. "/" .. dir))
    end
    for bname, bp in vim.spairs(presets.build) do
      if bp.configurePreset == name and (not r.build_preset or bname == ctx.state.build_preset) then r.build_preset = bname end
    end
    for tname, tp in vim.spairs(presets.test) do
      if tp.configurePreset == name and (not r.test_preset or tname == ctx.state.test_preset) then r.test_preset = tname end
    end
    if not r.host_build then
      r.build_arg = M.expand(o.build_dir, { buildType = r.build_type or name, presetName = name })
      r.host_build = vim.fs.normalize(ctx.root .. "/" .. r.build_arg)
    end
  else
    r.build_type = ctx.state.build_type or o.build_type
    r.build_arg = M.expand(o.build_dir, { buildType = r.build_type, presetName = r.build_type })
    r.host_build = vim.fs.normalize(r.build_arg:sub(1, 1) == "/" and r.build_arg or (ctx.root .. "/" .. r.build_arg))
  end
  -- how to refer to the build dir on the command line (cwd = project root)
  if not r.build_arg then
    local rel = vim.startswith(r.host_build, ctx.root .. "/") and r.host_build:sub(#ctx.root + 2)
    r.build_arg = rel or ctx:exec_path(r.host_build)
  end
  return r
end

local function configured(r)
  return r.host_build and vim.uv.fs_stat(r.host_build .. "/CMakeCache.txt") ~= nil
end

-- File API -----------------------------------------------------------------------------------

local function add_file_api_query(r)
  local dir = r.host_build .. "/.cmake/api/v1/query"
  vim.fn.mkdir(dir, "p")
  local f = io.open(dir .. "/codemodel-v2", "a")
  if f then f:close() end
end

local codemodel_cache = {}

--- Targets from the File API reply: { name, type, path? (exec space) }.
function M.codemodel_targets(r)
  local reply = r.host_build and (r.host_build .. "/.cmake/api/v1/reply")
  if not reply or not vim.uv.fs_stat(reply) then return {} end
  local indexes = {}
  for name in vim.fs.dir(reply) do
    if name:match("^index%-.*%.json$") then indexes[#indexes + 1] = name end
  end
  table.sort(indexes)
  local index_file = indexes[#indexes]
  if not index_file then return {} end
  local key = reply .. "/" .. index_file
  if codemodel_cache[key] then return codemodel_cache[key] end

  local index = read_json(key) or {}
  local ref = index.reply and index.reply["codemodel-v2"]
  local cm = ref and ref.jsonFile and read_json(reply .. "/" .. ref.jsonFile)
  if not cm then return {} end
  local conf = cm.configurations and cm.configurations[1]
  for _, c in ipairs(cm.configurations or {}) do
    if r.build_type and c.name == r.build_type then conf = c end
  end
  local out = {}
  for _, t in ipairs(conf and conf.targets or {}) do
    local tj = t.jsonFile and read_json(reply .. "/" .. t.jsonFile)
    if tj then
      local path = tj.artifacts and tj.artifacts[1] and tj.artifacts[1].path
      if path and path:sub(1, 1) ~= "/" then path = cm.paths.build .. "/" .. path end
      table.insert(out, { name = tj.name or t.name, type = tj.type, path = path })
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  codemodel_cache[key] = out
  return out
end

function M.executables(ctx)
  local r = M.resolve(ctx)
  local out = {}
  for _, t in ipairs(M.codemodel_targets(r)) do
    if t.type == "EXECUTABLE" and t.path then
      local cwd = ({
        exe = vim.fs.dirname(t.path),
        build = ctx:exec_path(r.host_build),
        root = ctx:exec_path(ctx.root),
      })[ctx.opts.run_cwd] or vim.fs.dirname(t.path)
      table.insert(out, { name = t.name, path = t.path, cwd = cwd })
    end
  end
  return out
end

function M.targets(ctx)
  local names = { "all", "clean" }
  for _, t in ipairs(M.codemodel_targets(M.resolve(ctx))) do
    if t.type ~= "INTERFACE_LIBRARY" then table.insert(names, t.name) end
  end
  return names
end

-- commands -----------------------------------------------------------------------------------

function M.efm()
  return table.concat({
    "CMake %trror at %f:%l (%m):",
    "CMake %tarning at %f:%l (%m):",
    "CMake %tarning (dev) at %f:%l (%m):",
    runner.efm("gcc"),
  }, ",")
end

local function spec(ctx, r, t)
  t.efm = t.efm or M.efm()
  t.after = t.after and { provider = M.name, root = ctx.root, action = t.after } or nil
  return ctx:task(t)
end

local function label(r)
  return r.preset or r.build_type or "default"
end

local function configure_step(ctx, r, extra, fresh)
  local cmd
  if r.preset then
    cmd = { "cmake", "--preset", r.preset }
    if not (r.presets.configure[r.preset] or {}).binaryDir then vim.list_extend(cmd, { "-B", r.build_arg }) end
  else
    cmd = { "cmake", "-S", ".", "-B", r.build_arg, "-DCMAKE_BUILD_TYPE=" .. r.build_type }
    if ctx.opts.generator and not configured(r) then vim.list_extend(cmd, { "-G", ctx.opts.generator }) end
  end
  table.insert(cmd, "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON")
  if fresh then table.insert(cmd, "--fresh") end
  vim.list_extend(cmd, ctx.opts.configure_args or {})
  vim.list_extend(cmd, extra or {})
  local steps = {}
  if r.host_build then
    table.insert(steps, function(cb)
      add_file_api_query(r)
      cb(true)
    end)
  end
  table.insert(steps, spec(ctx, r, { name = "cmake configure (" .. label(r) .. ")", cmd = cmd, after = "configure" }))
  return steps
end

local function build_cmd(ctx, r, target, extra)
  local cmd = r.build_preset and { "cmake", "--build", "--preset", r.build_preset }
    or { "cmake", "--build", r.build_arg }
  if not r.build_preset and r.build_type then vim.list_extend(cmd, { "--config", r.build_type }) end
  if target then vim.list_extend(cmd, { "--target", target }) end
  table.insert(cmd, "--parallel")
  vim.list_extend(cmd, ctx.opts.build_args or {})
  vim.list_extend(cmd, extra or {})
  return cmd
end

--- configure (when needed) + build steps
local function build_steps(ctx, r, target, extra, template)
  local steps = {}
  if not template and not configured(r) then steps = configure_step(ctx, r) end
  table.insert(steps, spec(ctx, r, {
    name = ("cmake build%s (%s)"):format(target and (" " .. target) or "", label(r)),
    cmd = build_cmd(ctx, r, target, extra),
  }))
  return steps
end

function M.build_target(ctx, target)
  return build_steps(ctx, M.resolve(ctx), target)
end

M.actions = {
  {
    name = "configure",
    desc = "cmake --preset / -B <build dir>",
    run = function(ctx, args) return configure_step(ctx, M.resolve(ctx), args.extra) end,
  },
  {
    name = "build",
    desc = "cmake --build (configures first when needed)",
    run = function(ctx, args) return build_steps(ctx, M.resolve(ctx), args.target, args.extra, args.template) end,
  },
  {
    name = "run",
    desc = "build and run an executable target",
    interactive = true,
    run = function(ctx, args)
      local r = M.resolve(ctx)
      local steps = configured(r) and {} or configure_step(ctx, r)
      table.insert(steps, function(cb)
        async.run(function()
          local exe = require("devcontainer.project").pick_executable(ctx, args.target)
          if not exe then return cb(false) end
          local more = build_steps(ctx, r, exe.name)
          table.insert(more, ctx:task({
            name = "run " .. exe.name,
            cmd = vim.list_extend({ exe.path }, args.extra),
            exec_cwd = exe.cwd,
            interactive = true,
          }))
          cb(true, more)
        end, function(err)
          if err then
            require("devcontainer.log").error(tostring(err))
            cb(false)
          end
        end)
      end)
      return steps
    end,
  },
  {
    name = "test",
    desc = "ctest",
    run = function(ctx, args)
      local r = M.resolve(ctx)
      local cmd = r.test_preset and { "ctest", "--preset", r.test_preset }
        or { "ctest", "--test-dir", r.build_arg, "-C", r.build_type or "Debug" }
      vim.list_extend(cmd, ctx.opts.ctest_args or {})
      vim.list_extend(cmd, args.extra)
      local steps = args.template and {} or build_steps(ctx, r)
      table.insert(steps, spec(ctx, r, { name = "ctest (" .. label(r) .. ")", cmd = cmd }))
      return steps
    end,
  },
  {
    name = "clean",
    desc = "cmake --build --target clean",
    run = function(ctx, args)
      local r = M.resolve(ctx)
      return { spec(ctx, r, { name = "cmake clean (" .. label(r) .. ")", cmd = build_cmd(ctx, r, "clean", args.extra) }) }
    end,
  },
  {
    name = "fresh",
    desc = "reconfigure from scratch (cmake --fresh)",
    run = function(ctx, args) return configure_step(ctx, M.resolve(ctx), args.extra, true) end,
  },
}

--- After configure: link compile_commands.json into the project root for clangd.
function M.after(ctx, action)
  if action ~= "configure" or not ctx.opts.link_compile_commands then return end
  local r = M.resolve(ctx)
  local db = r.host_build and (r.host_build .. "/compile_commands.json")
  if not db or not vim.uv.fs_stat(db) or not vim.startswith(r.host_build, ctx.root .. "/") then return end
  local link = ctx.root .. "/compile_commands.json"
  local st = vim.uv.fs_lstat(link)
  if st and st.type ~= "link" then return end -- the user's own file
  local target = r.host_build:sub(#ctx.root + 2) .. "/compile_commands.json"
  if st then
    if vim.uv.fs_readlink(link) == target then return end
    vim.uv.fs_unlink(link)
  end
  vim.uv.fs_symlink(target, link)
end

function M.settings(ctx)
  local r = M.resolve(ctx)
  local items = {}
  if r.preset then
    table.insert(items, { label = "Configure preset: " .. r.preset, key = "preset" })
  else
    table.insert(items, { label = "Build type: " .. r.build_type, key = "build_type" })
  end
  table.insert(items, { label = "Run/debug target: " .. (ctx.state.target or "(ask)"), key = "target" })
  local choice = async.select(items, { prompt = "CMake settings", format_item = function(i) return i.label end })
  if not choice then return end
  if choice.key == "preset" then
    local p = async.select(r.presets.order, {
      prompt = "Configure preset",
      format_item = function(n)
        local d = r.presets.configure[n].displayName
        return d and ("%s — %s"):format(n, d) or n
      end,
    })
    if p then ctx:set("preset", p) end
  elseif choice.key == "build_type" then
    local bt = async.select(ctx.opts.build_types, { prompt = "Build type" })
    if bt then ctx:set("build_type", bt) end
  else
    ctx:set("target", nil)
    require("devcontainer.project").pick_executable(ctx)
  end
end

function M.describe(ctx)
  local r = M.resolve(ctx)
  return (r.preset and ("preset " .. r.preset) or ("build type " .. r.build_type))
    .. (configured(r) and "" or ", not configured")
end

return M
