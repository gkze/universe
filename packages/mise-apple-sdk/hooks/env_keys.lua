---@param ctx EnvKeysCtx
---@return EnvKey[]
function PLUGIN:EnvKeys(ctx)
    return {
        { key = "SDKROOT", value = ctx.path .. "/MacOSX.sdk" },
    }
end
