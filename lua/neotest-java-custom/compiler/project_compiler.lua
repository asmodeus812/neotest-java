local logger = require("neotest-java.logger")

--- Compiles only the JDTLS project(s) rooted under the given base_dir
--- (via the `java/buildProjects` LSP extension), instead of the whole
--- workspace like the default `lsp_compiler`. Useful on large
--- multi-module workspaces where a full `java/buildWorkspace` is slow.
--- Falls back to a full workspace build if the active projects cannot
--- be resolved.
---
--- @diagnostic disable-next-line: undefined-doc-name
--- @param deps { client_provider: fun(cwd: neotest-java.Path): vim.lsp.Client }
--- @return NeotestJavaCompiler
local function ProjectCompiler(deps)
    --- @param client any
    --- @param args NeotestJavaCompiler.Opts
    local function build_workspace(client, args)
        logger.info("project_compiler: full workspace build, mode:", args.compile_mode)
        --- @diagnostic disable-next-line: undefined-field
        client:request("java/buildWorkspace", { forceRebuild = args.compile_mode == "full" }, function(err)
            if err then
                logger.error("project_compiler: workspace build failed:", err)
            else
                logger.debug("project_compiler: workspace build complete")
            end
        end)
    end

    --- @param client any
    --- @param args NeotestJavaCompiler.Opts
    --- @param projects string[] project URIs
    local function build_projects(client, args, projects)
        local base_dir_str = args.base_dir:to_string()
        local scoped = vim.tbl_filter(function(uri)
            local name = uri and vim.uri_to_fname(uri)
            return name ~= nil and vim.startswith(name, base_dir_str)
        end, projects)

        if not scoped or #scoped == 0 then
            logger.warn(
                "project_compiler: none of jdtls's known projects fall under",
                base_dir_str,
                "- falling back to a full workspace build:",
                projects
            )
            build_workspace(client, args)
            return
        end

        logger.info("project_compiler: building", scoped, "mode:", args.compile_mode)

        --- @diagnostic disable-next-line: undefined-field
        client:request("java/buildProjects", {
            identifiers = vim.tbl_map(function(uri)
                return { uri = uri }
            end, scoped),
            isFullBuild = args.compile_mode == "full",
        }, function(err)
            if err then
                logger.error("project_compiler: build failed:", err)
            else
                logger.debug("project_compiler: build complete")
            end
        end)
    end

    return {
        --- @param args NeotestJavaCompiler.Opts
        compile = function(args)
            local client = deps.client_provider(args.base_dir)
            if not client or not client.initialized then
                logger.warn("project_compiler: no initialized client for", args.base_dir:to_string(),
                    "- skipping compile")
                return
            end

            --- @diagnostic disable-next-line: undefined-field
            client:request("workspace/executeCommand", {
                command = "java.project.getAll",
            }, function(err, projects)
                if err or not projects then
                    logger.warn(
                        "project_compiler: could not resolve active jdtls projects, falling back to a full workspace build:",
                        err
                    )
                    build_workspace(client, args)
                    return
                end

                build_projects(client, args, projects)
            end)
        end,
    }
end

return ProjectCompiler
