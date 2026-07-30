_G.describe = function(name, fn) 
    print("Suite: " .. name)
    fn() 
end
_G.it = function(name, fn) 
    print("  Test: " .. name)
    if _G._before_each then _G._before_each() end
    fn() 
end
_G.before_each = function(fn) 
    _G._before_each = fn 
end

local original_assert = assert
_G.assert = setmetatable({
    is_true = function(v) if v ~= true then error("expected true") end end,
    is_truthy = function(v) if not v then error("expected truthy") end end,
    is_falsy = function(v) if v then error("expected falsy") end end,
    is_not_nil = function(v) if v == nil then error("expected not nil") end end,
    are = {
        equal = function(a, b) if a ~= b then error("expected " .. tostring(a) .. " == " .. tostring(b)) end end
    }
}, {
    __call = function(_, v, msg) return original_assert(v, msg) end
})

package.path = package.path .. ";./plugins/markdownreader.koplugin/?.lua"

package.preload["ffi"] = function()
    return {
        load = function() return {} end,
        cdef = function() end,
        typeof = function() return {} end,
        new = function() return {} end,
        cast = function() return {} end,
        C = {},
    }
end

package.preload["logger"] = function()
    return {
        info = function(...) print("LOG [info]:", ...) end,
        warn = function(...) print("LOG [warn]:", ...) end,
        err = function(...) print("LOG [error]:", ...) end,
        dbg = function(...) end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        mkdir = function(p) os.execute("mkdir -p " .. p) end,
        attributes = function(p) return nil end,
        dir = function(p) return nil end,
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
    local InfoMessageMock = {
        new = function(_, opts)
            return {
                text = opts.text,
                timeout = opts.timeout,
                movable = { dimen = { x = 0, y = 0, w = 100, h = 50 } },
            }
        end,
    }
    return InfoMessageMock
end

-- Mock MathRenderer for host-side testing (no FFI available)
-- NOTE: called with `:`, so first arg is self
package.preload["math_renderer"] = function()
    return {
        init = function() end,
        render_latex = function(self, latex_str, output_path)
            local f = io.open(output_path, "w")
            if f then
                f:write("<svg><text>Mocked</text></svg>")
                f:close()
            end
            return true
        end,
    }
end

dofile("tests/math_renderer_spec.lua")
dofile("tests/markdown_interceptor_spec.lua")
print("All tests passed.")
