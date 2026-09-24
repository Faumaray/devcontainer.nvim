# devcontainer.nvim

VS Code–style devcontainers for Neovim: **Neovim runs on your host; language servers, debug
adapters and builds run inside the container.** Your editor, config, keymaps and plugins stay
local. The toolchain (clangd, rust-analyzer, gdb, CMake, cargo, SDKs, system headers) lives in the
container described by the project's `.devcontainer/devcontainer.json`.

```
 host                                   container
 ┌──────────────────────┐   docker exec -i   ┌────────────────────────────┐
 │ nvim                 │ ─────────────────▶ │ clangd / gdb / cmake / ... │
 │ /home/me/proj/a.cpp  │ ◀── translated ─── │ /workspaces/proj/a.cpp     │
 └──────────────────────┘      paths         └────────────────────────────┘
```

## Features

- **Start the container when you open a project.** When you open a file (or `cd`) inside a project
  with a devcontainer config, you're asked whether to start it. "Always" and "Never" answers are
  remembered per project.
- **`:Devcontainer up`** builds and starts the container.
  - With [`@devcontainers/cli`](https://github.com/devcontainers/cli) installed you get the full
    spec: features, docker compose, UID remapping and lifecycle hooks.
  - Without it, a built-in docker/podman backend handles `image` and `build` configs.
  - Containers created by VS Code or the CLI are reused, because the same labels are used.
- **LSP inside the container.** Any server started through `vim.lsp.enable()`, nvim-lspconfig,
  rustaceanvim or `vim.lsp.start()` is transparently spawned with `docker exec` when its root is in
  an attached workspace.
  - Clients that were already running on the host are moved into the container on `up`, and moved
    back on `stop`.
  - URIs are translated in both directions: diagnostics, definitions, workspace edits, file
    watchers, and markdown links in hover docs.
- **Files that exist only in the container** (`/usr/include/c++/13/vector`, SDKs, toolchains) open
  as `devcontainer://<id>/...` buffers. "Go to definition" into the standard library works like in
  VS Code.
- **Build, run, test and debug CMake and Cargo projects** with `:Devcontainer configure / build /
  run / test / clean / debug`. They run in the container when one is attached and on the host
  otherwise. Compiler errors land in the quickfix list, pointing at host files.
- **Debugging inside the container** with [nvim-dap](https://github.com/mfussenegger/nvim-dap):
  stdio adapters (`gdb -i dap`, `lldb-dap`, `OpenDebugAD7`) run behind a local proxy that translates
  paths. `runInTerminal` becomes `docker exec -it`.
- **Integrations:** [overseer.nvim](https://github.com/stevearc/overseer.nvim),
  [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim),
  [rustaceanvim](https://github.com/mrcjkb/rustaceanvim), and any `vim.ui.select` picker
  (telescope, fzf-lua, snacks).
- **Container user environment.** `remoteUser`, `remoteEnv` and `userEnvProbe` are honoured, so a
  `PATH` from nvm, sdkman, rustup, `/opt/toolchain/bin`, etc. is picked up.
- **Other commands.** `:Devcontainer shell` / `exec <cmd>` open terminals in the container.
  `:Devcontainer log` shows build output. `:checkhealth devcontainer` checks your setup.

## Requirements

- Neovim ≥ 0.11
- docker or podman on the host (your user must be able to talk to the daemon)
- *optional:* `npm install -g @devcontainers/cli` (recommended; needed for features and compose)
- *optional:* nvim-dap, overseer.nvim, lualine.nvim, rustaceanvim
- The language servers, debuggers and build tools must be installed **in the container image**,
  not on the host.

## Installation

lazy.nvim:

```lua
{
  "you/devcontainer.nvim",
  lazy = false, -- must be loaded before the first LSP client starts
  opts = {},
}
```

zpack.nvim / `vim.pack` (Neovim 0.12+) install plugins with `git clone`. For a local copy, the
folder must be a git repository with at least one commit:

```lua
-- lua/plugins/devcontainer.lua
return { dir = "~/src/devcontainer.nvim", lazy = false, opts = {} }
```

Since that is a clone, local edits need a commit plus `:ZPack update devcontainer.nvim`. While
you're hacking on the plugin, load it straight from the folder instead:

```lua
vim.opt.rtp:prepend(vim.fn.expand("~/src/devcontainer.nvim"))
require("devcontainer").setup({})
```

## Configuration

These are the defaults:

```lua
require("devcontainer").setup({
  backend = "auto",        -- "auto" (CLI if installed, else docker) | "cli" | "docker"
  docker = "docker",       -- or "podman" (picked automatically if docker is missing)
  cli = "devcontainer",    -- path to @devcontainers/cli
  cli_up_args = {},        -- extra args for `devcontainer up`
  -- opening a project with a devcontainer config:
  --   "ask" = offer to start it (always/never answers are remembered per project)
  --   true  = start it without asking, false = only on :Devcontainer up
  autostart = "ask",
  stop_on_exit = false,    -- `docker stop` attached containers when Neovim exits
  user_env_probe = nil,    -- override devcontainer.json userEnvProbe:
                           -- "none" | "loginShell" | "interactiveShell" | "loginInteractiveShell"
  remote_fs = true,        -- open container-only files as devcontainer:// buffers
  lsp = {
    enabled = true,
    servers = "*",         -- "*" or a list of server names to run in the container
    exclude = {},          -- servers that always stay on the host, e.g. { "copilot" }
    remote_cmd = {},       -- per-server command in the container:
                           --   { clangd = { "clangd-18", "--background-index", "--clang-tidy" } }
                           -- or a function(host_cmd, session) -> argv
    fallback = "local",    -- server missing in the container: "local" (run on host, warn) | "none"
  },
  project = {
    runner = "auto",       -- "auto" (overseer.nvim when installed) | "overseer" | "builtin"
    open_output = "always",-- builtin runner output split: "always" | "on_failure" | "never"
    output_height = 12,
    open_quickfix = true,  -- open the quickfix list when a task fails with parsed errors
    cmake = {
      build_dir = "build/${buildType}", -- without CMakePresets.json; relative to the project root
      build_type = "Debug",
      build_types = { "Debug", "Release", "RelWithDebInfo", "MinSizeRel" },
      generator = nil,     -- e.g. "Ninja" (only used the first time a build dir is configured)
      configure_args = {},
      build_args = {},
      ctest_args = { "--output-on-failure" },
      link_compile_commands = true, -- symlink <build>/compile_commands.json into the project root
      run_cwd = "exe",     -- cwd for run/debug: "exe" (executable's dir) | "build" | "root"
    },
    cargo = {
      profile = "dev",     -- "dev" | "release" | any custom profile
      build_args = {},
      test_args = {},
    },
    debug = {
      adapter = "gdb",     -- nvim-dap adapter for :Devcontainer debug (registered when missing)
      command = { "gdb", "--interpreter=dap" },
      config = { stopAtBeginningOfMainSubprogram = false }, -- merged into the launch config
    },
  },
  integrations = {
    overseer = {
      -- run every overseer template (make, just, npm, tasks.json, ...) in the container when its
      -- cwd is inside an attached workspace; or a function(task_defn) -> boolean
      wrap_templates = true,
    },
  },
})
```

### Servers that aren't installed on the host

`vim.lsp.enable()` refuses to start a config whose `cmd[1]` isn't executable **on the host**. If
clangd only exists in the container, wrap the command:

```lua
vim.lsp.config("clangd", {
  cmd = require("devcontainer").lsp_cmd({ "clangd", "--background-index", "--clang-tidy" }),
})
vim.lsp.enable("clangd")
```

`lsp_cmd` runs in the container when the buffer's project is attached, and on the host otherwise.

Absolute host paths such as mason's `~/.local/share/nvim/mason/bin/clangd` are looked up by their
basename inside the container. Arguments that contain your workspace path (for example
`--compile-commands-dir=/home/me/proj/build`) are rewritten to the container path.

## Commands

**Container**

| Command | |
|---|---|
| `:Devcontainer up` | start / attach to the workspace's container (asks when there are several configs) |
| `:Devcontainer rebuild` | remove the container and build it again |
| `:Devcontainer stop` | detach, stop the container, move LSP clients back to the host |
| `:Devcontainer shell` | login shell of the remote user in a terminal split |
| `:Devcontainer exec <cmd>` | run a command in the container (in the current file's directory) |
| `:Devcontainer log` | build / lifecycle output |
| `:Devcontainer info` | attached containers, paths, servers running inside, current project |
| `:Devcontainer forget` | forget the "always / never start" answer for this project |

**Project** (CMake or Cargo, detected from the current file)

| Command | CMake | Cargo |
|---|---|---|
| `configure [args]` | `cmake --preset P` or `cmake -S . -B build/<type>` | `cargo fetch` |
| `build [target] [-- args]` | `cmake --build` (configures first when needed) | `cargo build [--bin/-p target]` |
| `run [target] [-- args]` | build + run the executable in a terminal | `cargo run --bin target -- args` |
| `test [args]` | `ctest` (test preset when there is one) | `cargo test` |
| `clean` | `cmake --build --target clean` | `cargo clean` |
| `debug [target] [-- args]` | build + start nvim-dap | build + start nvim-dap |
| `select` | configure preset / build type, run target | profile, run binary |
| `task` | pick any action, including `fresh` (reconfigure) | …including `check`, `clippy`, `fmt`, `doc` |

Targets complete with `<Tab>`: for CMake once the project has been configured, for Cargo after
the first `run` / `debug` / `select` has read `cargo metadata`. The first `run` or `debug` asks which
executable to use and remembers it; `select` changes it.

The workspace is the nearest parent folder that contains `.devcontainer/devcontainer.json`,
`.devcontainer.json` or `.devcontainer/<name>/devcontainer.json`. The project root is the topmost
`CMakeLists.txt` (or the Cargo workspace root) inside that workspace, so a monorepo with several
projects works.

Lua API: `require("devcontainer").build("app")`, `.run()`, `.test()`, `.debug()`, `.task()`,
`.select()`, `.up()`, `.stop()`, `.statusline()`, `.get(path)`.

After every task sequence a `User DevcontainerTaskDone` autocmd fires with
`data = { ok = boolean, name = string }`.

## Building projects

**CMake**

- With `CMakePresets.json` / `CMakeUserPresets.json` (including `include` and `inherits`), the
  first visible configure preset is used until you pick another with `:Devcontainer select`. The
  matching build and test presets are used when they exist.
- Without presets, each build type gets its own directory (`build/Debug`, `build/Release`, ...).
- `CMAKE_EXPORT_COMPILE_COMMANDS=ON` is always passed. After a successful configure,
  `<build>/compile_commands.json` is symlinked into the project root so clangd (running in the
  same container) finds it. An existing regular `compile_commands.json` is never touched.
- Executable targets come from the CMake File API, which is queried automatically.

**Cargo**

- Workspaces are detected from the root `Cargo.toml` with `[workspace]`.
- Binary targets come from `cargo metadata`. Profiles map to `target/debug`, `target/release` or
  `target/<profile>`.

**Errors**

- Compiler output from the container contains container paths. They are rewritten to host paths
  before the quickfix list is built, so `:cnext` opens your files.
- Errors in files that exist only in the container (system headers, `~/.cargo/registry`) point at
  `devcontainer://` buffers.

## Integrations

### overseer.nvim

When overseer is installed (`project.runner = "auto"`), project commands run as overseer tasks.
You get the task list, output view, restart and quickfix handling you already use.

- **`:OverseerRun`** lists the current project's actions as templates: `cmake build`,
  `cmake test`, `cargo clippy`, ...
- **Every other template** (make, just, npm, `.vscode/tasks.json`, your own) also runs in the
  container when its cwd is inside an attached workspace. The `devcontainer` component is added to
  those tasks automatically; turn this off with `integrations.overseer.wrap_templates = false`.
- **Tasks you create yourself** can opt in by adding the component:

  ```lua
  require("overseer").new_task({ cmd = { "make", "-j" }, components = { "devcontainer", "default" } })
  ```

The component rewrites the command to `docker exec` when the task starts, restores it afterwards,
and maps container paths in the task's quickfix list and diagnostics to host files.

### lualine.nvim

```lua
sections = { lualine_x = { "devcontainer" } }   -- container name, or "name (starting)"
```

Any other statusline can call `require("devcontainer").statusline()`.

### rustaceanvim

```lua
vim.g.rustaceanvim = {
  server = {
    -- rustaceanvim calls server.cmd without arguments, hence the wrapper function
    cmd = function() return require("devcontainer").lsp_cmd({ "rust-analyzer" }) end,
  },
  tools = {
    -- :RustLsp runnables / testables and code lenses run in the container
    executor = require("devcontainer.integrations.rustaceanvim").executor,
    test_executor = require("devcontainer.integrations.rustaceanvim").executor,
  },
}
```

For debugging Rust, use `:Devcontainer debug`: rustaceanvim's `debuggables` builds with the host's
cargo.

### Pickers

Every choice (autostart, configs, presets, targets, actions) goes through `vim.ui.select`, so
telescope-ui-select, fzf-lua or snacks.picker show them if you have them set up.

## Debugging (nvim-dap)

`:Devcontainer debug` needs no configuration: it builds the target and starts gdb in the container.
To use lldb-dap instead:

```lua
project = { debug = { adapter = "lldb-dap", command = { "lldb-dap" } } }
```

For your own launch configurations, wrap any **stdio** adapter with `dap_adapter`. It runs in the
container of the project you're debugging, and on the host when there is none.

```lua
local dap = require("dap")
local dc = require("devcontainer")

-- GDB ≥ 14 has a built-in DAP server
dap.adapters.gdb = dc.dap_adapter({ command = "gdb", args = { "--interpreter=dap", "--eval-command", "set print pretty on" } })
-- or LLVM's
dap.adapters["lldb-dap"] = dc.dap_adapter({ command = "lldb-dap" })

dap.configurations.cpp = {
  {
    name = "Launch",
    type = "gdb",
    request = "launch",
    -- host paths are fine: they are translated to container paths
    program = function()
      return vim.fn.input("Executable: ", vim.fn.getcwd() .. "/build/", "file")
    end,
    cwd = "${workspaceFolder}",
    stopAtBeginningOfMainSubprogram = false,
  },
}
dap.configurations.c = dap.configurations.cpp
```

`cpptools` works the same way: `dc.dap_adapter({ command = "OpenDebugAD7", id = "cppdbg" })`, as
long as it's installed in the image.

## How it works

1. `up` runs `devcontainer up` (or `docker build` / `docker run`), then probes the remote user's
   environment the same way VS Code's `userEnvProbe` does and applies `remoteEnv`.
2. `vim.lsp.start` is wrapped.
   - For managed servers inside an attached workspace, `cmd` is replaced by a function that
     starts `docker exec -i -u <remoteUser> -w <folder> -e ... <container> <server>`.
   - It returns an RPC client that translates every message between host and container paths.
   - `initialize.processId` is cleared, because the host PID means nothing in the container.
   - Host and container clients of the same server are never shared.
3. Paths under the workspace map to each other. Any other `file://` URI coming from the container
   becomes `devcontainer://<id>/<path>`. `BufReadCmd`/`BufWriteCmd` handlers read and write those
   files with `docker exec`.
4. For DAP, nvim-dap connects to `127.0.0.1:<random>`. The proxy spawns the adapter with
   `docker exec -i` and rewrites workspace paths in both directions.
5. Project tasks are plain commands (`cmake --build build/Debug`, `cargo test`) run with the project
   root as cwd. The runner (builtin or overseer) wraps them in `docker exec` when the project's
   workspace is attached, and maps paths in their output.

## Limitations

- **codelldb** only speaks TCP, so it isn't supported. Use `gdb --interpreter=dap` or `lldb-dap`.
- In the debugger, stack frames inside container-only files (libstdc++ sources) point to a host
  path. They open only if the same file exists on the host.
- The docker backend doesn't do features, docker compose or UID remapping. Install the
  devcontainer CLI for those.
- Port forwarding: numeric `forwardPorts` are published by the docker backend (`127.0.0.1:N:N`).
  With the CLI, use `appPort` or `runArgs`.
- File watching runs on the host (the workspace is bind-mounted, so this is normally what you want).
  Changes made inside the container outside the workspace aren't watched.
- `postAttachCommand` runs on every `:Devcontainer up`.
- overseer's own template providers that detect tools on the host (for example its cargo template
  runs `cargo metadata` on the host) only appear when the tool is installed on the host. The
  devcontainer templates cover CMake and Cargo without that.
- Build tasks run without a TTY, so compilers print without colours.

## Tests

```sh
NVIM=/path/to/nvim OVERSEER=/path/to/overseer.nvim tests/run.sh
```

- `tests/unit.lua` covers the pure modules: JSONC, path translation, presets, command generation,
  quickfix mapping and autostart decisions.
- `tests/e2e.lua` drives a real clangd through a fake docker CLI that bind-mounts the workspace at
  another path in a private mount namespace. It also uses a fake DAP adapter and a fake
  devcontainer CLI.
- `tests/e2e_project.lua` builds, runs, tests and debugs a real CMake/Ninja project and a Cargo
  workspace "in the container", with the builtin runner and with overseer.nvim.

The e2e suites need root (for mount namespaces), python3 and clangd. The project suite also needs
cmake, ninja, a C++ compiler and cargo.
