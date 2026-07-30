--[[--
Pure logic: compute changes between local and remote file manifests.
No KOReader dependencies — testable with plain Lua 5.1.

A manifest is a table mapping relative file paths to SHA strings:
  { ["Lecture-01.md"] = "abc123...", ["subdir/note.md"] = "def456..." }
]]

local JSON = require("json")

local Manifest = {}

--- Filter a GitHub Trees API response to extract only .md blob entries.
-- @tparam table tree_data  The parsed JSON from GET /git/trees/{ref}?recursive=1
-- @treturn table  Array of { path = string, sha = string } for .md blobs
function Manifest.filterMdFiles(tree_data)
    local files = {}
    if not tree_data or not tree_data.tree then return files end
    for _, item in ipairs(tree_data.tree) do
        if item.type == "blob" and item.path:match("%.md$") then
            table.insert(files, { path = item.path, sha = item.sha })
        end
    end
    return files
end

--- Build a manifest table from a tree files array.
-- @tparam table files  Array of { path, sha }
-- @treturn table  { [path] = sha, ... }
function Manifest.buildManifest(files)
    local manifest = {}
    for _, f in ipairs(files) do
        manifest[f.path] = f.sha
    end
    return manifest
end

--- Compute what to download and what to delete based on delta.
-- @tparam table local_manifest  { [path] = sha } from local storage
-- @tparam table remote_manifest { [path] = sha } from GitHub tree
-- @treturn table  { to_download = { path, sha }[], to_delete = string[], up_to_date = string[], stats = { total, changed, deleted, up_to_date } }
function Manifest.computeChanges(local_manifest, remote_manifest)
    local to_download = {}
    local to_delete = {}
    local up_to_date = {}

    -- Files in remote but not in local, or SHA differs → download
    for path, sha in pairs(remote_manifest) do
        if local_manifest[path] ~= sha then
            table.insert(to_download, { path = path, sha = sha })
        else
            table.insert(up_to_date, path)
        end
    end

    -- Files in local but not in remote → delete
    for path, _ in pairs(local_manifest) do
        if not remote_manifest[path] then
            table.insert(to_delete, path)
        end
    end

    return {
        to_download = to_download,
        to_delete = to_delete,
        up_to_date = up_to_date,
        stats = {
            total = #to_download + #to_delete + #up_to_date,
            changed = #to_download,
            deleted = #to_delete,
            up_to_date = #up_to_date,
        },
    }
end

--- Encode a manifest to a JSON string for storage.
function Manifest.encodeManifest(manifest)
    return JSON.encode(manifest)
end

--- Decode a manifest from a JSON string.
-- @tparam string json_str
-- @treturn table  Empty table on parse failure
function Manifest.decodeManifest(json_str)
    local ok, data = pcall(JSON.decode, json_str)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

return Manifest
