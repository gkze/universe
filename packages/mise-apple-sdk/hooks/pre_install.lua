---@param ctx PreInstallCtx
---@return PreInstallResult
function PLUGIN:PreInstall(ctx)
    assert(RUNTIME.osType == "darwin", "Apple SDK verification requires macOS")
    local release = require("releases").find(ctx.version)
    return {
        version = release.version,
        url = release.url,
        sha256 = release.sha256,
    }
end
