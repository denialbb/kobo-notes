package.path = package.path .. ";./plugins/markdownreader.koplugin/?.lua"
local MathSvgHarden = require("math_svg_harden")
local MathValidator = require("math_validator")

describe("MathSvgHarden", function()
    it("parses and expands SVG viewBox with margins", function()
        local svg = '<svg width="100" height="50" viewBox="0 0 100 50"><path d="M0 0"/></svg>'
        local hardened = MathSvgHarden.padViewBox(svg, 4, 2)
        assert.is_truthy(hardened:find('viewBox="%-4%.000 %-2%.000 108%.000 54%.000"'), "viewBox should be padded by 4px horizontal, 2px vertical")
        assert.is_truthy(hardened:find('width="108%.000"'))
        assert.is_truthy(hardened:find('height="54%.000"'))
    end)

    it("synthesizes viewBox when missing if dimensions are present", function()
        local svg = '<svg width="80" height="40"><line x1="0" y1="0" x2="80" y2="40"/></svg>'
        local hardened = MathSvgHarden.padViewBox(svg, 5, 5)
        assert.is_truthy(hardened:find('viewBox="%-5%.000 %-5%.000 90%.000 50%.000"'))
    end)

    it("composes pathification and padding in harden()", function()
        local svg = '<svg width="100" height="50" viewBox="0 0 100 50"><text x="0" y="0" font-family="cmex10" font-size="1px" transform="matrix(32,0,0,32,100,50)">&#80;</text></svg>'
        local res = MathSvgHarden.harden(svg, { pad_x = 4, pad_y = 2 })
        assert.is_falsy(res:find("<text", 1, true), "text should be rewritten into path")
        assert.is_truthy(res:find("<path ", 1, true))
        assert.is_truthy(res:find('viewBox="%-4%.000 %-2%.000 108%.000 54%.000"'))
    end)
end)

describe("MathValidator", function()
    it("validates a proper hardened SVG with zero errors", function()
        local svg = '<svg width="108" height="54" viewBox="-4 -2 108 54"><path d="M10 10 L50 50"/></svg>'
        local res = MathValidator.analyze(svg, "x + y")
        assert.is_true(res.valid)
        assert.are.equal(0, #res.defects)
        assert.are.equal(1, res.metrics.element_count)
    end)

    it("detects unpathified <text> elements as defects", function()
        local svg = '<svg width="100" height="50" viewBox="0 0 100 50"><text font-family="unknown">&#9999;</text></svg>'
        local res = MathValidator.analyze(svg, "\\unknown")
        assert.is_false(res.valid)
        assert.is_truthy(#res.defects > 0)
        assert.are.equal("UNRESOLVED_TEXT_ELEMENTS", res.defects[1].code)
    end)

    it("flags empty or corrupt SVG markup", function()
        local res1 = MathValidator.analyze("", "empty")
        assert.is_false(res1.valid)
        assert.are.equal("EMPTY_SVG", res1.defects[1].code)

        local res2 = MathValidator.analyze("<svg>unclosed", "bad")
        assert.is_false(res2.valid)
        assert.are.equal("MALFORMED_ROOT", res2.defects[1].code)
    end)

    it("formats a diagnosis string clearly for agents and logs", function()
        local svg = '<svg width="100" height="50"><text>foo</text></svg>'
        local res = MathValidator.analyze(svg, "\\test")
        local diag = MathValidator.formatDiagnosis(res)
        assert.is_truthy(diag:find("LaTeX: \\test", 1, true))
        assert.is_truthy(diag:find("DEFECTS DETECTED", 1, true))
    end)
end)
