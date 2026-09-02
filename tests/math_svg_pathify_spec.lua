package.path = package.path .. ";./plugins/markdownreader.koplugin/?.lua"
local MathSvgPathify = require("math_svg_pathify")

describe("MathSvgPathify", function()
    local svg  -- a minimal MicroTeX-style SVG with one \sum glyph and a <line>

    it("rewrites <text> glyphs into font-independent <path> outlines", function()
        local input = [[<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><text x="0" y="0" font-family="cmex10" font-size="1px" transform="matrix(32,0,0,32,100,50)" fill="rgb(0,0,0)" fill-opacity="1" style="white-space: pre;">&#80;</text></svg>]]
        local out = MathSvgPathify.convert(input)
        print("OUT IN BUSTED:", out)

        assert.is_falsy(out:find("<text", 1, true), "no <text> elements should remain")
        assert.is_truthy(out:find("<path ", 1, true), "a <path> element should be emitted")

        -- The \sum outline (U+2211) should be baked in as path data.
        assert.is_truthy(out:find('d="M', 1, true), "path should carry contour data")

        -- Transform must compose font-size/upm scale into the matrix. The sign of
        -- a zero component differs between LuaJIT and stock Lua, so assert the
        -- meaningful (non-zero) components rather than one exact string.
        assert.is_truthy(out:find("matrix(0.015625,", 1, true), "x-scale maps font units to device px")
        assert.is_truthy(out:find("-0.015625,", 1, true), "y-scale is flipped (SVG y-down)")
        assert.is_truthy(out:find("100.000000,50.000000", 1, true), "translate is preserved")
    end)

    it("preserves non-text geometry such as <line>", function()
        local input = [[<svg><text x="0" y="0" font-family="cmex10" font-size="1px" transform="matrix(1,0,0,1,0,0)" fill="rgb(0,0,0)" fill-opacity="1">&#80;</text><line x1="0" y1="0" x2="10" y2="0" stroke="rgb(0,0,0)" stroke-width="0.04"/></svg>]]
        local out = MathSvgPathify.convert(input)
        print("OUT IN BUSTED:", out)
        assert.is_truthy(out:find('<line x1="0" y1="0" x2="10" y2="0"', 1, true), "line must be kept")
    end)

    it("leaves unknown codepoints as <text> (graceful degradation)", function()
        local input = [[<svg><text x="0" y="0" font-family="cmex10" font-size="1px" transform="matrix(1,0,0,1,0,0)" fill="rgb(0,0,0)" fill-opacity="1">&#57344;</text></svg>]] -- U+E000, not in the glyph table
        local out = MathSvgPathify.convert(input)
        print("OUT IN BUSTED:", out)
        assert.is_truthy(out:find("<text", 1, true), "unknown codepoint should stay as text")
        assert.is_falsy(out:find("<path ", 1, true), "no path should be emitted for unknown glyphs")
    end)

    it("leaves multi-codepoint <text> elements unchanged (no silent char loss)", function()
        -- SvgGraphics2D drawText() emits several &#cp; refs inside ONE <text>.
        -- Replacing that element with a single path would drop every char but
        -- the first, so the converter must refuse and keep the <text> as-is.
        local input = [[<svg><text x="0" y="0" font-family="cmex10" font-size="1px" transform="matrix(1,0,0,1,0,0)" fill="rgb(0,0,0)" fill-opacity="1">&#945;&#768;</text></svg>]]
        local out = MathSvgPathify.convert(input)
        print("OUT IN BUSTED:", out)
        assert.is_truthy(out:find("<text", 1, true), "multi-codepoint text must stay as <text>")
        assert.is_falsy(out:find("<path ", 1, true), "no partial conversion allowed")
    end)

    it("folds non-zero x/y text position into the path translate", function()
        -- <text x="5" y="7" ... transform="matrix(1,0,0,1,10,20)"> must place
        -- the glyph at (10+5, 20+7), not drop the x/y offset.
        local input = [[<svg><text x="5" y="7" font-family="cmex10" font-size="1px" transform="matrix(1,0,0,1,10,20)" fill="rgb(0,0,0)" fill-opacity="1">&#80;</text></svg>]]
        local out = MathSvgPathify.convert(input)
        print("OUT IN BUSTED:", out)
        assert.is_truthy(out:find("15.000000,27.000000", 1, true), "e,f must gain a*x+c*y / b*x+d*y terms")
    end)

    it("returns the input unchanged when it is nil", function()
        assert.is_nil(MathSvgPathify.convert(nil))
    end)
end)
