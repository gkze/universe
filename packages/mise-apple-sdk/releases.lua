---@class Release
---@field version string
---@field sdk_version string
---@field sdk_build string
---@field product string
---@field package_id string
---@field package_version string
---@field url string
---@field sha256 string
---@field signer_sha256 string
---@field payload string

-- Oldest first. A release identity includes both the SDK version and build.
---@type Release[]
local releases = {
    {
        version = "15.5-24F74",
        sdk_version = "15.5",
        sdk_build = "24F74",
        product = "082-41241",
        package_id = "com.apple.pkg.CLTools_SDK_macOS_NMOS",
        package_version = "16.4.0.0.1.1747106510",
        url = table.concat({
            "https://swcdn.apple.com",
            "content",
            "downloads",
            "52",
            "01",
            "082-41241-A_0747ZN8FHV",
            "dectd075r63pppkkzsb75qk61s0lfee22j",
            "CLTools_macOSNMOS_SDK.pkg",
        }, "/"),
        sha256 = "ba3453d62b3d2babf67f3a4a44e8073d6555c85f114856f4390a1f53bd76e24a",
        signer_sha256 = "e074d204ac2498e9dc904a7bc7ced8464119b79d05668028920583b1e896ebb4",
        payload = table.concat({
            "Payload",
            "Library",
            "Developer",
            "CommandLineTools",
            "SDKs",
            "MacOSX15.5.sdk",
        }, "/"),
    },
}

---@param version string
---@return Release
local function find(version)
    for _, release in ipairs(releases) do
        if release.version == version then
            return release
        end
    end
    error("No reviewed Apple SDK release: " .. version)
end

return { list = releases, find = find }
