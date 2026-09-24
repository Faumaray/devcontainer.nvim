--- lualine component: `lualine_x = { "devcontainer" }`
--- Shows the name of the devcontainer the current buffer runs in ("name (starting)" while it starts).
local component = require("lualine.component"):extend()

function component:init(options)
  options.icon = options.icon or ""
  component.super.init(self, options)
end

function component:update_status()
  return require("devcontainer").statusline()
end

return component
