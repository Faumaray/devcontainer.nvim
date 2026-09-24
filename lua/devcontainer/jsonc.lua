--- devcontainer.json is JSON with comments and trailing commas.
local M = {}

local function strip_comments(s)
  local out, i, n, in_str = {}, 1, #s, false
  while i <= n do
    local c = s:byte(i)
    if in_str then
      if c == 92 then -- backslash: copy the escaped char verbatim
        out[#out + 1] = s:sub(i, i + 1)
        i = i + 2
      else
        if c == 34 then in_str = false end
        out[#out + 1] = string.char(c)
        i = i + 1
      end
    elseif c == 34 then
      in_str = true
      out[#out + 1] = '"'
      i = i + 1
    elseif c == 47 and s:byte(i + 1) == 47 then -- // line comment
      i = s:find("\n", i + 2, true) or n + 1
    elseif c == 47 and s:byte(i + 1) == 42 then -- /* block comment */
      local j = s:find("*/", i + 2, true)
      out[#out + 1] = " "
      i = j and j + 2 or n + 1
    else
      out[#out + 1] = string.char(c)
      i = i + 1
    end
  end
  return table.concat(out)
end

local function strip_trailing_commas(s)
  local out, i, n, in_str = {}, 1, #s, false
  while i <= n do
    local c = s:sub(i, i)
    local skip = false
    if in_str then
      if c == "\\" then
        out[#out + 1] = s:sub(i, i + 1)
        i = i + 2
        skip = true
      elseif c == '"' then
        in_str = false
      end
    elseif c == '"' then
      in_str = true
    elseif c == "," then
      local j = s:find("%S", i + 1)
      local nxt = j and s:sub(j, j)
      if nxt == "}" or nxt == "]" then
        i = i + 1
        skip = true
      end
    end
    if not skip then
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

function M.decode(s)
  s = s:gsub("^\239\187\191", "") -- BOM
  return vim.json.decode(strip_trailing_commas(strip_comments(s)), { luanil = { object = true, array = true } })
end

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil, "cannot read " .. path
  end
  local s = f:read("*a")
  f:close()
  local ok, res = pcall(M.decode, s)
  if not ok then
    return nil, ("%s: %s"):format(path, res)
  end
  return res
end

return M
