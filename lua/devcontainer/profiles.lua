--- Profiles: named sets of option overrides.
---
---   profiles = {
---     asan = { desc = "ASan build", project = { cmake = { configure_args = { "-DSANITIZE=address" } } } },
---     work = { match = { "~/work/**" }, extends = "asan", devcontainer = "gpu" },
---   }
---
--- A profile applies when its `match` fits the project / workspace folder, or when it's selected
--- for the workspace (:Devcontainer profile, remembered per workspace). devcontainer.json can ship
--- settings and profiles for the whole team under customizations["devcontainer.nvim"].
---
--- Precedence (lowest first): setup() options, matching profiles (by name), the devcontainer.json
--- `settings`, the selected profile. Lists under keys ending in "_args" are appended, every other
--- value replaces what's below it.
local config = require("devcontainer.config")
local jsonc = require("devcontainer.jsonc")
local spec = require("devcontainer.spec")
local store = require("devcontainer.store")

local M = {}

local cache = {} -- path -> resolved options
local described = {} -- path -> { scope, selected, matched }
local last_selected = {} -- scope -> name (for statuslines)
local extra = {} -- profiles from add()
local custom_cache = {} -- config file -> { stamp, value }

local META = { desc = true, match = true, extends = true }

function M.invalidate()
  cache, described = {}, {}
end

-- devcontainer.json is repository data: it may only carry settings that don't pick which programs
-- run on the host (no docker/cli paths, debug adapter commands, dotfiles, ...).
local ALLOWED = {
  project = true,
  lsp = { servers = true, exclude = true, fallback = true, remote_cmd = true },
  ports = { forward = true },
  devcontainer = true,
}

local function sanitize(t, allowed)
  if type(t) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(t) do
    local rule = allowed[k]
    if rule == true then
      out[k] = vim.deepcopy(v)
    elseif type(rule) == "table" and type(v) == "table" then
      out[k] = sanitize(v, rule)
    end
  end
  if type(out.project) == "table" and type(out.project.debug) == "table" then out.project.debug.command = nil end
  return out
end

local function sanitize_profile(def)
  local out = sanitize(def, ALLOWED) or {}
  if type(def.desc) == "string" then out.desc = def.desc end
  if type(def.extends) == "string" or type(def.extends) == "table" then out.extends = def.extends end
  if type(def.match) == "string" or type(def.match) == "table" then out.match = def.match end
  return out
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function config_file_of(ws)
  local s = require("devcontainer.session").by_folder(ws)
  if s then return s.config_file end
  return spec.list_configs(ws)[1]
end

--- customizations["devcontainer.nvim"] of the workspace's devcontainer.json:
--- { settings?, profiles, profile? }, or nil. Asks to trust the file the first time.
function M.customizations(ws)
  if not ws or not config.options.customizations then return nil end
  local file = config_file_of(ws)
  local stat = file and vim.uv.fs_stat(file)
  if not stat then return nil end
  local stamp = ("%d.%d.%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
  local hit = custom_cache[file]
  if hit and hit.stamp == stamp then return hit.value end

  local value, untrusted
  local raw = read(file)
  if raw and raw:find('"devcontainer.nvim"', 1, true) then
    local ok, decoded = pcall(jsonc.decode, raw)
    local c = ok and type(decoded) == "table" and type(decoded.customizations) == "table" and decoded.customizations
    if c and type(c["devcontainer.nvim"]) == "table" then
      -- trusted = the user allowed this exact content (:help vim.secure.read)
      local trusted = vim.secure.read(file)
      local ok2, t = pcall(jsonc.decode, trusted or "")
      local block = ok2 and type(t) == "table" and type(t.customizations) == "table" and t.customizations["devcontainer.nvim"]
      untrusted = trusted == nil
      if type(block) == "table" then
        value = { settings = sanitize(block.settings, ALLOWED), profiles = {} }
        if type(block.profile) == "string" then value.profile = block.profile end
        for name, def in pairs(type(block.profiles) == "table" and block.profiles or {}) do
          if type(name) == "string" and type(def) == "table" then value.profiles[name] = sanitize_profile(def) end
        end
      end
    end
  end
  -- not trusted ("ignore"): ask again next time the options are resolved
  if not untrusted then custom_cache[file] = { stamp = stamp, value = value } end
  return value
end

--- All profile definitions visible in a workspace (setup() wins over add() over devcontainer.json).
---@return table<string, table> defs, table? customizations
function M.definitions(ws)
  local defs = {}
  local custom = M.customizations(ws)
  for name, d in pairs(custom and custom.profiles or {}) do defs[name] = d end
  for name, d in pairs(extra) do defs[name] = d end
  for name, d in pairs(config.options.profiles or {}) do defs[name] = d end
  return defs, custom
end

--- Add profiles at runtime, e.g. from a project's .nvim.lua (:help 'exrc').
function M.add(defs)
  for name, d in pairs(defs or {}) do extra[name] = d end
  M.invalidate()
end

local function glob_match(pat, path)
  pat = vim.fs.normalize(pat)
  if not pat:find("[*?[{]") then return path == pat or vim.startswith(path, pat .. "/") end
  local ok, lp = pcall(vim.glob.to_lpeg, pat)
  return ok and lp:match(path) ~= nil
end

--- Does `match` (glob | fun(root) | list of those) fit one of `roots`?
function M.matches(match, roots)
  if match == nil then return false end
  local list = type(match) == "table" and match or { match }
  for _, pat in ipairs(list) do
    for _, r in ipairs(roots) do
      if type(pat) == "function" then
        local ok, yes = pcall(pat, r)
        if ok and yes then return true end
      elseif type(pat) == "string" and glob_match(pat, r) then
        return true
      end
    end
  end
  return false
end

--- Layers of a profile: its `extends` chain first, then itself.
local function expand(defs, name, out, seen)
  if seen[name] or type(defs[name]) ~= "table" then return end
  seen[name] = true
  local def = defs[name]
  local parents = type(def.extends) == "string" and { def.extends } or (def.extends or {})
  for _, p in ipairs(parents) do expand(defs, p, out, seen) end
  local layer = {}
  for k, v in pairs(def) do
    if not META[k] then layer[k] = v end
  end
  table.insert(out, layer)
end

--- The folder a profile selection belongs to: the devcontainer workspace containing `path`,
--- else `path` itself (a project root).
---@return string scope, string? workspace
function M.scope(path)
  local ws = spec.find_root_cached(path)
  return ws or path, ws
end

--- Scope of the current buffer (devcontainer workspace, else project root, else cwd).
function M.current_scope()
  local name = vim.api.nvim_buf_get_name(0)
  local s = require("devcontainer.session").find(name)
  if s then return s.local_folder, s.local_folder end
  local path = (name ~= "" and vim.bo.buftype == "" and not name:match("^%a[%w+.-]*://")) and name or vim.fn.getcwd()
  local ws = spec.find_root(path)
  if ws then return ws, ws end
  local ctx = require("devcontainer.project").detect()
  return ctx and ctx.root or vim.fn.getcwd(), nil
end

--- Selected profile name of a scope ("none" = explicitly none), falling back to the
--- devcontainer.json default.
function M.selected(scope, custom)
  local name = store.peek(scope, "profile")
  if name == nil and custom then name = custom.profile end
  if name == "none" then return nil end
  return name
end

--- Profile shown in statuslines for a scope (never reads files).
function M.active_name(scope)
  local name = store.peek(scope, "profile")
  if name == "none" then return nil end
  return name or last_selected[scope]
end

--- Options for `path` with profiles applied (cached until the next profile / config change).
---@return devcontainer.Options
function M.resolve(path)
  local hit = cache[path]
  if hit then return hit end
  local scope, ws = M.scope(path)
  local defs, custom = M.definitions(ws)
  local roots = { path }
  if ws and ws ~= path then roots[2] = ws end

  local names = vim.tbl_keys(defs)
  table.sort(names)
  local layers, seen, matched = {}, {}, {}
  for _, name in ipairs(names) do
    if type(defs[name]) == "table" and M.matches(defs[name].match, roots) then
      table.insert(matched, name)
      expand(defs, name, layers, seen)
    end
  end
  if custom and custom.settings then table.insert(layers, custom.settings) end
  local selected = M.selected(scope, custom)
  if selected then
    if defs[selected] then
      expand(defs, selected, layers, {})
    else
      selected = nil
    end
  end

  local opts = config.options
  for _, layer in ipairs(layers) do opts = config.merge(opts, layer, true) end
  cache[path] = opts
  described[path] = { scope = scope, selected = selected, matched = matched }
  last_selected[scope] = selected
  return opts
end

--- { scope, selected?, matched = { names } } for `path`.
function M.describe(path)
  M.resolve(path)
  return described[path]
end

--- Select `name` for a scope (nil = back to the default, "none" = no profile).
function M.set(scope, name)
  store.set(scope, "profile", name)
  last_selected[scope] = nil
  M.invalidate()
end

--- Sorted profile names visible in a workspace.
function M.names(ws)
  local names = vim.tbl_keys((M.definitions(ws)))
  table.sort(names)
  return names
end

return M
