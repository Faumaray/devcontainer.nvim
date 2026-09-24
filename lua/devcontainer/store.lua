--- Small JSON store in stdpath("data") for per-project choices:
--- autostart decisions, selected CMake preset/build type, cargo profile, targets, run args.
local M = {}

local data ---@type table?

function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "devcontainer.nvim", "state.json")
end

local function load()
  if data then return data end
  data = { projects = {} }
  local f = io.open(M.path(), "r")
  if f then
    local ok, decoded = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
    f:close()
    if ok and type(decoded) == "table" and type(decoded.projects) == "table" then data = decoded end
  end
  return data
end

local function save()
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(vim.json.encode(data))
  f:close()
  vim.uv.fs_rename(tmp, path)
end

--- State table of a project (a copy; use M.set to change it).
---@param root string
---@return table
function M.get(root)
  return vim.deepcopy(load().projects[root] or {})
end

--- Set `key` (dot separated: "cmake.preset") for a project; nil removes it.
function M.set(root, key, value)
  local projects = load().projects
  local t = projects[root] or {}
  projects[root] = t
  local parts = vim.split(key, ".", { plain = true })
  for i = 1, #parts - 1 do
    t[parts[i]] = type(t[parts[i]]) == "table" and t[parts[i]] or {}
    t = t[parts[i]]
  end
  t[parts[#parts]] = value
  if next(projects[root]) == nil then projects[root] = nil end
  save()
end

--- Forget everything about a project (or one key).
function M.clear(root, key)
  if key then return M.set(root, key, nil) end
  load().projects[root] = nil
  save()
end

--- For tests.
function M._reset(path_override)
  data = nil
  if path_override then M.path = function() return path_override end end
end

return M
