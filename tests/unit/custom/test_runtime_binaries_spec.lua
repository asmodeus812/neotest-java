local assertions = require("tests.assertions")
local eq = assertions.eq

local RuntimeBinaries = require("neotest-java-custom.command.runtime_binaries")
local Path = require("neotest-java.model.path")

local MAVEN_SIMPLE_FIXTURE = Path("tests/fixtures/maven-simple")

describe("Runtime binaries", function()
	-- neotest-java-custom's own code no longer needs this (nio.fn already
	-- handles the fast-event-context issue it used to work around), but
	-- the base neotest-java.command.binaries this wraps still does - deps
	-- is shared between the two, so every case here still needs it for
	-- that base layer's own request(s) to resolve synchronously.
	local sync_schedule = function(fn)
		fn()
	end

	it("uses the jdtls-resolved runtime when it's available (no fallback)", function()
		local bin = RuntimeBinaries({
			client_provider = function()
				return {
					request = function(_, _, _, callback)
						callback(nil, { ["org.eclipse.jdt.ls.core.vm.location"] = "/opt/jdk17" })
					end,
				}
			end,
			schedule = sync_schedule,
		})

		eq(Path("/opt/jdk17/bin/java"), bin.java(Path("/repo")))
	end)

	it("falls back to pom.xml <properties> + java_runtimes when jdtls resolution errors", function()
		local bin = RuntimeBinaries({
			client_provider = function()
				return {
					request = function(_, _, _, callback)
						callback({ message = "no runtime configured" }, nil)
					end,
				}
			end,
			java_runtimes = { JAVA_HOME_11 = "/opt/jdk11" },
			schedule = sync_schedule,
		})

		-- fixtures/maven-simple/pom.xml declares maven.compiler.target=11
		eq(Path("/opt/jdk11/bin/java"), bin.java(MAVEN_SIMPLE_FIXTURE))
	end)

	it("falls back to JAVA_HOME when no pom.xml/version match is found", function()
		vim.fn.setenv("JAVA_HOME", "/opt/default-jdk")

		local bin = RuntimeBinaries({
			client_provider = function()
				return {
					request = function(_, _, _, callback)
						callback({ message = "no runtime configured" }, nil)
					end,
				}
			end,
			interactive = false,
			schedule = sync_schedule,
		})

		eq(Path("/opt/default-jdk/bin/java"), bin.java(Path("/repo/no-pom-here")))

		vim.fn.setenv("JAVA_HOME", vim.NIL)
	end)

	it("prefers a client-configured runtime matching the compiler version over pom.xml", function()
		local client = {
			config = {
				settings = {
					java = {
						configuration = {
							runtimes = {
								{ name = "JavaSE-17", path = "/opt/jdk17-configured", default = true },
								{ name = "JavaSE-11", path = "/opt/jdk11-configured" },
							},
						},
					},
				},
			},
			request = function(_, _, params, callback)
				local keys = params.arguments[2]
				if vim.tbl_contains(keys, "org.eclipse.jdt.ls.core.vm.location") then
					callback({ message = "no vm.location" }, nil)
				elseif vim.tbl_contains(keys, "org.eclipse.jdt.core.compiler.source") then
					callback(nil, { ["org.eclipse.jdt.core.compiler.source"] = "11" })
				end
			end,
		}

		local bin = RuntimeBinaries({
			client_provider = function()
				return client
			end,
			schedule = sync_schedule,
		})

		-- picks the JavaSE-11 runtime (exact compliance match), NOT the
		-- JavaSE-17 one even though it's flagged default = true, and never
		-- has to touch pom.xml to do it.
		eq(Path("/opt/jdk11-configured/bin/java"), bin.java(MAVEN_SIMPLE_FIXTURE))
	end)

	it("falls back to the default configured runtime when nothing matches the compiler version", function()
		local client = {
			config = {
				settings = {
					java = {
						configuration = {
							runtimes = {
								{ name = "JavaSE-21", path = "/opt/jdk21-default", default = true },
							},
						},
					},
				},
			},
			request = function(_, _, params, callback)
				local keys = params.arguments[2]
				if vim.tbl_contains(keys, "org.eclipse.jdt.ls.core.vm.location") then
					callback({ message = "no vm.location" }, nil)
				elseif vim.tbl_contains(keys, "org.eclipse.jdt.core.compiler.source") then
					callback(nil, { ["org.eclipse.jdt.core.compiler.source"] = "11" })
				end
			end,
		}

		local bin = RuntimeBinaries({
			client_provider = function()
				return client
			end,
			schedule = sync_schedule,
		})

		eq(Path("/opt/jdk21-default/bin/java"), bin.java(Path("/repo/no-pom-here")))
	end)

	it("adds the .exe extension on Windows for the fallback path", function()
		local bin = RuntimeBinaries({
			client_provider = function()
				return {
					request = function(_, _, _, callback)
						callback({ message = "no runtime configured" }, nil)
					end,
				}
			end,
			java_runtimes = { JAVA_HOME_11 = "/opt/jdk11" },
			is_windows = true,
			schedule = sync_schedule,
		})

		eq(Path("/opt/jdk11/bin/java.exe"), bin.java(MAVEN_SIMPLE_FIXTURE))
	end)
end)
