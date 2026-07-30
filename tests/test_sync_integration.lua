-- Integration tests for syncnotes download pipeline.
-- Run with: LUA_CPATH='/home/denial/.luarocks/lib/lua/5.1/?.so;;' lua5.1 tests/test_sync_integration.lua

io.stdout:setvbuf("no")
package.path = "/home/denial/.luarocks/share/lua/5.1/?.lua;./plugins/syncnotes.koplugin/?.lua;" .. package.path

package.preload["json"] = function()
  return require("dkjson")
end

-- Mock KOReader modules
local mock_ui = { stack = {} }

package.preload["ui/widget/container/widgetcontainer"] = function() return { extend = function(_, t) return t end } end
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) table.insert(mock_ui.stack, w) end,
    close = function(_, w)
      for i = #mock_ui.stack, 1, -1 do
        if mock_ui.stack[i] == w then table.remove(mock_ui.stack, i) break end
      end
    end,
    forceRePaint = function() end,
  }
end
package.preload["ui/widget/infomessage"] = function()
  return {
    new = function(_, opts)
      return { text = opts.text, timeout = opts.timeout, setText = function(self, t) self.text = t end }
    end,
  }
end
package.preload["ui/widget/inputdialog"] = function() return { new = function() return { onShowKeyboard = function() end } end } end
package.preload["datastorage"] = function() return { getDataDir = function() return "/tmp/kobo-test" end, getSettingsDir = function() return "/tmp/kobo-test/settings" end } end
package.preload["luasettings"] = function()
  return {
    open = function()
      local data = {}
      return {
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        delSetting = function(_, k) data[k] = nil end,
        flush = function() end,
      }
    end,
  }
end
package.preload["ui/network/manager"] = function()
  return {
    runWhenOnline = function(_, cb) cb() end,
    afterWifiAction = function() end,
  }
end
package.preload["ssl.https"] = function()
  return { request = function() end }
end
package.preload["ltn12"] = function()
  return {
    sink = {
      table = function(t)
        return function(chunk)
          if chunk then t[#t+1] = chunk end
          return true
        end
      end,
    },
  }
end
package.preload["logger"] = function() return { info = function() end, warn = function() end, err = function() end } end
package.preload["util"] = function()
  return {
    getFileNameSuffix = function(f) return f:match("%.(%w+)$") or "" end,
    urlEncode = function(url)
      if not url then return nil end
      return url:gsub("([^%w%-%.%_~%/])", function(c) return string.format("%%%02X", string.byte(c)) end)
    end,
  }
end
package.preload["ffi/util"] = function()
  return {
    splitFilePathName = function(p) return p:match("^(.*/)(.*)$") or "", p end,
    template = function(s, ...)
      local t = s
      for i = 1, select("#", ...) do
        t = t:gsub("%%" .. i, tostring(select(i, ...)))
      end
      return t
    end,
  }
end
package.preload["libs/libkoreader-lfs"] = function()
  return require("lfs")
end

local Manifest = require("manifest")

local tests_run = 0
local tests_passed = 0

local function assert_eq(a, b, msg)
  tests_run = tests_run + 1
  if a == b then
    tests_passed = tests_passed + 1
    io.write("  \226\156\144 " .. msg .. "\n")
  else
    io.write("  \225\156\151 " .. msg .. "  (expected: " .. tostring(b) .. ", got: " .. tostring(a) .. ")\n")
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

local function clean_temp()
  os.execute("rm -rf /tmp/kobo-test")
  os.execute("mkdir -p /tmp/kobo-test/settings")
end

------------------------------------------------------------------------
--- progressBar
------------------------------------------------------------------------
io.write("\n--- progressBar ---\n")

local function progressBar(current, total, width)
  width = width or 12
  if total == 0 then
    return "[" .. string.rep("-", width) .. "]"
  end
  local filled = math.max(0, math.min(math.floor(current / total * width + 0.5), width))
  return "[" .. string.rep("#", filled) .. string.rep("-", width - filled) .. "]"
end

do
  assert_eq(progressBar(0, 10), "[------------]", "0/10 all empty")
  assert_eq(progressBar(5, 10), "[######------]", "5/10 half")
  assert_eq(progressBar(10, 10), "[############]", "10/10 full")
  assert_eq(progressBar(0, 0), "[------------]", "0 total shows empty")
  assert_eq(progressBar(1, 3, 6), "[##----]", "1/3 with width=6")
  -- Adversarial: overflow and underflow
  assert_eq(progressBar(15, 10), "[############]", "15/10 clamped to full")
  assert_eq(progressBar(-1, 10), "[------------]", "-1/10 clamped to empty")
  assert_eq(progressBar(0, 10, 0), "[]", "width=0 renders empty brackets")
  assert_eq(progressBar(0, 10, -1), "[]", "width=-1 renders empty brackets")
  assert_eq(progressBar(5, 10, 100), "[" .. string.rep("#", 50) .. string.rep("-", 50) .. "]", "5/10 with width=100")
end

------------------------------------------------------------------------
--- getNotesDir
------------------------------------------------------------------------
io.write("\n--- getNotesDir ---\n")

do
  local DataStorage = require("datastorage")

  local function getNotesDir(settings)
    local root = settings.notes_root or DataStorage:getDataDir() .. "/notes"
    local repo = settings.repo or "AI-2526"
    return root .. "/" .. repo .. "/"
  end

  assert_eq(getNotesDir({ notes_root = "/custom/path", repo = "my-repo" }), "/custom/path/my-repo/", "custom root + repo")
  assert_eq(getNotesDir({}), "/tmp/kobo-test/notes/AI-2526/", "defaults fallback")
  assert_eq(getNotesDir({ notes_root = "/trailing/slash/", repo = "r" }), "/trailing/slash//r/", "trailing slash on root")
end

------------------------------------------------------------------------
--- URL construction
------------------------------------------------------------------------
io.write("\n--- URL construction ---\n")

local function buildTreeURL(owner, repo, branch)
  return string.format("https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1", owner, repo, branch)
end

local function buildRawURL(owner, repo, branch, path)
  return string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo, branch, path)
end

do
  assert_eq(buildTreeURL("denialbb", "AI-2526", "master"),
    "https://api.github.com/repos/denialbb/AI-2526/git/trees/master?recursive=1",
    "tree URL basic")

  assert_eq(buildRawURL("denialbb", "AI-2526", "master", "notes/Lecture-01.md"),
    "https://raw.githubusercontent.com/denialbb/AI-2526/master/notes/Lecture-01.md",
    "raw URL basic")

  assert_eq(buildRawURL("denialbb", "AI-2526", "master",
    require("util").urlEncode("sub dir/file name.md")),
    "https://raw.githubusercontent.com/denialbb/AI-2526/master/sub%20dir/file%20name.md",
    "raw URL with space encoding")

  assert_eq(buildRawURL("a", "b", "main", require("util").urlEncode("file#1.md?query")),
    "https://raw.githubusercontent.com/a/b/main/file%231.md%3Fquery",
    "raw URL with # and ? encoding")
end

------------------------------------------------------------------------
--- Download loop
------------------------------------------------------------------------
io.write("\n--- Download loop ---\n")

do
  clean_temp()
  local notes_dir = "/tmp/kobo-test/notes/AI-2526/"

  local fake_tree = {
    tree = {
      { path = "Lecture-01.md", type = "blob", sha = "aaa" },
      { path = "images/note.md", type = "blob", sha = "bbb" },
      { path = "image.png", type = "blob", sha = "ccc" },
    }
  }

  local files = Manifest.filterMdFiles(fake_tree)
  local manifest = Manifest.buildManifest(files)
  assert_eq(#files, 2, "filter: 2 .md files")
  assert_eq(manifest["Lecture-01.md"], "aaa", "sha for Lecture-01.md")
  assert_eq(manifest["images/note.md"], "bbb", "sha for nested path")

  require("lfs").mkdir("/tmp/kobo-test/notes/")
  require("lfs").mkdir(notes_dir)

  local downloaded = {}
  for _, entry in ipairs(files) do
    local local_path = notes_dir .. entry.path
    local dir = notes_dir
    for sub in entry.path:gmatch("([^/]+)/") do
      dir = dir .. sub .. "/"
      require("lfs").mkdir(dir)
    end
    local f = io.open(local_path, "w")
    f:write("content of " .. entry.path)
    f:close()
    table.insert(downloaded, entry.path)
  end

  assert_eq(#downloaded, 2, "2 files written")
  assert_true(require("lfs").attributes(notes_dir .. "Lecture-01.md", "mode") == "file",
    "Lecture-01.md exists")
  assert_true(require("lfs").attributes(notes_dir .. "images/note.md", "mode") == "file",
    "nested images/note.md exists")
  assert_true(require("lfs").attributes(notes_dir .. "images", "mode") == "directory",
    "images/ directory created")

  local f = io.open(notes_dir .. "Lecture-01.md", "r")
  assert_eq(f:read("*a"), "content of Lecture-01.md", "file content correct")
  f:close()
end

-- Empty repo: no .md files
do
  clean_temp()
  local files = Manifest.filterMdFiles({ tree = {} })
  assert_eq(#files, 0, "empty tree: 0 files")
end

------------------------------------------------------------------------
--- Error paths
------------------------------------------------------------------------
io.write("\n--- Error paths ---\n")

do
  clean_temp()
  local notes_dir = "/tmp/kobo-test/notes/AI-2526/"
  require("lfs").mkdir("/tmp/kobo-test/notes/")
  require("lfs").mkdir(notes_dir)

  local function error_msg(http_code)
    if http_code == 401 then return "Bad or expired token."
    elseif http_code == 403 then return "Rate limited."
    elseif http_code == 404 then return "Repo not found."
    else return "HTTP " .. tostring(http_code) end
  end

  assert_eq(error_msg(401), "Bad or expired token.", "HTTP 401")
  assert_eq(error_msg(403), "Rate limited.", "HTTP 403")
  assert_eq(error_msg(404), "Repo not found.", "HTTP 404")
  assert_eq(error_msg(500), "HTTP 500", "HTTP 500")
  assert_eq(error_msg(nil), "HTTP nil", "nil (network failure)")
  assert_eq(error_msg(0), "HTTP 0", "HTTP 0 (no response)")
end

------------------------------------------------------------------------
--- Manifest file round-trip
------------------------------------------------------------------------
io.write("\n--- Manifest file round-trip ---\n")

do
  clean_temp()
  local manifest_file = "/tmp/kobo-test/.sync_manifest.json"

  local m = { ["a.md"] = "sha1", ["sub/b.md"] = "sha2" }
  local f = io.open(manifest_file, "w")
  f:write(Manifest.encodeManifest(m))
  f:close()

  local f2 = io.open(manifest_file, "r")
  local decoded = Manifest.decodeManifest(f2:read("*a"))
  f2:close()
  assert_eq(decoded["a.md"], "sha1", "a.md SHA restored")
  assert_eq(decoded["sub/b.md"], "sha2", "sub/b.md SHA restored")

  -- Corrupted manifest decodes to empty
  local empty = Manifest.decodeManifest("not valid json at all !!!")
  assert_eq(#empty, 0, "corrupt manifest → empty table")
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
