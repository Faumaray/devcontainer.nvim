--- neotest strategy "devcontainer" (from devcontainer.nvim): `default_strategy = "devcontainer"`
--- or `require("neotest").run.run({ strategy = "devcontainer" })`.
return function(spec, context)
  return require("devcontainer.integrations.neotest").strategy(spec, context)
end
