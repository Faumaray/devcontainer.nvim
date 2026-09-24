--- Translation of paths/URIs between the host workspace and the container workspace.
---
---   host:      file:///home/me/proj/src/a.cpp     <->  container: file:///workspaces/proj/src/a.cpp
---   host:      devcontainer://<id>/usr/include/x  <->  container: file:///usr/include/x
---
--- Only pure Lua here: it runs inside luv callbacks for the DAP proxy.
local M = {}

-- Strings under these keys are document contents or user-facing text: never rewrite them.
local VERBATIM = {
  text = true, newText = true, insertText = true, filterText = true, label = true,
  detail = true, message = true, output = true, expression = true, result = true,
}
-- Markdown: only rewrite workspace URIs embedded in the text (links in hover docs).
local MARKUP = { value = true, documentation = true }

local function under(path, root)
  if path == root then return "" end
  if #path > #root and path:byte(#root + 1) == 47 and path:sub(1, #root) == root then
    return path:sub(#root + 1)
  end
end

local function uri_path(s)
  local ok, path = pcall(vim.uri_to_fname, s)
  return ok and path or nil
end

--- Copy-on-write deep map over strings (and URI-like keys). Metatables are kept so
--- vim.empty_dict()/array markers still encode correctly.
local function walk(v, key, fn)
  local t = type(v)
  if t == "string" then return fn(v, key) end
  if t ~= "table" then return v end
  if #v > 256 and type(v[1]) == "number" then return v end -- e.g. semantic tokens
  local copy
  for k, val in pairs(v) do
    local nv = walk(val, k, fn)
    local nk = k
    if type(k) == "string" and k:find("://", 1, true) then nk = fn(k, nil) end -- WorkspaceEdit.changes
    if nv ~= val or nk ~= k then
      if not copy then
        copy = setmetatable({}, getmetatable(v))
        for kk, vv in pairs(v) do copy[kk] = vv end
      end
      if nk ~= k then copy[k] = nil end
      copy[nk] = nv
    end
  end
  return copy or v
end

---@class devcontainer.Translator
local Translator = {}
Translator.__index = Translator

---@param opts { local_roots: string[], remote_root: string, scheme?: string }
function M.new(opts)
  local self = setmetatable({
    local_roots = opts.local_roots,
    local_root = opts.local_roots[1],
    remote_root = opts.remote_root,
    scheme = opts.scheme, -- nil: leave paths outside the workspace alone (DAP)
  }, Translator)
  self.remote_uri = vim.uri_from_fname(self.remote_root) .. "/"
  self.remote_uri_pat = vim.pesc(self.remote_uri)
  self.local_uri_repl = (vim.uri_from_fname(self.local_root) .. "/"):gsub("%%", "%%%%")
  return self
end

function Translator:path_to_remote(path)
  for _, root in ipairs(self.local_roots) do
    local rest = under(path, root)
    if rest then return self.remote_root .. rest end
  end
end

function Translator:path_to_local(path)
  local rest = under(path, self.remote_root)
  if rest then return self.local_root .. rest end
end

function Translator:str_to_remote(s, key)
  if VERBATIM[key] or MARKUP[key] then return s end
  if s:sub(1, 7) == "file://" then
    local path = uri_path(s)
    local mapped = path and self:path_to_remote(path)
    return mapped and vim.uri_from_fname(mapped) or s
  end
  if self.scheme and s:sub(1, #self.scheme) == self.scheme then
    local path = s:sub(#self.scheme + 1)
    return path:byte(1) == 47 and vim.uri_from_fname(path) or s
  end
  if s:byte(1) == 47 then return self:path_to_remote(s) or s end
  return s
end

function Translator:str_to_local(s, key)
  if VERBATIM[key] then return s end
  if MARKUP[key] then
    if s:find(self.remote_uri, 1, true) then
      return (s:gsub(self.remote_uri_pat, self.local_uri_repl))
    end
    return s
  end
  if s:sub(1, 7) == "file://" then
    local path = uri_path(s)
    if not path then return s end
    local mapped = self:path_to_local(path)
    if mapped then return vim.uri_from_fname(mapped) end
    return self.scheme and (self.scheme .. path) or s
  end
  if s:byte(1) == 47 then return self:path_to_local(s) or s end
  return s
end

function Translator:to_remote(v)
  return walk(v, nil, function(s, key) return self:str_to_remote(s, key) end)
end

function Translator:to_local(v)
  return walk(v, nil, function(s, key) return self:str_to_local(s, key) end)
end

return M
