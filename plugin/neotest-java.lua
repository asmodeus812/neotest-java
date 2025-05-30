local exists = require("neotest.lib.file").exists
local job = require("plenary.job")
local logger = require("neotest.logging")
local lib = require("neotest.lib")
local ch = require("neotest-java.context_holder")
local junit_version = ch.config().default_version

local options = {
	setup = function()
		local filepath = ("%s/neotest-java/junit-platform-console-standalone-%s.jar"):format(
			vim.fn.stdpath("data"),
			junit_version
		)
		if exists(filepath) then
			lib.notify("Already setup!")
			return
		end

		-- Download Junit Standalone Jar
		local stderr = {}
		job
			:new({
				command = "curl",
				args = {
					"--output",
					filepath,
					("https://repo1.maven.org/maven2/org/junit/platform/junit-platform-console-standalone/%s/junit-platform-console-standalone-%s.jar"):format(
						junit_version,
						junit_version
					),
					"--create-dirs",
				},
				on_stderr = function(_, data)
					table.insert(stderr, data)
				end,
				on_exit = function(_, code)
					if code == 0 then
						lib.notify("Downloaded Junit Standalone successfully!")
					else
						local output = table.concat(stderr, "\n")
						lib.notify(string.format("Error while downloading: \n %s", output), "error")
						logger.error(output)
					end
				end,
			})
			:start()
	end,
}

vim.api.nvim_create_user_command("NeotestJava", function(info)
	local fun = options[info.args] or error("Invalid option")
	fun()
end, {
	desc = "Setup neotest-java",
	nargs = 1,
	complete = function()
		-- keys from options
		return vim.tbl_keys(options)
	end,
})
