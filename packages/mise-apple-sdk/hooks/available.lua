---@param ctx AvailableCtx
---@return AvailableVersion[]
function PLUGIN:Available(ctx)
    local versions = {}
    for _, release in ipairs(require("releases").list) do
        table.insert(versions, 1, { version = release.version })
    end
    return versions
end
