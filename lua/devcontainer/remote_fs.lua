--- devcontainer://<container-id>/abs/path buffers: files that only exist inside the container
--- (system headers, SDKs, toolchains). Go-to-definition into them works like in VS Code.
local log = require("devcontainer.log")
local registry = require("devcontainer.session")

local M = {}

local function parse(name)
  return name:match("^devcontainer://([^/]+)(/.*)$")
end

local function detect_filetype(buf, path)
  local ft = vim.filetype.match({ buf = buf, filename = path })
  if not ft and path:find("/include/", 1, true) then
    ft = "cpp" -- extensionless C++ standard library headers: <vector>, <memory>, ...
  end
  return ft
end

local function read(ev)
  local buf = ev.buf
  local name = vim.api.nvim_buf_get_name(buf)
  local key, path = parse(name)
  local session = key and registry.by_key[key]
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  if not session then
    log.warn("no attached devcontainer for " .. name)
    return
  end

  local res = vim.system(session:exec_argv({ "cat", "--", path }, { env = false }), {}):wait(20000)
  if res.code ~= 0 then
    log.error(("cannot read %s in %s: %s"):format(path, session.name, vim.trim(res.stderr or "")))
    return
  end
  local data = res.stdout or ""
  local eol = data:sub(-1) == "\n"
  if eol then data = data:sub(1, -2) end
  local lines = vim.split(data, "\n", { plain = true })
  if vim.o.fileformats:find("dos", 1, true) and data:find("\r\n", 1, true) then
    vim.bo[buf].fileformat = "dos"
    for i, l in ipairs(lines) do lines[i] = l:gsub("\r$", "") end
  end

  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
  vim.bo[buf].eol = eol or data == ""
  vim.bo[buf].modified = false

  local ft = detect_filetype(buf, path)
  if ft and vim.bo[buf].filetype ~= ft then vim.bo[buf].filetype = ft end

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) and registry.by_key[key] then
      require("devcontainer.lsp").attach_remote_buffer(buf, session)
    end
  end)
end

local function write(ev)
  local buf = ev.buf
  local target = ev.match ~= "" and ev.match or vim.api.nvim_buf_get_name(buf)
  local key, path = parse(target)
  local session = key and registry.by_key[key]
  if not session then
    return log.error("cannot write " .. target .. ": devcontainer is not attached")
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local nl = vim.bo[buf].fileformat == "dos" and "\r\n" or "\n"
  local data = ""
  if not (#lines == 1 and lines[1] == "") then
    data = table.concat(lines, nl)
    if vim.bo[buf].eol or vim.bo[buf].fixeol then data = data .. nl end
  end
  local argv = session:exec_argv({ "/bin/sh", "-c", 'cat > "$1"', "sh", path }, { stdin = true, env = false })
  local res = vim.system(argv, { stdin = data }):wait(20000)
  if res.code ~= 0 then
    return log.error(("cannot write %s in %s: %s"):format(path, session.name, vim.trim(res.stderr or "")))
  end
  if target == vim.api.nvim_buf_get_name(buf) then vim.bo[buf].modified = false end
  vim.api.nvim_echo({ { ('"%s" %dL, %dB written'):format(target, #lines, #data) } }, false, {})
end

function M.setup()
  local group = vim.api.nvim_create_augroup("devcontainer.remote_fs", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", { group = group, pattern = "devcontainer://*", callback = read })
  vim.api.nvim_create_autocmd("BufWriteCmd", { group = group, pattern = "devcontainer://*", callback = write })
end

return M
