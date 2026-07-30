# Slice 6: syncnotes — manifest comparison logic (pure functions + unit tests)

Depends on: Slice 4 (skeleton exists)

## Goal

Implement the pure-Lua functions for comparing local vs remote manifest and computing which files to download and which to delete. These are unit-testable without KOReader.

## Files to create

### `plugins/syncnotes.koplugin/manifest.lua`

A pure-Lua module with no KOReader dependencies (only `json` for encoding/decoding):

```lua
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
```

## Unit tests

### `tests/test_manifest.lua`

```lua
-- Unit tests for Manifest module (Slice 6)
-- Run with: lua5.1 tests/test_manifest.lua

local JSON = require("json")

-- Minimal JSON polyfill if not available outside KOReader
if not JSON then
    JSON = { encode = function(t) return "" end, decode = function(s) return {} end }
end

-- Load the module under test (adjust path for test runner)
package.path = "./plugins/syncnotes/koplugin/?.lua;" .. package.path
local Manifest = require("manifest")

local tests_run = 0
local tests_passed = 0

function assert_equal(expected, actual, msg)
    tests_run = tests_run + 1
    local ok
    if type(expected) == "table" and type(actual) == "table" then
        ok = table_equals(expected, actual)
    else
        ok = expected == actual
    end
    if ok then
        tests_passed = tests_passed + 1
        io.write("  ✓ " .. (msg or "") .. "\n")
    else
        io.write("  ✗ " .. (msg or "") .. "\n")
        io.write("    expected: " .. tostring(expected) .. "\n")
        io.write("    actual:   " .. tostring(actual) .. "\n")
    end
end

function table_equals(a, b)
    if #a ~= #b then return false end
    for i, v in ipairs(a) do
        if type(v) == "table" and type(b[i]) == "table" then
            if not table_equals(v, b[i]) then return false end
        elseif v ~= b[i] then
            return false
        end
    end
    return true
end

-- Test 1: filterMdFiles extracts only .md blobs
do
    local tree = {
        tree = {
            { path = "README.md", type = "blob", sha = "aaa" },
            { path = "notes/Lecture-01.md", type = "blob", sha = "bbb" },
            { path = "image.png", type = "blob", sha = "ccc" },
            { path = "subdir", type = "tree", sha = "ddd" },
            { path = "data.json", type = "blob", sha = "eee" },
            { path = "notes/Lecture-02.md", type = "blob", sha = "fff" },
        }
    }
    local result = Manifest.filterMdFiles(tree)
    assert_equal(3, #result, "filterMdFiles: only .md blobs")
    assert_equal("README.md", result[1].path, "filterMdFiles: path 1")
    assert_equal("notes/Lecture-01.md", result[2].path, "filterMdFiles: path 2")
end

-- Test 2: filterMdFiles returns empty for empty tree
do
    local result = Manifest.filterMdFiles({ tree = {} })
    assert_equal(0, #result, "filterMdFiles: empty tree")
end

-- Test 3: filterMdFiles returns empty for nil
do
    local result = Manifest.filterMdFiles(nil)
    assert_equal(0, #result, "filterMdFiles: nil input")
end

-- Test 4: buildManifest creates path→sha mapping
do
    local files = {
        { path = "README.md", sha = "aaa" },
        { path = "notes/Lecture-01.md", sha = "bbb" },
    }
    local m = Manifest.buildManifest(files)
    assert_equal("aaa", m["README.md"], "buildManifest: README sha")
    assert_equal("bbb", m["notes/Lecture-01.md"], "buildManifest: nested path sha")
end

-- Test 5: computeChanges — new file to download
do
    local local_m = {}
    local remote_m = { ["new.md"] = "abc" }
    local result = Manifest.computeChanges(local_m, remote_m)
    assert_equal(1, #result.to_download, "computeChanges: 1 new file")
    assert_equal("new.md", result.to_download[1].path, "computeChanges: new file path")
    assert_equal(0, #result.to_delete, "computeChanges: nothing to delete")
end

-- Test 6: computeChanges — modified file (SHA differs)
do
    local local_m = { ["note.md"] = "oldsha" }
    local remote_m = { ["note.md"] = "newsha" }
    local result = Manifest.computeChanges(local_m, remote_m)
    assert_equal(1, #result.to_download, "computeChanges: 1 modified")
    assert_equal("note.md", result.to_download[1].path, "computeChanges: modified path")
    assert_equal(0, #result.to_delete, "computeChanges: nothing deleted")
end

-- Test 7: computeChanges — up-to-date file
do
    local local_m = { ["note.md"] = "same" }
    local remote_m = { ["note.md"] = "same" }
    local result = Manifest.computeChanges(local_m, remote_m)
    assert_equal(0, #result.to_download, "computeChanges: nothing to download")
    assert_equal(0, #result.to_delete, "computeChanges: nothing to delete")
    assert_equal(1, #result.up_to_date, "computeChanges: 1 up-to-date")
end

-- Test 8: computeChanges — deleted file (remote removed)
do
    local local_m = { ["old.md"] = "sha1", ["keep.md"] = "sha2" }
    local remote_m = { ["keep.md"] = "sha2" }
    local result = Manifest.computeChanges(local_m, remote_m)
    assert_equal(0, #result.to_download, "computeChanges: nothing to download")
    assert_equal(1, #result.to_delete, "computeChanges: 1 deleted")
    assert_equal("old.md", result.to_delete[1], "computeChanges: deleted path")
end

-- Test 9: computeChanges — mixed: new + modified + deleted + up-to-date
do
    local local_m = {
        ["keep.md"] = "s1",
        ["change.md"] = "old",
        ["remove.md"] = "s3",
    }
    local remote_m = {
        ["keep.md"] = "s1",
        ["change.md"] = "new",
        ["add.md"] = "s4",
    }
    local result = Manifest.computeChanges(local_m, remote_m)
    assert_equal(2, #result.to_download, "computeChanges: 2 to download")
    assert_equal(1, #result.to_delete, "computeChanges: 1 to delete")
    assert_equal(1, #result.up_to_date, "computeChanges: 1 up-to-date")
    assert_equal("remove.md", result.to_delete[1], "computeChanges: remove.md deleted")
end

-- Test 10: computeChanges stats
do
    local local_m = { ["a.md"] = "s1" }
    local remote_m = { ["a.md"] = "s1", ["b.md"] = "s2" }
    local result = Manifest.computeChanges(local_m, remote_m)
    assert_equal(2, result.stats.total, "stats.total")
    assert_equal(1, result.stats.changed, "stats.changed")
    assert_equal(0, result.stats.deleted, "stats.deleted")
    assert_equal(1, result.stats.up_to_date, "stats.up_to_date")
end

-- Test 11: encodeManifest / decodeManifest round-trip
do
    local m = { ["a.md"] = "sha1", ["b.md"] = "sha2" }
    local encoded = Manifest.encodeManifest(m)
    local decoded = Manifest.decodeManifest(encoded)
    assert_equal("sha1", decoded["a.md"], "encode/decode round-trip")
    assert_equal("sha2", decoded["b.md"], "encode/decode round-trip")
end

-- Test 12: decodeManifest handles bad JSON
do
    local result = Manifest.decodeManifest("not json")
    assert_equal(0, #result, "decodeManifest: bad JSON returns empty table")
    -- Also test that it's an empty table (not nil)
    assert_equal(0, next(result) and 1 or 0, "decodeManifest: table is empty")
end

-- Summary
io.write(string.format("\nResults: %d/%d passed\n", tests_passed, tests_run))
if tests_passed == tests_run then
    io.write("All tests passed.\n")
    os.exit(0)
else
    io.write(string.format("FAIL: %d test(s) failed\n", tests_run - tests_passed))
    os.exit(1)
end
```

## Running tests

```bash
lua5.1 tests/test_manifest.lua
```

Requires `json` in Lua path. If not available, the test falls back to a no-op polyfill — install lua-json or use the KOReader-bundled json module:

```bash
# On Debian/Ubuntu
sudo apt install lua-json
```

Or copy `common/json.lua` from the koreader repo to a reachable path.

## Acceptance

- All 12 unit tests pass with `lua5.1 tests/test_manifest.lua`
- Logic correctly handles: new files, modified files, deleted files, up-to-date files, mixed scenarios, empty inputs, nil inputs, bad JSON
