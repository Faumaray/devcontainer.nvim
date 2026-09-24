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
  -- `docker stop` attached containers when Neovim exits
  stop_on_exit = false,
  -- how to capture the container user's environment (PATH from nvm/sdkman/...):
  -- nil = devcontainer.json `userEnvProbe` (default "loginInteractiveShell"), or
  -- "none" | "loginShell" | "interactiveShell" | "loginInteractiveShell"
  user_env_probe = nil,
  -- open container-only files (system headers, SDKs, toolchains) as devcontainer:// buffers
  remote_fs = true,
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
    cmake = {
      -- used when the project has no CMakePresets.json; relative to the project root
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

function M.set(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- lists should replace, not merge index-by-index
  if opts and opts.lsp then
    for _, k in ipairs({ "servers", "exclude" }) do
      if opts.lsp[k] ~= nil then
        M.options.lsp[k] = opts.lsp[k]
      end
    end
  end
  local p = opts and opts.project or {}
  for _, section in ipairs({ "cmake", "cargo", "debug" }) do
    for k, v in pairs(p[section] or {}) do
      if vim.islist(v) then M.options.project[section][k] = v end
    end
  end
  local o = M.options
  if o.docker == "docker" and vim.fn.executable("docker") == 0 and vim.fn.executable("podman") == 1 then
    o.docker = "podman"
  end
end

return M
