--- :Devcontainer files [dir] — find and open files that exist only in the container (system
--- headers, SDKs, toolchains, installed packages) with snacks.picker, telescope, fzf-lua or
--- vim.ui.select (the `picker` option). They open as devcontainer:// buffers.
local config = require("devcontainer.config")
local log = require("devcontainer.log")

local M = {}

-- `fd` when the image has it (fast, respects nothing but hidden files), else `find`
local LIST_SCRIPT = [[
if command -v fd >/dev/null 2>&1; then exec fd --type f --hidden --absolute-path --no-ignore . "$1"
elif command -v fdfind >/dev/null 2>&1; then exec fdfind --type f --hidden --absolute-path --no-ignore . "$1"
else exec find "$1" -type f 2>/dev/null; fi]]

-- prints the roots (globs, ~ = the remote user's home) that exist
local ROOTS_SCRIPT = [[
for pat; do
  case "$pat" in "~"*) pat="$HOME${pat#\~}";; esac
  for d in $pat; do [ -d "$d" ] && echo "$d"; done
done]]

--- argv (host) listing the files below `dir` in the container.
function M.list_argv(session, dir)
  return session:exec_argv({ "/bin/sh", "-c", LIST_SCRIPT, "sh", dir })
end

--- argv (host) printing the first lines of a container file (previews).
function M.head_argv(session, path)
  return session:exec_argv({ "head", "-c", "65536", "--", path }, { env = false })
end

function M.buffer_name(session, path)
  return "devcontainer://" .. session.key .. path
end

function M.open(session, path)
  if path and path ~= "" then vim.cmd.edit(vim.fn.fnameescape(M.buffer_name(session, path))) end
end

--- Configured roots that exist in the container.
function M.roots(session)
  local argv = session:exec_argv(vim.list_extend({ "/bin/sh", "-c", ROOTS_SCRIPT, "sh" }, config.options.files.roots or {}))
  local res = vim.system(argv, { text = true }):wait(10000)
  return vim.split(res.stdout or "", "\n", { trimempty = true })
end

local function preview_lines(session, path)
  local res = vim.system(M.head_argv(session, path), { text = true }):wait(5000)
  return vim.split((res.stdout or ""):gsub("\r", ""), "\n", { plain = true })
end

local function shell_join(argv)
  return table.concat(vim.tbl_map(vim.fn.shellescape, argv), " ")
end

local pickers = {}

function pickers.snacks(session, dir)
  Snacks.picker.pick({
    source = "devcontainer_files",
    title = ("%s: %s"):format(session.name, dir),
    finder = function(_, ctx)
      local argv = M.list_argv(session, dir)
      return require("snacks.picker.source.proc").proc(ctx:opts({
        cmd = argv[1],
        args = vim.list_slice(argv, 2),
        transform = function(item) item.path = item.text end,
      }), ctx)
    end,
    format = "text",
    preview = function(ctx)
      ctx.preview:reset()
      ctx.preview:set_lines(preview_lines(session, ctx.item.path))
      local ft = vim.filetype.match({ filename = ctx.item.path })
      if ft then ctx.preview:highlight({ ft = ft }) end
    end,
    confirm = function(picker, item)
      picker:close()
      if item then M.open(session, item.path) end
    end,
  })
end

function pickers.telescope(session, dir)
  local conf = require("telescope.config").values
  local actions, state = require("telescope.actions"), require("telescope.actions.state")
  require("telescope.pickers").new({}, {
    prompt_title = ("%s: %s"):format(session.name, dir),
    finder = require("telescope.finders").new_oneshot_job(M.list_argv(session, dir), {}),
    sorter = conf.file_sorter({}),
    previewer = require("telescope.previewers").new_buffer_previewer({
      define_preview = function(self, entry)
        local path = entry.value or entry[1]
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines(session, path))
        local ft = vim.filetype.match({ filename = path })
        if ft then pcall(require("telescope.previewers.utils").highlighter, self.state.bufnr, ft) end
      end,
    }),
    attach_mappings = function(bufnr)
      actions.select_default:replace(function()
        local entry = state.get_selected_entry()
        actions.close(bufnr)
        if entry then M.open(session, entry.value or entry[1]) end
      end)
      return true
    end,
  }):find()
end

pickers["fzf-lua"] = function(session, dir)
  local head = M.head_argv(session, "PLACEHOLDER")
  head[#head] = nil
  require("fzf-lua").fzf_exec(shell_join(M.list_argv(session, dir)), {
    prompt = session.name .. "> ",
    preview = shell_join(head) .. " {}",
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then M.open(session, selected[1]) end
      end,
    },
  })
end

M.MAX_SELECT = 5000

function pickers.select(session, dir)
  local res = vim.system(M.list_argv(session, dir), { text = true }):wait(30000)
  local files = vim.split(res.stdout or "", "\n", { trimempty = true })
  if #files > M.MAX_SELECT then
    log.warn(("%d files below %s, showing the first %d (a picker plugin handles more)"):format(#files, dir, M.MAX_SELECT))
    files = vim.list_slice(files, 1, M.MAX_SELECT)
  end
  vim.ui.select(files, { prompt = ("%s: %s"):format(session.name, dir), kind = "devcontainer.files" }, function(path)
    M.open(session, path)
  end)
end

--- Which picker the `picker` option resolves to.
function M.backend()
  local p = config.options.picker
  if pickers[p] then return p end
  if p == "fzf_lua" then return "fzf-lua" end
  local snacks = rawget(_G, "Snacks")
  if snacks and snacks.picker then return "snacks" end
  if pcall(require, "telescope.pickers") then return "telescope" end
  if pcall(require, "fzf-lua") then return "fzf-lua" end
  return "select"
end

--- Pick a file below `dir` (or first a root from `files.roots`) and open it.
---@param session devcontainer.Session
---@param dir? string
function M.files(session, dir)
  local backend = M.backend()
  if dir and dir ~= "" then return pickers[backend](session, dir) end
  local roots = M.roots(session)
  if #roots == 0 then return log.warn("none of files.roots exists in " .. session.name .. " (:Devcontainer files <dir>)") end
  vim.ui.select(roots, { prompt = "Folder in " .. session.name, kind = "devcontainer.roots" }, function(root)
    if root then pickers[backend](session, root) end
  end)
end

return M
