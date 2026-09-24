--- :Devcontainer init — add a devcontainer configuration to a project from the official
--- templates (https://containers.dev/templates). With the devcontainer CLI the template is
--- applied (Dockerfile, scripts, options with their defaults); without it a minimal
--- image-based devcontainer.json is written.
local async = require("devcontainer.async")
local config = require("devcontainer.config")
local log = require("devcontainer.log")
local spec = require("devcontainer.spec")

local M = {}

M.TEMPLATES = {
  { id = "cpp", desc = "C++ (gcc, clang, gdb, CMake)", image = "cpp:latest" },
  { id = "rust", desc = "Rust (cargo, rust-analyzer)", image = "rust:latest" },
  { id = "python", desc = "Python 3", image = "python:latest" },
  { id = "go", desc = "Go", image = "go:latest" },
  { id = "javascript-node", desc = "Node.js, JavaScript", image = "javascript-node:latest" },
  { id = "typescript-node", desc = "Node.js, TypeScript", image = "typescript-node:latest" },
  { id = "java", desc = "Java", image = "java:latest" },
  { id = "dotnet", desc = "C# (.NET)", image = "dotnet:latest" },
  { id = "universal", desc = "many languages in one (large)", image = "universal:latest" },
  { id = "ubuntu", desc = "Ubuntu base", image = "base:ubuntu" },
  { id = "debian", desc = "Debian base", image = "base:debian" },
  { id = "alpine", desc = "Alpine base", image = "base:alpine" },
}

--- OCI reference of a template id ("cpp" -> ghcr.io/devcontainers/templates/cpp).
function M.template_ref(id)
  if id:find("/", 1, true) then return id end
  return "ghcr.io/devcontainers/templates/" .. id
end

--- Minimal devcontainer.json (JSONC) for an image.
function M.minimal_config(name, image)
  if not image:find("/", 1, true) then image = "mcr.microsoft.com/devcontainers/" .. image end
  return table.concat({
    "// See https://containers.dev/implementors/json_reference/",
    "{",
    ("  \"name\": %s,"):format(vim.json.encode(name)),
    ("  \"image\": %s,"):format(vim.json.encode(image)),
    "  // \"features\": {},",
    "  // \"forwardPorts\": [],",
    "  // \"postCreateCommand\": \"\",",
    "}",
    "",
  }, "\n")
end

local function ask_start(root, file)
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.ui.select({ "Start it now", "Later" }, { prompt = "Devcontainer configuration created", kind = "devcontainer.start" }, function(choice)
    if choice == "Start it now" then require("devcontainer").up({ path = root }) end
  end)
end

--- Create a devcontainer config for the project containing `path` (git root, else `path`).
---@param path string
function M.init(path)
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  local root = spec.normalize_dir(vim.fs.root(dir, ".git") or dir)
  local existing = spec.list_configs(root)
  if #existing > 0 then
    log.info(("%s already has a devcontainer configuration"):format(vim.fn.fnamemodify(root, ":~")))
    return vim.cmd.edit(vim.fn.fnameescape(existing[1]))
  end
  local cli = config.options.cli
  local have_cli = vim.fn.executable(cli) == 1
  local items = vim.deepcopy(M.TEMPLATES)
  table.insert(items, { id = "other", desc = have_cli and "another template (OCI reference) or image" or "another image" })

  async.run(function()
    local choice = async.select(items, {
      prompt = ("Devcontainer for %s"):format(vim.fn.fnamemodify(root, ":~")),
      format_item = function(t) return ("%-16s %s"):format(t.id, t.desc) end,
      kind = "devcontainer.template",
    })
    if not choice then return end
    local id, image = choice.id, choice.image
    if id == "other" then
      local value = async.input({ prompt = have_cli and "Template (ghcr.io/...) or image: " or "Image: " })
      if not value or vim.trim(value) == "" then return end
      value = vim.trim(value)
      local is_template = have_cli and value:find("/templates/", 1, true) ~= nil
      id, image = is_template and value or nil, (not is_template) and value or nil
    end

    local file = root .. "/.devcontainer/devcontainer.json"
    if have_cli and id then
      log.info("applying template " .. M.template_ref(id))
      local stream = function(_, data) log.append(data) end
      local res = async.system({
        cli, "templates", "apply", "--workspace-folder", root, "--template-id", M.template_ref(id),
        "--omit-paths", '[".github/*"]',
      }, { text = true, stdout = stream, stderr = stream })
      if res.code ~= 0 or not vim.uv.fs_stat(file) then
        error("`devcontainer templates apply` failed (see :Devcontainer log)", 0)
      end
    else
      vim.fn.mkdir(vim.fs.dirname(file), "p")
      local f = assert(io.open(file, "w"))
      f:write(M.minimal_config(vim.fs.basename(root), image))
      f:close()
    end
    spec.clear_cache()
    ask_start(root, file)
  end, function(err)
    if err then log.error(tostring(err)) end
  end)
end

return M
