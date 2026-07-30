-- Unit tests for Manifest module.
-- Run with: lua5.1 tests/test_manifest.lua

io.stdout:setvbuf("no")

package.path = "/home/denial/.luarocks/share/lua/5.1/?.lua;" .. package.path

package.preload["json"] = function()
  return require("dkjson")
end

local JSON = require("json")

package.path = "./plugins/syncnotes.koplugin/?.lua;./plugins/syncnotes/koplugin/?.lua;" .. package.path
local Manifest = require("manifest")

local tests_run = 0
local tests_passed = 0

local function assert_eq(expected, actual, msg)
    tests_run = tests_run + 1
    local ok
    if type(expected) == "table" and type(actual) == "table" then
        ok = table_equals(expected, actual)
    else
        ok = expected == actual
    end
    if ok then
        tests_passed = tests_passed + 1
        io.write("  \226\156\144 " .. (msg or "") .. "\n")
    else
        io.write("  \225\156\151 " .. (msg or "") .. "\n")
        io.write("    expected: " .. tostring(expected) .. "\n")
        io.write("    actual:   " .. tostring(actual) .. "\n")
    end
end

local function assert_true(v, msg)
    tests_run = tests_run + 1
    if v then
        tests_passed = tests_passed + 1
        io.write("  \226\156\144 " .. msg .. "\n")
    else
        io.write("  \225\156\151 " .. msg .. " (expected true, got " .. tostring(v) .. ")\n")
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

------------------------------------------------------------------------
--- filterMdFiles
------------------------------------------------------------------------

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
    assert_eq(3, #result, "only .md blobs")
    assert_eq("README.md", result[1].path, "first path")
    assert_eq("notes/Lecture-01.md", result[2].path, "second path (nested)")
end

do
    assert_eq(0, #Manifest.filterMdFiles({ tree = {} }), "empty tree")
end

do
    assert_eq(0, #Manifest.filterMdFiles(nil), "nil input")
end

-- Adversarial: malformed tree entries
do
    local result = Manifest.filterMdFiles({ tree = { {}, { path = "nopath.md" }, { path = "no-type.md", sha = "x" } } })
    assert_eq(0, #result, "entries missing type field → skipped")
end

-- Adversarial: non-.md extension
do
    local result = Manifest.filterMdFiles({ tree = { { path = "readme.MD", type = "blob", sha = "x" } } })
    assert_eq(0, #result, ".MD uppercase excluded")
end

------------------------------------------------------------------------
--- buildManifest
------------------------------------------------------------------------

do
    local files = { { path = "README.md", sha = "aaa" }, { path = "notes/Lecture-01.md", sha = "bbb" } }
    local m = Manifest.buildManifest(files)
    assert_eq("aaa", m["README.md"], "README SHA")
    assert_eq("bbb", m["notes/Lecture-01.md"], "nested path SHA")
end

-- Duplicate paths: last wins
do
    local m = Manifest.buildManifest({ { path = "same.md", sha = "first" }, { path = "same.md", sha = "last" } })
    assert_eq("last", m["same.md"], "duplicate path: last sha wins")
end

-- Empty file list
do
    assert_eq(0, #Manifest.buildManifest({}), "empty input → empty manifest")
end

------------------------------------------------------------------------
--- computeChanges
------------------------------------------------------------------------

do
    local r = Manifest.computeChanges({}, { ["new.md"] = "abc" })
    assert_eq(1, #r.to_download, "new file → download")
    assert_eq("new.md", r.to_download[1].path)
    assert_eq(0, #r.to_delete, "nothing to delete")
end

do
    local r = Manifest.computeChanges({ ["note.md"] = "oldsha" }, { ["note.md"] = "newsha" })
    assert_eq(1, #r.to_download, "SHA differs → download")
    assert_eq(0, #r.to_delete, "nothing deleted")
end

do
    local r = Manifest.computeChanges({ ["note.md"] = "same" }, { ["note.md"] = "same" })
    assert_eq(0, #r.to_download, "SHA same → no download")
    assert_eq(0, #r.to_delete, "nothing deleted")
    assert_eq(1, #r.up_to_date, "1 up-to-date")
end

do
    local r = Manifest.computeChanges({ ["old.md"] = "s1", ["keep.md"] = "s2" }, { ["keep.md"] = "s2" })
    assert_eq(0, #r.to_download, "nothing to download")
    assert_eq(1, #r.to_delete, "1 deleted")
    assert_eq("old.md", r.to_delete[1], "deleted path")
end

do
    local r = Manifest.computeChanges(
        { ["keep.md"] = "s1", ["change.md"] = "old", ["remove.md"] = "s3" },
        { ["keep.md"] = "s1", ["change.md"] = "new", ["add.md"] = "s4" }
    )
    assert_eq(2, #r.to_download, "2 to download (new + modified)")
    assert_eq(1, #r.to_delete, "1 to delete")
    assert_eq(1, #r.up_to_date, "1 up-to-date")
    assert_eq("remove.md", r.to_delete[1])
end

-- computeChanges stats
do
    local r = Manifest.computeChanges({ ["a.md"] = "s1" }, { ["a.md"] = "s1", ["b.md"] = "s2" })
    assert_eq(2, r.stats.total)
    assert_eq(1, r.stats.changed)
    assert_eq(0, r.stats.deleted)
    assert_eq(1, r.stats.up_to_date)
end

-- Both manifests empty
do
    local r = Manifest.computeChanges({}, {})
    assert_eq(0, #r.to_download, "both empty → nothing")
    assert_eq(0, #r.to_delete)
    assert_eq(0, #r.up_to_date)
    assert_eq(0, r.stats.total)
end

------------------------------------------------------------------------
--- encodeManifest / decodeManifest
------------------------------------------------------------------------

do
    local m = { ["a.md"] = "sha1", ["b.md"] = "sha2" }
    local decoded = Manifest.decodeManifest(Manifest.encodeManifest(m))
    assert_eq("sha1", decoded["a.md"], "round-trip a.md")
    assert_eq("sha2", decoded["b.md"], "round-trip b.md")
end

do
    local result = Manifest.decodeManifest("not json")
    assert_eq(0, #result, "bad JSON → empty table")
    assert_true(next(result) == nil, "bad JSON → table has no keys")
end

-- Empty manifest encode/decode
do
    local m = {}
    local decoded = Manifest.decodeManifest(Manifest.encodeManifest(m))
    assert_eq(0, #decoded, "empty manifest round-trip")
end

------------------------------------------------------------------------
io.write(string.format("\nResults: %d/%d passed\n", tests_passed, tests_run))
if tests_passed == tests_run then
    io.write("All tests passed.\n")
    os.exit(0)
else
    io.write(string.format("FAIL: %d test(s) failed\n", tests_run - tests_passed))
    os.exit(1)
end
