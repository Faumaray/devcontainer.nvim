--- Shell-style quoting for command arguments that are passed without a shell (argv): what a
--- terminal would do with `-DX="a b"` before cmake sees it.
local M = {}

--- Split `str` into words the way a POSIX shell does (quotes, backslashes). Unbalanced quotes are
--- kept as written.
---@param str string
---@return string[]
function M.split(str)
  local words, cur, has = {}, {}, false
  local i, n = 1, #str
  local function push()
    if has then words[#words + 1] = table.concat(cur) end
    cur, has = {}, false
  end
  while i <= n do
    local c = str:sub(i, i)
    if c:match("%s") then
      push()
      i = i + 1
    elseif c == "'" then
      local j = str:find("'", i + 1, true)
      if not j then cur[#cur + 1], has, i = str:sub(i), true, n + 1
      else cur[#cur + 1], has, i = str:sub(i + 1, j - 1), true, j + 1 end
    elseif c == '"' then
      local j, buf, closed = i + 1, {}, false
      while j <= n do
        local d = str:sub(j, j)
        if d == "\\" and str:sub(j + 1, j + 1):match('["\\$`]') then
          buf[#buf + 1] = str:sub(j + 1, j + 1)
          j = j + 2
        elseif d == '"' then
          closed = true
          break
        else
          buf[#buf + 1] = d
          j = j + 1
        end
      end
      if closed then cur[#cur + 1], has, i = table.concat(buf), true, j + 1
      else cur[#cur + 1], has, i = str:sub(i), true, n + 1 end
    elseif c == "\\" and i < n then
      cur[#cur + 1], has, i = str:sub(i + 1, i + 1), true, i + 2
    else
      cur[#cur + 1], has, i = c, true, i + 1
    end
  end
  push()
  return words
end

--- One configured argument: quotes and backslashes removed like a shell would. An argument
--- without any is returned as is (spaces stay part of it).
---@param arg string
---@return string
function M.unquote(arg)
  if type(arg) ~= "string" or not arg:find("['\"\\]") then return arg end
  local words = M.split(arg)
  -- unquoted spaces around the quotes: it was written as several words, keep it as it is
  return #words == 1 and words[1] or arg
end

--- A list of configured arguments, unquoted.
---@param list string[]?
---@return string[]
function M.args(list)
  return vim.tbl_map(M.unquote, list or {})
end

return M
