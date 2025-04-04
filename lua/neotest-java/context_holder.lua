local log = require("neotest-java.logger")
local compatible_path = require("neotest-java.util.compatible_path")

local DEFAULT_VERSION = "1.10.1"

---@type neotest-java.ConfigOpts
local default_config = {
	junit_jar = compatible_path(
		("%s/neotest-java/junit-platform-console-standalone-%s.jar"):format(vim.fn.stdpath("data"), DEFAULT_VERSION)
	),
	default_version = DEFAULT_VERSION,
	incremental_build = true,
	build_target = "project",
	java_runtimes = {},
}

---@type neotest-java.Context
local context = { root = nil, config = default_config }

---@class neotest-java.ContextHolder
return {
	--
	get_context = function()
		return context
	end,
	config = function()
		return context.config
	end,
	set_opts = function(opts)
		context.config = vim.tbl_extend("force", context.config, opts)
		log.debug("Config updated: ", context.config)
	end,
	set_root = function(root)
		context.root = root
	end,
}

---@class neotest-java.ConfigOpts
---@field junit_jar string
---@field build_target string
---@field incremental_build boolean
---@field default_version string
---@field java_runtimes table<string,string>
---@class neotest-java.Context
---@field config neotest-java.ConfigOpts
---@field root string|nil
