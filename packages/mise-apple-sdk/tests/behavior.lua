-- Runs in a disposable Mise process; provider effects are simulated.
---@param self Plugin
---@param ctx AvailableCtx
---@return AvailableVersion[]
return function(self, ctx)
    require("original_available")
    local releases = require("releases")
    local release = releases.list[1]
    local available = self:Available(ctx)
    assert(#available == #releases.list)
    assert(available[1].version == releases.list[#releases.list].version)
    assert(releases.find(release.version) == release)
    local ok, failure = pcall(releases.find, "unreviewed")
    assert(not ok and tostring(failure):find("No reviewed", 1, true))

    require("hooks.pre_install")
    local host = RUNTIME
    RUNTIME = { osType = "linux" }
    local install_ok, install_error = pcall(self.PreInstall, self, {
        args = {},
        version = release.version,
    })
    assert(
        not install_ok
            and tostring(install_error):find("requires macOS", 1, true)
    )
    RUNTIME = { osType = "darwin" }
    local install = self:PreInstall({ args = {}, version = release.version })
    assert(install.url == release.url and install.sha256 == release.sha256)
    assert(install.version == release.version)
    RUNTIME = host

    require("hooks.env_keys")
    local sdk = { path = "/fixture with spaces", version = release.version }
    local keys = self:EnvKeys({
        path = sdk.path,
        version = sdk.version,
        main = sdk,
        sdkInfo = {},
        options = {},
    })
    assert(#keys == 1 and keys[1].key == "SDKROOT")
    assert(keys[1].value == sdk.path .. "/MacOSX.sdk")

    local cmd = require("cmd")
    local file = require("file")
    local json = require("json")
    local real_exec, real_stat = cmd.exec, file.stat
    local real_list, real_read = file.list, file.read
    local real_decode = json.decode
    local real_remove, real_rename = os.remove, os.rename
    require("hooks.post_install")

    -- Model provider effects; assertions exercise the real hook's decisions.
    for _, scenario in ipairs({
        "success",
        "untrusted",
        "signer",
        "metadata",
        "build",
        "expand",
        "rename",
        "cleanup",
        "primary-and-cleanup",
        "staging",
    }) do
        local expanded, published, removed = false, false, false
        local root = "/fixture with spaces"
        local archive = root .. "/" .. assert(release.url:match("[^/]+$"))
        file.stat = function(path)
            if path == root .. "/.expanded" then
                if expanded or scenario == "staging" then
                    return { is_dir = true, is_symlink = false }
                end
            elseif path == root .. "/.expanded/link" then
                return { is_dir = true, is_symlink = true }
            end
            return nil
        end
        file.list = function(path)
            assert(path == root .. "/.expanded", "followed a symlink")
            return { root .. "/.expanded/link" }
        end
        file.read = function(path)
            assert(path:find("SDKSettings.json", 1, true))
            return "fixture"
        end
        json.decode = function(value)
            assert(value == "fixture")
            return {
                Version = scenario == "metadata" and "wrong"
                    or release.sdk_version,
            }
        end
        cmd.exec = function(command, options)
            assert(options.env.SDK_ARCHIVE == archive)
            assert(options.env.LC_ALL == "C")
            if command:find("--check-signature", 1, true) then
                assert(command:find('"$SDK_ARCHIVE"', 1, true))
                if
                    scenario == "untrusted"
                    or scenario == "primary-and-cleanup"
                then
                    return "unsigned package"
                end
                return "Status: signed Apple Software\nSHA256 Fingerprint: "
                    .. (
                        scenario == "signer" and "0000"
                        or release.signer_sha256
                    )
            elseif command:find("--expand-full", 1, true) then
                expanded = true
                assert(scenario ~= "expand", "fixture expansion failure")
                return ""
            end
            assert(command:find("ProductBuildVersion", 1, true))
            return scenario == "build" and "wrong" or release.sdk_build
        end
        -- Intentional replacement of provider effects in this fixture.
        ---@diagnostic disable-next-line: duplicate-set-field
        os.rename = function(source, destination)
            assert(source == root .. "/.expanded/" .. release.payload)
            assert(destination == root .. "/MacOSX.sdk")
            if scenario == "rename" then
                return nil, "fixture rename failure"
            end
            published = true
            return true
        end
        ---@diagnostic disable-next-line: duplicate-set-field
        os.remove = function(path)
            if path == archive then
                if
                    scenario == "cleanup"
                    or scenario == "primary-and-cleanup"
                then
                    return nil, "fixture cleanup failure"
                end
                removed = true
            else
                assert(
                    path == root .. "/.expanded"
                        or path == root .. "/.expanded/link"
                )
            end
            return true
        end
        local post_ok, post_error = pcall(self.PostInstall, self, {
            rootPath = root,
            runtimeVersion = release.version,
            sdkInfo = {},
        })
        assert(post_ok == (scenario == "success"), scenario)
        assert(published == (scenario == "success" or scenario == "cleanup"))
        if scenario == "primary-and-cleanup" then
            assert(tostring(post_error):find("not trusted", 1, true))
            assert(tostring(post_error):find("Cleanup failed", 1, true))
        elseif scenario ~= "cleanup" and scenario ~= "staging" then
            assert(removed, scenario .. " did not clean the archive")
        end
    end
    cmd.exec, file.stat = real_exec, real_stat
    file.list, file.read, json.decode = real_list, real_read, real_decode
    os.remove, os.rename = real_remove, real_rename
    return { { version = "passed" } }
end
