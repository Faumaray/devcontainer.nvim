# devcontainer.nvim

VS Code–style devcontainers for Neovim: **Neovim runs on your host; language servers, debug
adapters, formatters, linters, tests and builds run inside the container.** Your editor, config,
keymaps and plugins stay local. The toolchain (clangd, rust-analyzer, gdb, CMake, cargo, SDKs,
system headers) lives in the container described by the project's `.devcontainer/devcontainer.json`.

```
 host                                   container
 ┌──────────────────────┐   docker exec -i   ┌────────────────────────────┐
 │ nvim                 │ ─────────────────▶ │ clangd / gdb / cmake / ... │
 │ /home/me/proj/a.cpp  │ ◀── translated ─── │ /workspaces/proj/a.cpp     │
 └──────────────────────┘      paths         └────────────────────────────┘
```

Full documentation: `:help devcontainer`.

## Features

- **Start the container when you open a project.** When you open a file (or `cd`) inside a project
  with a devcontainer config, you're asked whether to start it. "Always" and "Never" answers are
  remembered per project. `:Devcontainer init` adds a config from the official templates.
- **`:Devcontainer up`** builds and starts the container, with live progress (fidget.nvim,
  snacks.nvim or the command line).
  - With [`@devcontainers/cli`](https://github.com/devcontainers/cli) installed you get the full
    spec: features, docker compose, UID remapping and lifecycle hooks.
  - Without it, a built-in docker/podman backend handles `image` and `build` configs.
  - Containers created by VS Code or the CLI are reused, because the same labels are used.
  - Saving `devcontainer.json` (or its Dockerfile) offers a rebuild; so does `up` when the
    container is older than its configuration.
- **LSP inside the container.** Any server started through `vim.lsp.enable()`, nvim-lspconfig,
  rustaceanvim or `vim.lsp.start()` is transparently spawned with `docker exec` when its root is in
  an attached workspace.
  - Clients that were already running on the host are moved into the container on `up`, and moved
    back on `stop`. Servers installed only in the container start for the files that were already
    open.
  - URIs are translated in both directions: diagnostics, definitions, workspace edits, file
    watchers, and markdown links in hover docs.
- **Files that exist only in the container** (`/usr/include/c++/13/vector`, SDKs, toolchains) open
  as `devcontainer://<id>/...` buffers. "Go to definition" into the standard library works like in
  VS Code. `:Devcontainer files` finds them with your picker.
- **Build, run, test and debug CMake and Cargo projects** with `:Devcontainer configure / build /
  run / test / clean / debug`. They run in the container when one is attached and on the host
  otherwise. Compiler errors land in the quickfix list, pointing at host files.
- **Profiles**: named option sets, applied per folder or selected with `:Devcontainer profile`,
  e.g. an `asan` profile with its own build dir and CMake flags. Teams can ship them in
  `devcontainer.json`.
- **Port forwarding** like VS Code: `forwardPorts` (also with the CLI backend) and
  `:Devcontainer forward`, including servers bound to the container's localhost and compose
  services (`db:5432`).
- **Debugging inside the container** with [nvim-dap](https://github.com/mfussenegger/nvim-dap):
  stdio adapters (`gdb -i dap`, `lldb-dap`, `OpenDebugAD7`) and TCP adapters (codelldb, delve) run
  behind a local proxy that translates paths. `runInTerminal` becomes `docker exec -it`.
- **Git in the container**: your SSH agent (also in builds), known hosts, `~/.gitconfig` and your
  dotfiles repository.
- **Integrations:** [overseer.nvim](https://github.com/stevearc/overseer.nvim),
  [neotest](https://github.com/nvim-neotest/neotest),
  [conform.nvim](https://github.com/stevearc/conform.nvim),
  [nvim-lint](https://github.com/mfussenegger/nvim-lint),
  [rustaceanvim](https://github.com/mrcjkb/rustaceanvim),
  [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim),
  [snacks.nvim](https://github.com/folke/snacks.nvim) (picker, terminal, notifier),
  [telescope](https://github.com/nvim-telescope/telescope.nvim),
  [fzf-lua](https://github.com/ibhagwan/fzf-lua),
  [toggleterm](https://github.com/akinsho/toggleterm.nvim),
  [fidget.nvim](https://github.com/j-hui/fidget.nvim), and a `wrap_cmd()` API for anything else.
- **Container user environment.** `remoteUser`, `remoteEnv` and `userEnvProbe` are honoured, so a
  `PATH` from nvm, sdkman, rustup, `/opt/toolchain/bin`, etc. is picked up.
- **Other commands.** `:Devcontainer shell` / `exec <cmd>` open terminals in the container.
  `:Devcontainer log` shows build output. `:checkhealth devcontainer` checks your setup.

## Requirements

- Neovim ≥ 0.11
- docker or podman on the host (your user must be able to talk to the daemon)
- *optional:* `npm install -g @devcontainers/cli` (recommended; needed for features and compose)
- *optional:* any of the plugins listed under [Integrations](#integrations)
- The language servers, debuggers, formatters, linters and build tools must be installed **in the
  container image**, not on the host.

## Installation

lazy.nvim:

```lua
{
  "faumaray/devcontainer.nvim",
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
  stop_on_exit = false,    -- stop attached containers when Neovim exits (compose projects as a
                           -- whole; "shutdownAction": "none" in devcontainer.json keeps them)
  watch_config = true,     -- offer a rebuild when devcontainer.json / Dockerfile / compose files change
  user_env_probe = nil,    -- override devcontainer.json userEnvProbe:
                           -- "none" | "loginShell" | "interactiveShell" | "loginInteractiveShell"
  remote_fs = true,        -- open container-only files as devcontainer:// buffers
  devcontainer = nil,      -- config to use when there are several (.devcontainer/<name>/): nil = ask
  profiles = {},           -- see "Profiles"
  customizations = true,   -- read customizations["devcontainer.nvim"] from a trusted devcontainer.json
  git = {
    ssh_agent = true,      -- make the host's SSH agent available in new containers
    gitconfig = true,      -- copy ~/.gitconfig into containers that have none (or a path)
    known_hosts = true,    -- add ~/.ssh/known_hosts entries to the container user's (or a path)
  },
  dotfiles = {
    repository = nil,      -- "owner/repo" or a git URL, installed in new containers
    target_path = "~/dotfiles",
    install_command = nil, -- default: install.sh, install, bootstrap.sh, bootstrap, setup.sh, setup
  },
  progress = "auto",       -- :Devcontainer up progress: "auto" | "fidget" | "snacks" | "echo" | false
  picker = "auto",         -- :Devcontainer files: "auto" | "snacks" | "telescope" | "fzf-lua" | "select"
  files = {
    roots = { "/usr/include", "/usr/local/include", "/opt", "~/.cargo/registry/src", ... },
  },
  terminal = {
    provider = "builtin",  -- shell/exec/run terminals: "builtin" | "snacks" | "toggleterm" | function
  },
  ports = {
    forward = true,        -- forward devcontainer.json forwardPorts when attaching
    bind_address = "127.0.0.1",
    relay = nil,           -- fun(host, port, session) -> argv; default: socat, bash, python3 or nc
  },
  lsp = {
    enabled = true,
    servers = "*",         -- "*" or a list of server names to run in the container
    exclude = {},          -- servers that always stay on the host, e.g. { "copilot" }
    remote_cmd = {},       -- per-server command in the container:
                           --   { clangd = { "clangd-18", "--background-index", "--clang-tidy" } }
                           -- or a function(host_cmd, session) -> argv
    fallback = "local",    -- server missing in the container: "local" (run on host, warn) | "none"
    follow_build_dir = true, -- --compile-commands-dir / compilationDatabasePath follow the active
                           -- build dir (build/Debug, a profile's dir, ...); false keeps them as written
  },
  project = {
    runner = "auto",       -- "auto" (overseer.nvim when installed) | "overseer" | "builtin"
    open_output = "always",-- builtin runner output split: "always" | "on_failure" | "never"
    output_height = 12,
    open_quickfix = true,  -- open the quickfix list when a task fails with parsed errors
    env = {},              -- environment of every project task
    run_args = {},         -- default program arguments of run / debug
    cmake = {
      preset = nil,        -- configure preset (default: the one picked with :Devcontainer select)
      build_dir = "build/${buildType}", -- without CMakePresets.json; also ${presetName}, ${profile}
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
      features = {},
      no_default_features = false,
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

A server installed only in the container needs nothing special:

```lua
vim.lsp.config("clangd", { cmd = { "clangd", "--background-index", "--clang-tidy" } })
vim.lsp.enable("clangd")
```

`vim.lsp.enable()` refuses to start a config whose `cmd[1]` isn't executable on the host. So once
a container is attached, enabled configs like that are started in it, also for the files that were
already open before `:Devcontainer up`. Without a container they don't start (and don't error).

Plugins that start servers themselves (rustaceanvim) need the command wrapped, so it can run in the
container when the buffer's project is attached, and on the host otherwise:

```lua
cmd = require("devcontainer").lsp_cmd({ "clangd", "--background-index" })
```

Absolute host paths such as mason's `~/.local/share/nvim/mason/bin/clangd` are looked up by their
basename inside the container. Arguments that contain your workspace path (for example
`--query-driver=/home/me/proj/tools/*`) are rewritten to the container path, and
`--compile-commands-dir` follows the project's active build dir (see [Building projects](#building-projects)).

## Commands

**Container**

| Command | |
|---|---|
| `:Devcontainer up` | start / attach to the workspace's container (asks when there are several configs) |
| `:Devcontainer rebuild [--no-cache]` | remove the container and build it again |
| `:Devcontainer stop` | detach, stop the container (the whole compose project), move LSP clients back |
| `:Devcontainer down` | remove the container (`docker compose down` for compose configs), after asking |
| `:Devcontainer init` | add a devcontainer config to the project from a template |
| `:Devcontainer config` | open devcontainer.json |
| `:Devcontainer shell` | login shell of the remote user in a terminal |
| `:Devcontainer exec <cmd>` | run a command in the container (in the current file's directory) |
| `:Devcontainer files [dir]` | find and open container-only files (headers, SDKs, packages) |
| `:Devcontainer ports` | forwarded ports: open in the browser, copy the address, stop |
| `:Devcontainer forward <port\|host:port> [local]` | forward a port |
| `:Devcontainer unforward <port>` | stop forwarding a port |
| `:Devcontainer profile [name\|none]` | select the profile of this workspace |
| `:Devcontainer log` | build / lifecycle output |
| `:Devcontainer info` | attached containers, paths, servers, ports, profile, current project |
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
| `select` | configure preset / build type, run target | cargo profile, run binary |
| `task` | pick any action, including `fresh` (reconfigure) | …including `check`, `clippy`, `fmt`, `doc` |

Targets complete with `<Tab>`: for CMake once the project has been configured, for Cargo after
the first `run` / `debug` / `select` has read `cargo metadata`. The first `run` or `debug` asks which
executable to use and remembers it; `select` changes it.

The workspace is the nearest parent folder that contains `.devcontainer/devcontainer.json`,
`.devcontainer.json` or `.devcontainer/<name>/devcontainer.json`. The project root is the topmost
`CMakeLists.txt` (or the Cargo workspace root) inside that workspace, so a monorepo with several
projects works.

## Profiles

A profile is a named set of option overrides. It applies automatically in the folders its `match`
fits, or when you select it for the workspace with `:Devcontainer profile` (remembered per
workspace). Precedence, lowest first: your `setup()` options, the matching profiles, the
`devcontainer.json` settings, the selected profile. Lists named `*_args` are appended, everything
else replaces what's below it.

```lua
require("devcontainer").setup({
  profiles = {
    asan = {
      desc = "AddressSanitizer build",
      project = {
        cmake = {
          build_dir = "build/${profile}-${buildType}",   -- its own build dir
          configure_args = { "-DCMAKE_CXX_FLAGS=-fsanitize=address" },
        },
        env = { ASAN_OPTIONS = "detect_leaks=1" },
      },
    },
    release = { project = { cmake = { build_type = "Release" }, cargo = { profile = "release" } } },
    work = {
      match = { "~/work/**" },               -- glob, folder, function(root) or a list of those
      extends = "asan",
      devcontainer = "gpu",                  -- use .devcontainer/gpu/devcontainer.json
      lsp = { remote_cmd = { clangd = { "clangd-18", "--background-index" } } },
    },
  },
})
```

- `:Devcontainer profile asan` selects one, `:Devcontainer profile none` none, `:Devcontainer
  profile` picks from a list (matched ones are marked).
- CMake reconfigures when the configure settings of a build dir change, so switching profiles is
  enough. LSP clients restart when the profile changes `lsp` options.
- The statusline shows the selected profile: `proj [asan]`.
- From a project's `.nvim.lua` (`:help 'exrc'`): `require("devcontainer").add_profiles({ ... })`.
- A team can put settings and profiles in `devcontainer.json`. They're used once you trust the file
  (`:help vim.secure.read`), and can't change which programs run on the host (no `docker`, `cli`,
  debug adapter commands, dotfiles):

  ```jsonc
  "customizations": {
    "devcontainer.nvim": {
      "settings": { "project": { "cmake": { "generator": "Ninja" } } },
      "profiles": { "ci": { "desc": "like CI", "project": { "cmake": { "configure_args": ["-DWERROR=ON"] } } } },
      "profile": "ci"
    }
  }
  ```

## Port forwarding

`forwardPorts` from devcontainer.json are forwarded when the container attaches, with either
backend. Each connection to `localhost:<port>` on the host is relayed into the container through
`docker exec` (socat, bash, python3 or nc, whichever the image has). That's how VS Code does it,
so servers that only listen on the container's `localhost` work, and so do compose services
(`"forwardPorts": ["db:5432"]`).

- `portsAttributes` are honoured: `label`, `onAutoForward` (`notify`, `silent`, `ignore`,
  `openBrowser`, `openBrowserOnce`), `requireLocalPort` and `protocol`. When the local port is
  busy, another one is used and shown.
- `:Devcontainer forward 8080`, `:Devcontainer forward db:5432 15432`, `:Devcontainer unforward
  8080`, `:Devcontainer ports`.
- Ports the container publishes itself (`appPort`, `-p` in `runArgs`) are listed, not tunnelled.

## Building projects

**CMake**

- With `CMakePresets.json` / `CMakeUserPresets.json` (including `include` and `inherits`), the
  first visible configure preset is used until you pick another with `:Devcontainer select` (or a
  profile sets `cmake.preset`). The matching build and test presets are used when they exist.
- Without presets, each build type gets its own directory (`build/Debug`, `build/Release`, ...).
- `CMAKE_EXPORT_COMPILE_COMMANDS=ON` is always passed. After a successful configure,
  `<build>/compile_commands.json` is symlinked into the project root so clangd (running in the
  same container) finds it. An existing regular `compile_commands.json` is never touched.
- A server that is told where the database is, like clangd with `--compile-commands-dir=build`
  (or `init_options.compilationDatabasePath`), gets the active build dir instead: `build/Debug`,
  the selected profile's or preset's dir. It restarts when that dir changes (profile, preset or
  build type switch) or after its first configure. Dirs outside the project are left alone;
  `lsp.follow_build_dir = false` turns this off.
- Executable targets come from the CMake File API, which is queried automatically.

**Cargo**

- Workspaces are detected from the root `Cargo.toml` with `[workspace]`.
- Binary targets come from `cargo metadata`. Profiles map to `target/debug`, `target/release` or
  `target/<profile>`; custom `[profile.*]` sections are offered by `:Devcontainer select`.

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

### neotest

```lua
require("neotest").setup({ adapters = { ... }, default_strategy = "devcontainer" })
-- or per run: require("neotest").run.run({ strategy = "devcontainer" })
```

The adapter's test command runs in the container. Result files the adapter passes (under Neovim's
tempdir) live in the container and are copied back with container paths mapped, and helper
scripts that only exist on the host (neotest-python's `neotest.py`, ...) are copied in first.
`strategy = "dap"` works too, through the DAP proxy.

### conform.nvim and nvim-lint

```lua
require("conform").setup({ formatters_by_ft = { cpp = { "clang_format" }, python = { "ruff_format" } } })
require("devcontainer.integrations.conform").setup()        -- after conform.setup()

require("lint").linters_by_ft = { python = { "ruff", "mypy" } }
require("devcontainer.integrations.lint").setup()           -- after linters_by_ft
```

Formatters and linters then run inside the buffer's container (and on the host elsewhere, or when
the tool isn't in the image). `setup({ formatters = { "clang_format" }, exclude = { ... } })`
limits which ones; `.wrap(name)` wraps a single one. Container paths in linter output are mapped
back before nvim-lint's parser sees them.

### Terminals

`terminal.provider = "snacks"` or `"toggleterm"` opens `:Devcontainer shell` / `exec` and `run`
tasks in those plugins. For your own terminals and jobs:

```lua
Snacks.terminal(require("devcontainer").shell_cmd())            -- login shell in the container
local argv = require("devcontainer").wrap_cmd({ "make", "-j8" }) -- docker exec ... (host argv without one)
```

### Pickers and progress

- `:Devcontainer files` uses snacks.picker, telescope or fzf-lua when installed, with previews
  (`picker = ...` to choose); every other choice goes through `vim.ui.select`, so
  telescope-ui-select, fzf-lua or snacks show them if you have them set up.
- `:Devcontainer up` reports progress (build steps with percentages, lifecycle hooks) through
  fidget.nvim, snacks.nvim's notifier, or the command line (`progress = ...`).

### Statuslines

```lua
sections = { lualine_x = { "devcontainer" } }   -- "name", "name [profile]", "name (starting)"
```

Any other statusline can call `require("devcontainer").statusline()`; it's cheap, and the
`DevcontainerAttached` / `Detached` / `ProfileChanged` events redraw it. heirline:
`{ provider = function() return require("devcontainer").statusline() end }`.

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

### Session managers

`devcontainer://` buffers restored by auto-session, persistence.nvim or `:mksession` before the
container runs are read again once it attaches.

## Debugging (nvim-dap)

`:Devcontainer debug` needs no configuration: it builds the target and starts gdb in the container.
To use lldb-dap instead:

```lua
project = { debug = { adapter = "lldb-dap", command = { "lldb-dap" } } }
```

For your own launch configurations, wrap the adapter with `dap_adapter`. It runs in the container
of the project you're debugging, and on the host when there is none.

```lua
local dap = require("dap")
local dc = require("devcontainer")

-- stdio adapters: GDB ≥ 14 has a built-in DAP server, or LLVM's lldb-dap
dap.adapters.gdb = dc.dap_adapter({ command = "gdb", args = { "--interpreter=dap", "--eval-command", "set print pretty on" } })
dap.adapters["lldb-dap"] = dc.dap_adapter({ command = "lldb-dap" })

-- TCP adapters: started in the container, reached through a relay
dap.adapters.codelldb = dc.dap_adapter({
  type = "server", port = "${port}",
  executable = { command = "codelldb", args = { "--port", "${port}" } },
})
dap.adapters.go = dc.dap_adapter({
  type = "server", port = "${port}",
  executable = { command = "dlv", args = { "dap", "-l", "127.0.0.1:${port}" } },
})

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

## Git, SSH and dotfiles

- **SSH agent** (`git.ssh_agent`): new containers get `SSH_AUTH_SOCK` pointing at your agent, in
  shells, builds (FetchContent over SSH), language servers and the lifecycle commands the
  devcontainer CLI runs. On Linux a folder in Neovim's state dir is mounted and Neovim relays a
  socket in it to its `$SSH_AUTH_SOCK` (the container still starts after you log in again; the
  agent is there while Neovim runs). All Neovims share that socket: the first one serves it, and
  another takes over when it exits, so start Neovim where `$SSH_AUTH_SOCK` has your keys. The
  container user needs your uid, which the devcontainer CLI arranges. On macOS, Docker Desktop's
  `/run/host-services/ssh-auth.sock` is used. Existing containers need a rebuild.
- **known_hosts** (`git.known_hosts`): hosts from your `~/.ssh/known_hosts` are added to the
  container user's, since a build can't answer ssh's "continue connecting?".
- **gitconfig** (`git.gitconfig`): `~/.gitconfig` is copied into containers that have none.
- **When git over SSH fails** in a build, `:checkhealth devcontainer` shows what tasks in the
  container see: which Neovim relays the agent, whether it's reachable, how many keys it has, and
  whether there's a known_hosts.
- **Dotfiles** (`dotfiles.repository`): cloned into new containers and installed like the
  devcontainer CLI does (install command, or the first `install.sh`, `install`, `bootstrap.sh`,
  `bootstrap`, `setup.sh` or `setup`, else the dotfiles are linked into `$HOME`).

## Events and Lua API

`User` autocmds, with `data`:

| Event | data |
|---|---|
| `DevcontainerStarting` | `{ local_folder }` |
| `DevcontainerAttached` / `DevcontainerDetached` | `{ name, key, container_id, local_folder, remote_folder }` |
| `DevcontainerProfileChanged` | `{ scope, profile }` |
| `DevcontainerTaskDone` | `{ ok, name }` after every task sequence |

`require("devcontainer")`: `.up()`, `.rebuild()`, `.stop()`, `.down()`, `.build("app")`, `.run()`,
`.test()`, `.debug()`, `.task()`, `.select()`, `.profile(name)`, `.options(path)`,
`.add_profiles(tbl)`, `.wrap_cmd(argv, opts)`, `.shell_cmd()`, `.lsp_cmd(argv)`,
`.dap_adapter(spec)`, `.forward("3000")`, `.files(dir)`, `.statusline()`, `.get(path)`.

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
   `docker exec -i` (or, for TCP adapters, a relay to the adapter's port in the container) and
   rewrites workspace paths in both directions.
5. Project tasks are plain commands (`cmake --build build/Debug`, `cargo test`) run with the project
   root as cwd. The runner (builtin or overseer) wraps them in `docker exec` when the project's
   workspace is attached, and maps paths in their output.
6. Forwarded ports are TCP listeners in Neovim; every connection gets its own `docker exec -i`
   relay into the container.

## Limitations

- In the debugger, stack frames inside container-only files (libstdc++ sources) point to a host
  path. They open only if the same file exists on the host.
- The docker backend doesn't do features, docker compose or UID remapping. Install the
  devcontainer CLI for those.
- Ports are forwarded when they're listed (`forwardPorts`, `:Devcontainer forward`); ports a
  process opens later are not detected automatically. Each connection starts a `docker exec`, which
  adds a little latency to the first byte.
- File watching runs on the host (the workspace is bind-mounted, so this is normally what you want).
  Changes made inside the container outside the workspace aren't watched.
- `postAttachCommand` runs on every `:Devcontainer up`.
- overseer's own template providers that detect tools on the host (for example its cargo template
  runs `cargo metadata` on the host) only appear when the tool is installed on the host. The
  devcontainer templates cover CMake and Cargo without that.
- Build tasks run without a TTY, so compilers print without colours.
- neotest adapters that stream results while running (neotest-python's stream file) report them
  when the run ends.

## Tests

```sh
NVIM=/path/to/nvim PLUGINS=/path/with/plugins tests/run.sh
```

- `tests/unit.lua` covers the pure modules: JSONC, path translation, presets, command generation,
  quickfix mapping, profiles, ports, integrations (against stub plugins) and autostart decisions.
- `tests/e2e.lua` drives a real clangd through a fake docker CLI that bind-mounts the workspace at
  another path in a private mount namespace. It also covers the DAP proxy (stdio and TCP adapters),
  port forwarding, lifecycle events and prompts, git/dotfiles, and the fake devcontainer CLI.
- `tests/e2e_lsp_start.lua` opens a file before the container starts, with servers that exist only
  in the container (plain `cmd` and `lsp_cmd`), and checks they start there once it attaches.
- `tests/e2e_project.lua` builds, runs, tests and debugs a real CMake/Ninja project and a Cargo
  workspace "in the container", with the builtin runner and with overseer.nvim, and profiles.
- `tests/e2e_integrations.lua` runs conform.nvim, nvim-lint, neotest, snacks.nvim, telescope,
  toggleterm and fidget.nvim against it. `$PLUGINS` is a folder with those plugins (plus
  overseer.nvim, nvim-nio and plenary.nvim); missing ones are skipped.

The e2e suites need root (for mount namespaces), python3, git, clangd and ssh-agent. The project
suite also needs cmake, ninja, a C++ compiler and cargo.

## License

MIT
