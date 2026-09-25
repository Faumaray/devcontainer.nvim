--- overseer.nvim component from devcontainer.nvim: runs the task's command inside the attached
--- devcontainer (via `docker exec`) when the task's cwd is in an attached workspace, and maps
--- container paths in the quickfix list / diagnostics back to host files.
---@type overseer.ComponentFileDefinition
return {
  desc = "Run the task inside the attached devcontainer (devcontainer.nvim)",
  params = {
    cwd = {
      desc = "Working directory inside the container (default: the task cwd mapped into the container)",
      type = "string",
      optional = true,
    },
    session = {
      desc = "Container key; false to always run on the host (default: detect from the task cwd)",
      type = "opaque",
      optional = true,
    },
  },
  constructor = function(params)
    local registry = require("devcontainer.session")
    local runner = require("devcontainer.runner")

    local function session_for(task)
      if params.session == false then return nil end
      return (params.session and registry.by_key[params.session]) or registry.find(task.cwd)
    end

    return {
      on_init = function(self, task)
        self.orig = { cmd = task.cmd, env = task.env }
      end,
      on_pre_start = function(self, task)
        task.cmd, task.env = self.orig.cmd, self.orig.env
        self.session = session_for(task)
        local s = self.session
        if not s then return end
        local cmd = task.cmd
        if type(cmd) == "string" then cmd = { "/bin/sh", "-c", cmd } end
        task.cmd = s:exec_argv(cmd, {
          stdin = true,
          cwd = params.cwd or s:remote_path(task.cwd) or s.remote_folder,
          env = task.env,
        })
        task.env = nil
      end,
      on_exit = function(self, task)
        -- keep the task definition container-agnostic (restart, serialization)
        task.cmd, task.env = self.orig.cmd, self.orig.env
      end,
      on_preprocess_result = function(self, _, result)
        if self.session and type(result.diagnostics) == "table" then
          runner.fix_items(result.diagnostics, self.session)
        end
      end,
      on_complete = function(self, task, status)
        if self.session and status == "FAILURE" then
          local ok, buf = pcall(task.get_bufnr, task)
          if ok and buf and vim.api.nvim_buf_is_valid(buf) then
            runner.ssh_hint(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
          end
        end
        if self.session then
          local last = vim.fn.getqflist({ nr = "$" }).nr
          for nr = 1, last do
            local l = vim.fn.getqflist({ nr = nr, context = 0, id = 0, items = 0 })
            if l.context == task.id and runner.fix_items(l.items, self.session) then
              vim.fn.setqflist({}, "r", { id = l.id, items = l.items })
            end
          end
        end
        local after = task.metadata and task.metadata.devcontainer_after
        if status == "SUCCESS" and after then
          pcall(require("devcontainer.project").after, after)
        end
      end,
    }
  end,
}
