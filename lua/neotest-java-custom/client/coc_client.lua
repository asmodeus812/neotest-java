-- Minimal vim.lsp.Client-shaped proxy backed by coc.nvim's RPC.
--
-- neotest-java's public DI surface (classpath_provider, binaries,
-- lsp_compiler) only ever calls `client:request(method, params, callback)`
-- and reads `client.initialized` / `client.attached_buffers` off whatever
-- `client_provider(cwd)` returns - it doesn't care whether that object is
-- a real vim.lsp.Client. This exists because coc.nvim does not register
-- itself under vim.lsp.get_clients(), so there is no real client object
-- to hand back for a coc-java setup.
--
-- attached_buffers is always empty here, deliberately: the only thing
-- either current reader (classpath_provider.lua, runtime_binaries.lua)
-- does with it is `vim.tbl_keys(client.attached_buffers)[1]`, passed
-- straight through as the trailing bufnr argument to
-- `client:request(method, params, callback, bufnr)`. For a real
-- vim.lsp.Client that argument is load-bearing (nvim core's own
-- Client:request flushes that buffer's pending edits and tracks the
-- request against it - see vim/lsp/client.lua). For coc it never can be:
-- CocRequest's whole chain (plugin/coc.vim's CocRequest ->
-- coc#rpc#request('sendRequest', ...) -> services.sendRequest(id,
-- method, params) on the TS side) takes exactly those three arguments,
-- with no buffer slot to receive one. Tracking real attached buffers
-- here to populate a value nothing can currently use isn't worth the
-- upkeep (autocmds, cwd scoping, a coc.nvim RPC round-trip per buffer
-- via CocAction('ensureDocument', ...) on every read).
--
-- If some future consumer starts reading attached_buffers for a different
-- reason, this is the place to bring that tracking back.

local nio = require("nio")
local logger = require("neotest-java.logger")

--- @diagnostic disable-next-line: undefined-doc-name
--- @param _cwd neotest-java.Path
--- @return vim.lsp.Client
local function coc_client_provider(_cwd)
    local ok_services, services = pcall(nio.fn.CocAction, "services")
    assert(ok_services, "Failed to obtain active services: " .. tostring(services))

    local java_services = vim.tbl_filter(function(service)
        return service and service.state == "running" and service.id == "java"
    end, services)

    assert(
        #java_services > 0,
        "No running java service attached: " .. vim.inspect(services)
    )
    local ok_settings, java_settings = pcall(nio.fn["coc#util#get_config"], "java")

    return {
        initialized = true,
        name = "coc",
        attached_buffers = {}, -- left empty for now not really used for coc
        config = { settings = { java = ok_settings and java_settings or {} } },
        request = function(_, method, params, callback)
            logger.debug("CocRequest:", method, params)
            local ok, result = pcall(nio.fn.CocRequest, "java", method, params)
            if not ok then
                logger.warn("CocRequest failed:", method, result)
            end
            local err = (not ok) and { message = result } or nil
            if callback then
                callback(err, result)
            end
            return true
        end,
    }
end

return coc_client_provider
