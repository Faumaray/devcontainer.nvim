--- Tiny coroutine helpers so container orchestration reads top to bottom.
local M = {}

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    vim.notify("devcontainer: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Run `fn` in a coroutine; `done(err)` is called when it finishes or fails.
function M.run(fn, done)
  resume(coroutine.create(function()
    local ok, err = pcall(fn)
    if done then
      done(not ok and err or nil)
    elseif not ok then
      error(err, 0)
    end
  end))
end

--- vim.system that yields until the process exits. Must be called inside M.run.
function M.system(cmd, opts)
  local co = assert(coroutine.running(), "async.system() outside of a coroutine")
  local ok, err = pcall(vim.system, cmd, opts or {}, function(res)
    vim.schedule(function() resume(co, res) end)
  end)
  if not ok then
    error(("cannot run `%s`: %s"):format(cmd[1], err), 0)
  end
  return coroutine.yield()
end

--- Like M.system but raises when the command fails.
function M.check(cmd, opts)
  local res = M.system(cmd, opts)
  if res.code ~= 0 then
    local stderr = vim.trim(res.stderr or "")
    error(("`%s` failed with exit code %d%s"):format(
      table.concat(vim.list_slice(cmd, 1, 2), " "),
      res.code,
      stderr ~= "" and (": " .. stderr:sub(-400)) or " (see :Devcontainer log)"
    ), 0)
  end
  return res
end

function M.select(items, opts)
  local co = assert(coroutine.running())
  vim.ui.select(items, opts, function(choice)
    vim.schedule(function() resume(co, choice) end)
  end)
  return coroutine.yield()
end

return M
