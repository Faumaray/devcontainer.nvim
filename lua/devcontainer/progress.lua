--- Progress of `:Devcontainer up` (image build, container start, lifecycle hooks) through
--- fidget.nvim, snacks.nvim's notifier or a plain echo, per the `progress` option.
local config = require("devcontainer.config")

local M = {}

--- Interesting part of a build / CLI log line: message and percentage, or nil to skip it.
---@return string? message, integer? percent
function M.parse_line(line)
  line = vim.trim(line or "")
  if line == "" then return nil end
  if line:sub(1, 1) == "{" then
    -- devcontainer CLI JSON log: {"type":"text","text":"..."} / {"type":"start","text":"..."}
    local ok, obj = pcall(vim.json.decode, line)
    if not ok or type(obj) ~= "table" then return nil end
    if obj.outcome then return nil end -- the final result line
    local text = obj.text or obj.name
    if type(text) ~= "string" or text == "" then return nil end
    return M.parse_line(text)
  end
  line = line:gsub("^%[%d+ ms%]%s*", "") -- CLI text log timestamps
  -- BuildKit "#8 [build 3/7] RUN ...", classic builder "Step 3/7 : RUN ..."
  local cur, total = line:match("%[[^%]]-(%d+)/(%d+)%]")
  if not cur then cur, total = line:match("^Step (%d+)/(%d+)") end
  if cur and tonumber(total) > 0 then
    local msg = line:gsub("^#%d+%s+", "")
    return msg, math.floor(tonumber(cur) * 100 / tonumber(total))
  end
  if line:match("^#%d+ ") then return nil end -- BuildKit step output: too chatty
  return line
end

local function shorten(msg)
  msg = msg:gsub("%s+", " ")
  return #msg > 80 and (msg:sub(1, 77) .. "...") or msg
end

local backends = {}

function backends.fidget(title)
  local h = require("fidget.progress.handle").create({
    title = title,
    message = "starting",
    lsp_client = { name = "devcontainer" },
    percentage = 0,
  })
  return {
    report = function(msg, pct) h:report({ message = msg, percentage = pct }) end,
    finish = function(_, msg)
      h:report({ message = msg })
      h:finish()
    end,
  }
end

function backends.snacks(title)
  local id = "devcontainer_progress_" .. title
  return {
    report = function(msg, pct)
      Snacks.notifier.notify(pct and ("%s (%d%%)"):format(msg, pct) or msg, "info", { id = id, title = title, timeout = false })
    end,
    finish = function() Snacks.notifier.hide(id) end,
  }
end

function backends.echo(title)
  return {
    report = function(msg, pct)
      vim.api.nvim_echo({ { ("%s: %s%s"):format(title, msg, pct and (" (%d%%)"):format(pct) or "") } }, false, {})
    end,
    finish = function() vim.api.nvim_echo({ { "" } }, false, {}) end,
  }
end

--- Which backend `progress = "auto"` picks.
function M.backend()
  local p = config.options.progress
  if p == false or p == nil then return nil end
  if p == "fidget" or p == "snacks" or p == "echo" then return p end
  if pcall(require, "fidget.progress.handle") then return "fidget" end
  local snacks = rawget(_G, "Snacks")
  if snacks and snacks.notifier and snacks.config and type(snacks.config.notifier) == "table" and snacks.config.notifier.enabled then
    return "snacks"
  end
  return "echo"
end

---@class devcontainer.Progress
---@field report fun(self: devcontainer.Progress, msg: string, pct?: integer)  (any context)
---@field feed fun(self: devcontainer.Progress, lines: string[])            log lines (any context)
---@field finish fun(self: devcontainer.Progress, ok: boolean, msg?: string)

--- Start a progress report. Every method may be called from luv callbacks.
---@return devcontainer.Progress
function M.start(title)
  local name = M.backend()
  local impl = name and backends[name](title)
  local last, pending, scheduled, done = 0, nil, false, false
  local self = {}
  local function flush()
    scheduled = false
    last = vim.uv.now()
    if done or not pending then return end
    local p = pending
    pending = nil
    pcall(impl.report, p[1], p[2])
  end
  -- at most one update per 100ms; the latest message wins
  function self:report(msg, pct)
    if not impl or done then return end
    pending = { shorten(msg), pct }
    if scheduled then return end
    scheduled = true
    vim.defer_fn(flush, math.max(0, 100 - (vim.uv.now() - last)))
  end
  function self:feed(lines)
    for _, l in ipairs(lines) do
      local msg, pct = M.parse_line(l)
      if msg then self:report(msg, pct) end
    end
  end
  function self:finish(ok, msg)
    if not impl or done then return end
    done = true
    vim.schedule(function() pcall(impl.finish, ok, msg or (ok and "done" or "failed")) end)
  end
  return self
end

return M
