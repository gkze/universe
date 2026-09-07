---@type cmd
local cmd = require("cmd")
---@type file
local file = require("file")
---@type json
local json = require("json")

local function trim(value)
    return (value:gsub("%s+$", ""))
end

---@param parts string[] Space-free shell words, with quoting preserved.
---@param env table<string, string>
---@return string
local function run(parts, env)
    return cmd.exec(table.concat(parts, " "), { env = env })
end

-- Do not follow SDK symlinks when removing extraction leftovers.
---@param path string
local function remove_tree(path)
    local stat = file.stat(path)
    if not stat then
        return
    end
    if stat.is_dir and not stat.is_symlink then
        for _, child in ipairs(file.list(path)) do
            remove_tree(child)
        end
    end
    assert(os.remove(path))
end

---@param release Release
---@param env table<string, string>
local function verify_signature(release, env)
    local signature =
        run({ "/usr/sbin/pkgutil", "--check-signature", '"$SDK_ARCHIVE"' }, env)
    assert(
        signature:find("Status: signed Apple Software", 1, true),
        "Package is not trusted Apple Software"
    )
    local fingerprint = signature:match("SHA256 Fingerprint:%s*([%x%s]+)")
    assert(
        fingerprint
            and fingerprint:gsub("%s", ""):lower() == release.signer_sha256,
        "Unexpected Apple SDK signing certificate"
    )
end

---@param release Release
---@param env table<string, string>
local function verify_sdk_metadata(release, env)
    local settings = json.decode(
        file.read(file.join_path(env.SDK_PAYLOAD, "SDKSettings.json"))
    )
    assert(type(settings) == "table", "Invalid SDK settings")
    local build = trim(run({
        "/usr/bin/plutil",
        "-extract",
        "ProductBuildVersion",
        "raw",
        "-o",
        "-",
        '"$SDK_PAYLOAD/System/Library/CoreServices/SystemVersion.plist"',
    }, env))
    assert(
        settings.Version == release.sdk_version and build == release.sdk_build,
        "Apple SDK metadata mismatch"
    )
end

---@param ctx PostInstallCtx
function PLUGIN:PostInstall(ctx)
    local release = require("releases").find(ctx.runtimeVersion)
    -- Mise downloads and verifies the archive before invoking this hook.
    local archive =
        file.join_path(ctx.rootPath, assert(release.url:match("[^/]+$")))
    local expanded = file.join_path(ctx.rootPath, ".expanded")
    assert(not file.stat(expanded), "SDK staging directory already exists")
    local env = {
        LC_ALL = "C",
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin",
        SDK_ARCHIVE = archive,
        SDK_EXPANDED = expanded,
        SDK_PAYLOAD = file.join_path(expanded, release.payload),
    }
    local ok, failure = pcall(function()
        verify_signature(release, env)
        run({
            "/usr/sbin/pkgutil",
            "--expand-full",
            '"$SDK_ARCHIVE"',
            '"$SDK_EXPANDED"',
        }, env)
        verify_sdk_metadata(release, env)
        local destination = file.join_path(ctx.rootPath, "MacOSX.sdk")
        assert(not file.stat(destination), "SDK destination already exists")
        assert(os.rename(env.SDK_PAYLOAD, destination))
    end)
    local cleaned, cleanup_error = pcall(function()
        remove_tree(expanded)
        assert(os.remove(archive))
    end)
    if not ok then
        error(
            tostring(failure)
                .. (
                    cleaned and ""
                    or "\nCleanup failed: " .. tostring(cleanup_error)
                )
        )
    end
    assert(cleaned, cleanup_error)
end
