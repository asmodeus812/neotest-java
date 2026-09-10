local Path = require("neotest-java.model.path")
local Binaries = require("neotest-java.command.binaries")
local logger = require("neotest-java.logger")
local nio = require("nio")
local xml = require("neotest.lib.xml")

--- Plain synchronous file read (deliberately not `neotest.lib.file.read`,
--- which is nio-async and would force every caller of this module onto
--- an async context just to read a local pom.xml).
--- @param path string
--- @return string | nil
local function read_file(path)
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local content = fd:read("*a")
    fd:close()
    return content
end

--- xml2lua only wraps repeated sibling tags into a list when there is
--- more than one occurrence; a lone <plugin> stays a plain table. This
--- normalizes both shapes into a list so callers can always `ipairs` it.
--- @param node table | nil
--- @return table[]
local function to_list(node)
    if node == nil then
        return {}
    end
    if node[1] ~= nil then
        return node
    end
    return { node }
end

--- @param var string
--- @return string | nil
local function get_env(var)
    local value = nio.fn.getenv(var)
    return value ~= vim.NIL and value ~= "" and value or nil
end

local COMPILER_SETTING = "org.eclipse.jdt.core.compiler.source"

--- Asks the LSP client for this project's configured compiler compliance
--- level (the same setting the default Binaries queries alongside
--- vm.location), then matches it against the client's own
--- java.configuration.runtimes — no pom.xml/gradle parsing involved,
--- since jdtls already resolved the compliance level for whichever
--- build file is active at cwd. Prefers an exact compliance match; a
--- runtime flagged `default = true` is only used if nothing matches.
---
--- This is the primary fallback: `java.configuration.runtimes` is
--- typically populated once, up front, in the LSP client's own setup
--- (e.g. from JAVA_HOME_<N> env vars), so it works with zero additional
--- neotest-java config. pom.xml parsing (below) only matters when the
--- client wasn't configured with a runtimes list at all.
---
--- @diagnostic disable-next-line: undefined-doc-name
--- @param client vim.lsp.Client
--- @param cwd neotest-java.Path
--- @return string | nil
local function runtime_from_client_config(client, cwd)
    local settings = client.config and client.config.settings and client.config.settings.java
    local runtimes = settings and settings.configuration and settings.configuration.runtimes
    if not runtimes or #runtimes == 0 then
        return nil
    end

    local bufnr = client.attached_buffers and vim.tbl_keys(client.attached_buffers)[1]
    local result_future = nio.control.future()
    --- @diagnostic disable-next-line: undefined-field
    client:request("workspace/executeCommand", {
        command = "java.project.getSettings",
        arguments = { vim.uri_from_fname(cwd:to_string()), { COMPILER_SETTING } },
    }, function(err, res)
        result_future.set((not err) and res and res[COMPILER_SETTING] or nil)
    end, bufnr)
    local compiler_version = result_future.wait()
    if not compiler_version then
        return nil
    end

    local default_path
    for _, runtime in ipairs(runtimes) do
        if runtime.default == true and not default_path then
            default_path = runtime.path
        end
        local suffix = runtime.name and runtime.name:match(".*-(.*)")
        if suffix and suffix == compiler_version then
            return runtime.path
        end
    end
    return default_path
end

--- @param target string
--- @return string
local function normalize_version(target)
    local parts = vim.split(tostring(target), "%.")
    return parts[#parts]
end

--- Best-effort extraction of the JDK version a maven project is
--- configured for. Checks, in order:
---   1. <properties><maven.compiler.release>/<maven.compiler.target> — the
---      common modern convention.
---   2. maven-compiler-plugin's own <configuration><release>/<target> —
---      the older, more explicit convention.
--- Returns nil when it cannot be determined (no pom.xml, neither
--- convention present, or an unparseable version).
--- @param base_dir neotest-java.Path
--- @return string | nil
local function read_pom_compiler_version(base_dir)
    local pom_path = base_dir:append("pom.xml"):to_string()
    local content = read_file(pom_path)
    if not content then
        return nil
    end

    local ok_parse, tree = pcall(xml.parse, content)
    if not ok_parse or not tree or not tree.project then
        return nil
    end

    local properties = tree.project.properties
    local from_properties = properties and (properties["maven.compiler.release"] or properties["maven.compiler.target"])
    if from_properties then
        return normalize_version(from_properties)
    end

    local build = tree.project.build
    local plugins = build and build.plugins and build.plugins.plugin
    for _, plugin in ipairs(to_list(plugins)) do
        if plugin.artifactId == "maven-compiler-plugin" and plugin.configuration then
            local target = plugin.configuration.release or plugin.configuration.target
            if target then
                return normalize_version(target)
            end
        end
    end

    return nil
end

--- Prompts the user for a runtime home directory, validating it points
--- at a real JDK install (i.e. has a bin/ subdirectory).
--- @param version string
--- @return string | nil
local function input_runtime(version)
    local runtime_path = nio.fn.input({
        default = "",
        prompt = string.format("Enter runtime home directory for JDK-%s (empty to use JAVA_HOME): ", version),
        completion = "dir",
        cancelreturn = "__INPUT_CANCELLED__",
    })

    if runtime_path == "__INPUT_CANCELLED__" or not runtime_path or #runtime_path == 0 then
        return get_env("JAVA_HOME")
    elseif nio.fn.isdirectory(runtime_path) == 0 or nio.fn.isdirectory(runtime_path .. "/bin") == 0 then
        logger.warn(string.format("Invalid runtime home directory %s was specified, please try again", runtime_path))
        return input_runtime(version)
    end

    return runtime_path
end

--- Wraps the default jdtls-backed `Binaries` provider with a fallback
--- chain for when jdtls can't resolve vm.location directly for a given
--- project:
---   1. Match the project's compiler compliance level against the
---      client's own `java.configuration.runtimes` (no file parsing).
---   2. Read the JDK version off pom.xml, then resolve it via an
---      explicit `java_runtimes` table, a `JAVA_HOME_<version>` env
---      var, or an interactive prompt.
---   3. Plain `JAVA_HOME`.
---
--- @diagnostic disable-next-line: undefined-doc-name
--- @param deps { client_provider: fun(cwd: neotest-java.Path): vim.lsp.Client, java_runtimes?: table<string, string>, is_windows?: boolean, interactive?: boolean, schedule?: fun(fn: fun()) }
--- @return neotest-java.LspBinaries
local function RuntimeBinaries(deps)
    local base = Binaries(deps)
    local runtime_cache = {}

    --- @param cwd neotest-java.Path
    --- @return string
    local function resolve_fallback_runtime(cwd)
        local cache_key = cwd:to_string()
        if runtime_cache[cache_key] then
            return runtime_cache[cache_key]
        end

        local runtime

        local ok_client, client = pcall(deps.client_provider, cwd)
        if ok_client and client then
            local ok_configured, configured = pcall(runtime_from_client_config, client, cwd)
            runtime = ok_configured and configured or nil
            if runtime then
                logger.info("runtime_binaries: matched", cache_key, "->", runtime, "(configured runtimes)")
            end
        end

        local version
        if not runtime then
            version = read_pom_compiler_version(cwd)
            runtime = version
                and (
                    (deps.java_runtimes and deps.java_runtimes[string.format("JAVA_HOME_%s", version)])
                    or get_env(string.format("JAVA_HOME_%s", version))
                )
            if runtime then
                logger.info("runtime_binaries: matched", cache_key, "->", runtime, "(JAVA_HOME_" .. version .. ")")
            end
        end

        if not runtime and version and deps.interactive ~= false then
            runtime = input_runtime(version)
            if runtime then
                logger.info("runtime_binaries: matched", cache_key, "->", runtime, "(interactive prompt)")
            end
        end

        if not runtime then
            runtime = get_env("JAVA_HOME")
            if runtime then
                logger.info("runtime_binaries: matched", cache_key, "->", runtime, "(plain JAVA_HOME)")
            end
        end

        assert(
            runtime,
            "unable to resolve a java runtime for "
            .. cache_key
            .. " (no jdtls vm.location, no matching configured runtime, no pom.xml match, no JAVA_HOME)"
        )

        runtime_cache[cache_key] = runtime
        return runtime
    end

    --- @param cwd neotest-java.Path
    --- @param exe string
    --- @return neotest-java.Path
    local function resolve(cwd, exe)
        local ok, resolved = pcall(function()
            return exe == "java" and base.java(cwd) or base.javap(cwd)
        end)

        if ok and resolved then
            logger.info("runtime_binaries: matched", cwd:to_string(), "->", resolved:to_string(),
                "(jdtls vm.location, " .. exe .. ")")
            return resolved
        end

        logger.warn(
            "runtime_binaries: jdtls did not report a usable java runtime for",
            cwd:to_string(),
            "- falling back to configured-runtimes/pom.xml/JAVA_HOME resolution:",
            resolved
        )

        local is_windows = deps.is_windows
        if is_windows == nil then
            is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
        end
        local exe_ext = is_windows and ".exe" or ""

        return Path(resolve_fallback_runtime(cwd)):append("bin/" .. exe .. exe_ext)
    end

    return {
        --- @param cwd neotest-java.Path
        java = function(cwd)
            return resolve(cwd, "java")
        end,

        --- @param cwd neotest-java.Path
        javap = function(cwd)
            return resolve(cwd, "javap")
        end,
    }
end

return RuntimeBinaries
