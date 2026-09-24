--- Rust / Cargo projects (workspaces included).
local async = require("devcontainer.async")
local runner = require("devcontainer.runner")

local M = { name = "cargo" }

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

--- Workspace root (topmost Cargo.toml with [workspace]) or the nearest Cargo.toml.
function M.detect(path, boundary)
  local stop = boundary and vim.fs.dirname(boundary) or vim.env.HOME
  local found = vim.fs.find("Cargo.toml", { upward = true, path = path, stop = stop, type = "file", limit = math.huge })
  if #found == 0 then return nil end
  for i = #found, 1, -1 do
    local toml = read(found[i]) or ""
    if toml:find("^%s*%[workspace%]") or toml:find("\n%s*%[workspace%]") then
      return vim.fs.dirname(found[i])
    end
  end
  return vim.fs.dirname(found[1])
end

local function profile(ctx)
  return ctx.state.profile or ctx.opts.profile or "dev"
end

local function profile_args(ctx)
  local p = profile(ctx)
  if p == "dev" then return {} end
  if p == "release" then return { "--release" } end
  return { "--profile", p }
end

local function profile_dir(ctx)
  local p = profile(ctx)
  if p == "dev" or p == "test" then return "debug" end
  if p == "bench" then return "release" end
  return p
end

local metadata_cache = {}

--- `cargo metadata --no-deps` (run where cargo runs; paths are in that space). Yields.
function M.metadata(ctx)
  local stat = vim.uv.fs_stat(ctx.root .. "/Cargo.toml")
  local key = ctx.root .. (ctx.session and ctx.session.key or "") .. (stat and stat.mtime.sec or "")
  if metadata_cache[key] then return metadata_cache[key].data end
  local res = ctx:system({ "cargo", "metadata", "--no-deps", "--format-version", "1" })
  if res.code ~= 0 then
    error("cargo metadata failed: " .. vim.trim(res.stderr or ""):sub(-300), 0)
  end
  local data = vim.json.decode(res.stdout, { luanil = { object = true, array = true } })
  metadata_cache[key] = { root = ctx.root, data = data }
  return data
end

local function bins(meta)
  local out = {}
  local members = {}
  for _, id in ipairs(meta.workspace_members or {}) do members[id] = true end
  for _, pkg in ipairs(meta.packages or {}) do
    if members[pkg.id] or not meta.workspace_members then
      for _, t in ipairs(pkg.targets or {}) do
        if vim.tbl_contains(t.kind or {}, "bin") then
          table.insert(out, { name = t.name, package = pkg.name })
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function M.executables(ctx)
  local meta = M.metadata(ctx)
  local dir = ("%s/%s"):format(meta.target_directory, profile_dir(ctx))
  return vim.tbl_map(function(b)
    return { name = b.name, package = b.package, path = dir .. "/" .. b.name, cwd = meta.workspace_root }
  end, bins(meta))
end

function M.targets(ctx)
  local names = {}
  for _, entry in pairs(metadata_cache) do
    if entry.root == ctx.root then
      for _, b in ipairs(bins(entry.data)) do
        if not vim.tbl_contains(names, b.name) then table.insert(names, b.name) end
      end
    end
  end
  return names
end

function M.efm()
  return runner.efm("cargo")
end

local function spec(ctx, t)
  t.efm = t.efm or M.efm()
  return ctx:task(t)
end

local function cargo(ctx, sub, extra, name)
  local cmd = { "cargo", sub }
  vim.list_extend(cmd, extra or {})
  return spec(ctx, { name = name or ("cargo " .. sub), cmd = cmd })
end

--- `--bin x` for a binary target, `-p x` for a package.
local function target_args(ctx, target)
  if not target then return {} end
  for _, b in ipairs(bins(M.metadata(ctx))) do
    if b.name == target then return { "--bin", target } end
  end
  return { "-p", target }
end

function M.build_target(ctx, target)
  local args = vim.list_extend(profile_args(ctx), { "--bin", target })
  return { cargo(ctx, "build", args, ("cargo build %s (%s)"):format(target, profile(ctx))) }
end

M.actions = {
  {
    name = "configure",
    desc = "cargo fetch",
    run = function(ctx, args) return { cargo(ctx, "fetch", args.extra) } end,
  },
  {
    name = "build",
    desc = "cargo build",
    run = function(ctx, args)
      local a = vim.list_extend(profile_args(ctx), target_args(ctx, args.target))
      vim.list_extend(a, ctx.opts.build_args or {})
      vim.list_extend(a, args.extra)
      return { cargo(ctx, "build", a, ("cargo build%s (%s)"):format(args.target and (" " .. args.target) or "", profile(ctx))) }
    end,
  },
  {
    name = "run",
    desc = "cargo run (asks which binary in workspaces)",
    interactive = true,
    run = function(ctx, args)
      local exe = require("devcontainer.project").pick_executable(ctx, args.target)
      if not exe then return end
      local a = vim.list_extend(profile_args(ctx), { "--bin", exe.name })
      if #args.extra > 0 then vim.list_extend(vim.list_extend(a, { "--" }), args.extra) end
      local t = cargo(ctx, "run", a, "cargo run " .. exe.name)
      t.interactive = true
      return { t }
    end,
  },
  {
    name = "test",
    desc = "cargo test",
    run = function(ctx, args)
      local a = profile_args(ctx)
      vim.list_extend(a, ctx.opts.test_args or {})
      vim.list_extend(a, args.extra)
      return { cargo(ctx, "test", a) }
    end,
  },
  { name = "clean", desc = "cargo clean", run = function(ctx, args) return { cargo(ctx, "clean", args.extra) } end },
  {
    name = "check",
    desc = "cargo check --all-targets",
    run = function(ctx, args) return { cargo(ctx, "check", vim.list_extend({ "--all-targets" }, args.extra)) } end,
  },
  {
    name = "clippy",
    desc = "cargo clippy --all-targets",
    run = function(ctx, args) return { cargo(ctx, "clippy", vim.list_extend({ "--all-targets" }, args.extra)) } end,
  },
  { name = "fmt", desc = "cargo fmt", run = function(ctx, args) return { cargo(ctx, "fmt", args.extra) } end },
  { name = "doc", desc = "cargo doc", run = function(ctx, args) return { cargo(ctx, "doc", args.extra) } end },
}

--- Cargo profiles: the built-in ones plus the [profile.<name>] sections of the root Cargo.toml.
function M.profiles(root)
  local out = { "dev", "release" }
  for name in ("\n" .. (read(root .. "/Cargo.toml") or "")):gmatch("\n%s*%[profile%.([%w_%-]+)%]") do
    if not vim.tbl_contains(out, name) then table.insert(out, name) end
  end
  return out
end

function M.settings(ctx)
  local items = {
    { label = "Profile: " .. profile(ctx), key = "profile" },
    { label = "Run/debug binary: " .. (ctx.state.target or "(ask)"), key = "target" },
  }
  local choice = async.select(items, { prompt = "Cargo settings", format_item = function(i) return i.label end })
  if not choice then return end
  if choice.key == "profile" then
    local p = async.select(M.profiles(ctx.root), { prompt = "Profile" })
    if p then ctx:set("profile", p) end
  else
    ctx:set("target", nil)
    require("devcontainer.project").pick_executable(ctx)
  end
end

function M.describe(ctx)
  return "profile " .. profile(ctx)
end

return M
