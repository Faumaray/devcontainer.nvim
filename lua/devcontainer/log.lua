local M = {}

local MAX_LINES = 10000
local lines = {}
local bufnr

local function clean(s)
  s = s:gsub("\27%[[%d;?]*[A-Za-z]", "")
  s = s:gsub("\r\n?", "\n")
  return s
end

local subscribers = {}

--- Call `fn(lines)` for everything appended from now on (from luv callbacks too: keep it fast).
---@return fun() unsubscribe
function M.subscribe(fn)
  subscribers[fn] = true
  return function() subscribers[fn] = nil end
end

--- Append raw output (build logs, stderr, ...) to the log buffer. Safe to call from luv callbacks.
function M.append(data)
  if type(data) ~= "string" or data == "" then
    return
  end
  local new = vim.split(clean(data), "\n", { plain = true, trimempty = true })
  for fn in pairs(subscribers) do pcall(fn, new) end
  vim.schedule(function()
    vim.list_extend(lines, new)
    if #lines > MAX_LINES then
      lines = vim.list_slice(lines, #lines - MAX_LINES + 1)
    end
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new)
      vim.bo[bufnr].modifiable = false
      local last = vim.api.nvim_buf_line_count(bufnr)
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        vim.api.nvim_win_set_cursor(win, { last, 0 })
      end
    end
  end)
end

local function notify(msg, level)
  M.append(msg)
  vim.schedule(function()
    vim.notify(msg, level, { title = "devcontainer" })
  end)
end

function M.info(msg) notify(msg, vim.log.levels.INFO) end
function M.warn(msg) notify(msg, vim.log.levels.WARN) end
function M.error(msg) notify(tostring(msg), vim.log.levels.ERROR) end

function M.open()
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "devcontainer-log")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].filetype = "log"
  end
  vim.cmd("botright sbuffer " .. bufnr)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), 0 })
end

return M
