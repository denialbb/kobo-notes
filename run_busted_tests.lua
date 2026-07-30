--[[--
Minimal, dependency-free busted-compatible test runner.

Deliberately has no luarocks/busted dependency: it implements just enough of
the busted API (describe/it/before_each/after_each and the assert table) for
the specs in tests/. Run with:  lua run_busted_tests.lua
]]

--------------------------------------------------------------------------
-- Test framework
--------------------------------------------------------------------------

local stats = { passed = 0, failed = 0, failures = {} }
local hook_stack = {}          -- stack of {before=fn, after=fn} per describe
local name_stack = {}

_G.describe = function(name, fn)
    print("Suite: " .. name)
    name_stack[#name_stack + 1] = name
    hook_stack[#hook_stack + 1] = {}
    local ok, err = pcall(fn)
    if not ok then
        stats.failed = stats.failed + 1
        stats.failures[#stats.failures + 1] = name .. " (suite body): " .. tostring(err)
        print("    SUITE ERROR: " .. tostring(err))
    end
    hook_stack[#hook_stack] = nil
    name_stack[#name_stack] = nil
end

local function runHooks(key)
    for i = 1, #hook_stack do
        local fn = hook_stack[i][key]
        if fn then fn() end
    end
end

_G.it = function(name, fn)
    local full = table.concat(name_stack, " / ") .. " / " .. name
    local ok, err = pcall(function()
        runHooks("before")
        fn()
        runHooks("after")
    end)
    if ok then
        stats.passed = stats.passed + 1
        print("  PASS: " .. name)
    else
        stats.failed = stats.failed + 1
        stats.failures[#stats.failures + 1] = full .. "\n      " .. tostring(err)
        print("  FAIL: " .. name .. "\n      " .. tostring(err))
    end
end

_G.before_each = function(fn)
    hook_stack[#hook_stack].before = fn
end

_G.after_each = function(fn)
    hook_stack[#hook_stack].after = fn
end

--------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------

local original_assert = assert

local function fail(msg, extra)
    error(msg .. (extra and (": " .. tostring(extra)) or ""), 3)
end

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

_G.assert = setmetatable({
    is_true     = function(v, m) if v ~= true then fail("expected true, got " .. tostring(v), m) end end,
    is_false    = function(v, m) if v ~= false then fail("expected false, got " .. tostring(v), m) end end,
    is_truthy   = function(v, m) if not v then fail("expected truthy, got " .. tostring(v), m) end end,
    is_falsy    = function(v, m) if v then fail("expected falsy, got " .. tostring(v), m) end end,
    is_nil      = function(v, m) if v ~= nil then fail("expected nil, got " .. tostring(v), m) end end,
    is_not_nil  = function(v, m) if v == nil then fail("expected not nil", m) end end,
    is_table    = function(v, m) if type(v) ~= "table" then fail("expected table, got " .. type(v), m) end end,
    is_string   = function(v, m) if type(v) ~= "string" then fail("expected string, got " .. type(v), m) end end,
    is_function = function(v, m) if type(v) ~= "function" then fail("expected function, got " .. type(v), m) end end,
    has_error   = function(fn, m)
        local ok = pcall(fn)
        if ok then fail("expected function to raise", m) end
    end,
    has_no_error = function(fn, m)
        local ok, err = pcall(fn)
        if not ok then fail("expected no error, got " .. tostring(err), m) end
    end,
    are = {
        equal = function(a, b, m)
            if a ~= b then
                fail("expected [" .. tostring(a) .. "] == [" .. tostring(b) .. "]", m)
            end
        end,
        not_equal = function(a, b, m)
            if a == b then fail("expected values to differ (" .. tostring(a) .. ")", m) end
        end,
        same = function(a, b, m)
            if not deepEqual(a, b) then fail("expected tables to be deeply equal", m) end
        end,
    },
}, {
    __call = function(_, v, msg) return original_assert(v, msg) end
})

--------------------------------------------------------------------------
-- Environment stubs (KOReader modules unavailable on the host)
--------------------------------------------------------------------------

package.path = package.path .. ";./plugins/markdownreader.koplugin/?.lua"

package.preload["ffi"] = function()
    return {
        load = function() error("no native libraries in the test environment") end,
        cdef = function() end,
        typeof = function() return {} end,
        new = function() return {} end,
        cast = function() return {} end,
        C = {},
    }
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err  = function(...) print("LOG [error]:", ...) end,
        dbg  = function() end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        mkdir = function(p) os.execute("mkdir -p '" .. p .. "'") end,
        attributes = function() return nil end,
        dir = function() return function() return nil end end,
    }
end

package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        setDirty = function() end,
        forceRePaint = function() end,
    }
end

package.preload["ui/widget/infomessage"] = function()
    return {
        new = function(_, opts)
            return {
                text = opts.text,
                timeout = opts.timeout,
                movable = { dimen = { x = 0, y = 0, w = 100, h = 50 } },
            }
        end,
    }
end

--------------------------------------------------------------------------
-- Spec discovery
--------------------------------------------------------------------------

local function discoverSpecs()
    local specs = {}
    local pipe = io.popen("ls tests/*_spec.lua 2>/dev/null")
    if pipe then
        for line in pipe:lines() do
            specs[#specs + 1] = line
        end
        pipe:close()
    end
    table.sort(specs)
    return specs
end

local specs = discoverSpecs()
if #specs == 0 then
    print("No spec files found in tests/")
    os.exit(1)
end

for _, spec in ipairs(specs) do
    print("\n=== " .. spec .. " ===")
    local ok, err = pcall(dofile, spec)
    if not ok then
        stats.failed = stats.failed + 1
        stats.failures[#stats.failures + 1] = spec .. " (load): " .. tostring(err)
        print("  LOAD ERROR: " .. tostring(err))
    end
end

--------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------

print("\n----------------------------------------")
print(string.format("%d passed, %d failed, %d total",
    stats.passed, stats.failed, stats.passed + stats.failed))

if stats.failed > 0 then
    print("\nFailures:")
    for _, f in ipairs(stats.failures) do
        print("  - " .. f)
    end
    os.exit(1)
end

print("All tests passed.")
