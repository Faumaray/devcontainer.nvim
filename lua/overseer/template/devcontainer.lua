--- overseer.nvim template provider from devcontainer.nvim.
---
--- * Lists the CMake / Cargo actions of the current project (configure, build, test, clean, ...)
---   as templates for :OverseerRun. They run in the devcontainer when one is attached.
--- * Adds the `devcontainer` component to tasks built from every other template (make, just,
---   npm, tasks.json, ...), so they run in the container too (integrations.overseer.wrap_templates).
local overseer = require("overseer")

local hooked = false
local function hook_all_templates()
  if hooked then return end
  hooked = true
  overseer.add_template_hook(nil, function(task_defn, util)
    local wrap = require("devcontainer.config").options.integrations.overseer.wrap_templates
    if type(wrap) == "function" then wrap = wrap(task_defn) end
    if wrap and not util.has_component(task_defn, "devcontainer") then
      util.add_component(task_defn, "devcontainer")
    end
  end)
end

local TAGS = {
  build = overseer.TAG.BUILD,
  test = overseer.TAG.TEST,
  clean = overseer.TAG.CLEAN,
}

---@type overseer.TemplateFileProvider
return {
  generator = function(search, cb)
    hook_all_templates()
    local project = require("devcontainer.project")
    local ok, ctx = pcall(project.detect, search.dir)
    if not ok or not ctx then
      return cb(ok and "No CMake or Cargo project" or tostring(ctx))
    end
    local runner = require("devcontainer.runner")
    local tmpls = {}
    for _, action in ipairs(ctx.provider.actions) do
      if not action.interactive then
        table.insert(tmpls, {
          name = ("%s %s"):format(ctx.provider.name, action.name),
          desc = action.desc,
          tags = { TAGS[action.name] },
          builder = function()
            -- templates are single commands: no implicit configure step
            local steps = action.run(ctx, { extra = {}, template = true })
            local spec = steps and steps[#steps]
            if type(spec) ~= "table" then error(("%s %s: not available as a template"):format(ctx.provider.name, action.name)) end
            return runner.task_definition(spec)
          end,
        })
      end
    end
    cb(tmpls)
  end,
}
