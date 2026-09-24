--- rustaceanvim executor that runs runnables / testables (`:RustLsp runnables`, code lenses)
--- in the devcontainer, through the same runner as :Devcontainer build/test.
---
---   vim.g.rustaceanvim = {
---     tools = {
---       executor = require("devcontainer.integrations.rustaceanvim").executor,
---       test_executor = require("devcontainer.integrations.rustaceanvim").executor,
---     },
---     server = { cmd = function() return require("devcontainer").lsp_cmd({ "rust-analyzer" }) end },
---   }
local M = {}

---@type rustaceanvim.Executor
M.executor = {
  execute_command = function(command, args, cwd, opts)
    local runner = require("devcontainer.runner")
    local sub = args[1]
    local interactive = not (sub == "test" or sub == "build" or sub == "check" or sub == "bench")
    runner.run({
      {
        name = table.concat(vim.list_extend({ command }, args), " "),
        cmd = vim.list_extend({ command }, args),
        cwd = cwd or vim.fn.getcwd(),
        env = opts and opts.env,
        efm = runner.efm("cargo"),
        interactive = interactive,
      },
    })
  end,
}

return M
