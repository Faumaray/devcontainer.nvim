local M = {}

---@class devcontainer.Options
M.defaults = {
  -- "auto": use the devcontainer CLI when installed, plain docker otherwise. Or force "cli" / "docker".
  backend = "auto",
  -- container engine ("docker" or "podman")
  docker = "docker",
  -- reference CLI: npm install -g @devcontainers/cli
  cli = "devcontainer",
  -- extra arguments for `devcontainer up`
  cli_up_args = {},
  -- when a file/cwd inside a project with a devcontainer config is opened:
  --   "ask" = offer to start it (answers "always"/"never" are remembered per project)
  --   true  = start it right away, false = only on :Devcontainer up
  autostart = "ask",
  -- `docker stop` attached containers when Neovim exits (compose projects are stopped as a
  -- whole; devcontainer.json `"shutdownAction": "none"` keeps a container running)
  stop_on_exit = false,
  -- offer to rebuild when devcontainer.json / its Dockerfile / compose files change
  watch_config = true,
  -- how to capture the container user's environment (PATH from nvm/sdkman/...):
  -- nil = devcontainer.json `userEnvProbe` (default "loginInteractiveShell"), or
  -- "none" | "loginShell" | "interactiveShell" | "loginInteractiveShell"
  user_env_probe = nil,
  -- open container-only files (system headers, SDKs, toolchains) as devcontainer:// buffers
  remote_fs = true,
  -- which config to use when the workspace has several (.devcontainer/<name>/devcontainer.json):
  -- nil = ask, or the <name> (usually set by a profile)
  devcontainer = nil,
  -- named sets of option overrides, see :help devcontainer-profiles
  --   { asan = { desc = "...", match = { "~/work/**" }, extends = { "base" }, project = { ... } } }
  profiles = {},
  -- read customizations["devcontainer.nvim"] (settings / profiles shared by the team) from
  -- devcontainer.json; the file has to be trusted first (:help vim.secure.read)
  customizations = true,
  lsp = {
    enabled = true,
    -- "*" = every server whose root_dir lies inside an attached devcontainer; or a list of names
    servers = "*",
    -- servers that always stay on the host (e.g. "copilot")
    exclude = {},
    -- command to use inside the container, per server: { clangd = { "clangd-18", "--background-index" } }
    remote_cmd = {},
    -- server binary missing in the container: "local" = run it on the host (with a warning), "none" = don't start
    fallback = "local",
  },
  -- :Devcontainer configure/build/run/test/clean/debug — run in the container when attached, else on the host
  project = {
    -- "auto" (overseer.nvim when installed) | "overseer" | "builtin"
    runner = "auto",
    -- builtin runner output split: "always" | "on_failure" | "never"
    open_output = "always",
    output_height = 12,
    -- open the quickfix list when a task fails with parsed errors
    open_quickfix = true,
    -- environment of every project task (build, test, run)
    env = {},
    -- default program arguments for :Devcontainer run / debug without `-- args`
    run_args = {},
    cmake = {
      -- configure preset to use (default: the one picked with :Devcontainer select, else the first)
      preset = nil,
      -- used when the project has no CMakePresets.json; relative to the project root.
      -- Macros: ${buildType}, ${presetName}, ${profile} (the selected profile, "default" without)
      build_dir = "build/${buildType}",
      build_type = "Debug",
      build_types = { "Debug", "Release", "RelWithDebInfo", "MinSizeRel" },
      generator = nil, -- e.g. "Ninja" (only applied when the build dir is configured for the first time)
      configure_args = {},
      build_args = {},
      ctest_args = { "--output-on-failure" },
      -- symlink <build>/compile_commands.json into the project root for clangd
      link_compile_commands = true,
      -- working directory of :Devcontainer run/debug: "exe" (executable's dir) | "build" | "root"
      run_cwd = "exe",
    },
    cargo = {
      profile = "dev", -- "dev" | "release" | any custom profile
      features = {}, -- --features a,b
      no_default_features = false,
      build_args = {},
      test_args = {},
    },
    debug = {
      -- nvim-dap adapter used by :Devcontainer debug; registered automatically when missing
      adapter = "gdb",
      command = { "gdb", "--interpreter=dap" },
      -- extra fields merged into the launch configuration
      config = { stopAtBeginningOfMainSubprogram = false },
    },
  },
  integrations = {
    overseer = {
      -- run every overseer template task (make, just, npm, tasks.json, ...) in the container
      -- when its cwd is inside an attached workspace
      wrap_templates = true,
    },
  },
}

---@type devcontainer.Options
M.options = vim.deepcopy(M.defaults)

local function is_list(t)
  return type(t) == "table" and next(t) ~= nil and vim.islist(t)
end

--- Deep merge of option tables. Lists replace the base list; with `append_args`, lists under
--- keys ending in "_args" (configure_args, build_args, ...) are appended instead, which is how
--- profiles add flags on top of the base options.
---@param base table
---@param override table
---@param append_args? boolean
function M.merge(base, override, append_args)
  local out = vim.deepcopy(base)
  for k, v in pairs(override) do
    local b = out[k]
    if type(v) == "table" and type(b) == "table" and not getmetatable(v) then
      if is_list(v) or is_list(b) then
        if append_args and type(k) == "string" and k:match("_args$") then
          out[k] = vim.list_extend(vim.deepcopy(b), v)
        else
          out[k] = vim.deepcopy(v)
        end
      else
        out[k] = M.merge(b, v, append_args)
      end
    else
      out[k] = type(v) == "table" and vim.deepcopy(v) or v
    end
  end
  return out
end

--- Options that apply to `path` (a project or workspace root): the global options with the
--- matching / selected profiles and the devcontainer.json customizations applied.
---@param path? string
---@return devcontainer.Options
function M.get(path)
  if not path then return M.options end
  return require("devcontainer.profiles").resolve(path)
end

function M.set(opts)
  M.options = M.merge(M.defaults, opts or {})
  local o = M.options
  if o.docker == "docker" and vim.fn.executable("docker") == 0 and vim.fn.executable("podman") == 1 then
    o.docker = "podman"
  end
  require("devcontainer.profiles").invalidate()
end

return M
