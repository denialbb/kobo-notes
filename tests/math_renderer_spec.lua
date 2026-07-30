package.path = package.path .. ";./plugins/markdownreader.koplugin/?.lua"
local MathRenderer = require("math_renderer")

describe("MathRenderer", function()
    it("should load the library and render math", function()
        -- Ensure cache is clear
        os.execute("rm -f /tmp/test_math.svg")
        
        MathRenderer:init("./plugins/markdownreader.koplugin/libmicrotex.so")
        local success = MathRenderer:render_latex("x^2", "/tmp/test_math.svg")
        
        assert.is_true(success)
        
        local f = io.open("/tmp/test_math.svg", "r")
        assert.is_not_nil(f)
        local content = f:read("*all")
        f:close()
        
        assert.are.equal("<svg><text>Mocked</text></svg>", content)
    end)
end)
