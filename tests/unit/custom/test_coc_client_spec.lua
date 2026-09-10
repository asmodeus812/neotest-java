local assertions = require("tests.assertions")
local eq = assertions.eq

describe("neotest-java-custom coc client provider", function()
	local original_cocaction
	local original_cocrequest
	local original_coc_get_config

	before_each(function()
		original_cocaction = vim.fn.CocAction
		original_cocrequest = vim.fn.CocRequest
		original_coc_get_config = vim.fn["coc#util#get_config"]
	end)

	after_each(function()
		vim.fn.CocAction = original_cocaction
		vim.fn.CocRequest = original_cocrequest
		vim.fn["coc#util#get_config"] = original_coc_get_config
		package.loaded["neotest-java-custom.client.coc_client"] = nil
	end)

	it("builds a vim.lsp.Client-shaped proxy backed by coc.nvim's RPC", function()
		vim.fn.CocAction = function(action)
			if action == "services" then
				return { { id = "java", state = "running" } }
			end
			return nil
		end
		vim.fn["coc#util#get_config"] = function(section)
			eq("java", section)
			return { configuration = { runtimes = { { name = "JavaSE-17", path = "/opt/jdk17" } } } }
		end
		vim.fn.CocRequest = function(id, method, params)
			eq("java", id)
			eq("workspace/executeCommand", method)
			return { classpaths = { "/fake/classpath.jar" } }
		end

		local coc_client_provider = require("neotest-java-custom.client.coc_client")
		local client = coc_client_provider(nil)

		eq(true, client.initialized)
		eq("coc", client.name)
		eq({}, client.attached_buffers)
		eq("/opt/jdk17", client.config.settings.java.configuration.runtimes[1].path)

		local captured
		client:request("workspace/executeCommand", { command = "java.project.getClasspaths" }, function(err, result)
			captured = { err = err, result = result }
		end)
		eq(nil, captured.err)
		eq("/fake/classpath.jar", captured.result.classpaths[1])
	end)

	it("raises a clear error when no coc-java service is attached", function()
		vim.fn.CocAction = function()
			return {}
		end

		local coc_client_provider = require("neotest-java-custom.client.coc_client")
		local ok, err = pcall(coc_client_provider, nil)

		eq(false, ok)
		assert(
			tostring(err):find("No running java service attached", 1, true),
			"expected a coc-java error, got: " .. tostring(err)
		)
	end)
end)
