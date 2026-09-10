local assertions = require("tests.assertions")
local eq = assertions.eq

local ProjectCompiler = require("neotest-java-custom.compiler.project_compiler")
local Path = require("neotest-java.model.path")

describe("Project compiler", function()
	it("builds only the jdtls projects rooted under base_dir", function()
		local calls = {}
		local fake_client = { initialized = true }
		fake_client.request = function(_, method, params, callback)
			table.insert(calls, { method = method, params = params })
			if method == "workspace/executeCommand" and params.command == "java.project.getAll" then
				callback(nil, { "file:///repo/moduleA", "file:///other/moduleB" })
			elseif method == "java/buildProjects" then
				callback(nil, {})
			end
		end

		local compiler = ProjectCompiler({
			client_provider = function(cwd)
				eq(Path("/repo"), cwd)
				return fake_client
			end,
		})

		compiler.compile({ base_dir = Path("/repo"), compile_mode = "full" })

		eq(2, #calls)
		eq("workspace/executeCommand", calls[1].method)
		eq("java/buildProjects", calls[2].method)
		eq(1, #calls[2].params.identifiers)
		eq("file:///repo/moduleA", calls[2].params.identifiers[1].uri)
		eq(true, calls[2].params.isFullBuild)
	end)

	it("falls back to a full workspace build when no project matches base_dir", function()
		local calls = {}
		local fake_client = { initialized = true }
		fake_client.request = function(_, method, params, callback)
			table.insert(calls, { method = method, params = params })
			if method == "workspace/executeCommand" then
				callback(nil, { "file:///unrelated/moduleC" })
			elseif method == "java/buildWorkspace" then
				callback(nil, {})
			end
		end

		local compiler = ProjectCompiler({
			client_provider = function()
				return fake_client
			end,
		})

		compiler.compile({ base_dir = Path("/repo"), compile_mode = "incremental" })

		eq(2, #calls)
		eq("java/buildWorkspace", calls[2].method)
		eq(false, calls[2].params.forceRebuild)
	end)

	it("falls back to a full workspace build when getAll errors", function()
		local calls = {}
		local fake_client = { initialized = true }
		fake_client.request = function(_, method, params, callback)
			table.insert(calls, { method = method, params = params })
			if method == "workspace/executeCommand" then
				callback({ message = "no active projects" }, nil)
			elseif method == "java/buildWorkspace" then
				callback(nil, {})
			end
		end

		local compiler = ProjectCompiler({
			client_provider = function()
				return fake_client
			end,
		})

		compiler.compile({ base_dir = Path("/repo"), compile_mode = "full" })

		eq(2, #calls)
		eq("java/buildWorkspace", calls[2].method)
	end)

	it("does nothing when the client isn't initialized", function()
		local requested = false
		local compiler = ProjectCompiler({
			client_provider = function()
				return { initialized = false }
			end,
		})

		compiler.compile({ base_dir = Path("/repo"), compile_mode = "full" })
		vim.wait(20)

		eq(false, requested)
	end)
end)
