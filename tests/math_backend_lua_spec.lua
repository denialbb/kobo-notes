package.path = package.path .. ";./plugins/markdownreader.koplugin/?.lua"
local MathBackendLua = require("math_backend_lua")

local be = MathBackendLua.new()

local function html(src, block)
    local res = be:render(src, block == nil and true or block)
    assert.is_not_nil(res, "nil result for: " .. src)
    assert.are.equal("html", res.kind)
    return res.html
end

local function isRendered(src, block)
    local h = html(src, block)
    assert.is_falsy(h:find("mathsrc", 1, true), "degraded to source: " .. src)
    return h
end

--- No leftover alignment/row markup may reach the reader.
local function assertClean(h, src)
    assert.is_falsy(h:find("&amp;", 1, true), "raw & leaked in: " .. tostring(src))
    -- an ampersand may only ever appear as the start of an entity
    for m in h:gmatch("&([%a#]*)") do
        assert.is_truthy(m:match("^%a+$") or m:match("^#%d+$"),
            "bare & in output for: " .. tostring(src))
    end
    assert.is_falsy(h:find("\\\\", 1, true), "literal \\\\ leaked in: " .. tostring(src))
end

describe("MathBackendLua accents", function()
    it("renders \\underline as an underlined span", function()
        local h = isRendered("\\underline{GC}")
        assert.is_truthy(h:find("text%-decoration: underline"))
        assert.is_truthy(h:find("GC", 1, true))
    end)

    it("renders \\overline with an overline decoration", function()
        local h = isRendered("\\overline{AB}")
        assert.is_truthy(h:find("text%-decoration: overline"))
        assert.is_truthy(h:find("AB", 1, true))
    end)

    it("renders \\underline over nested math", function()
        local h = isRendered("\\underline{\\mathrm{GC}}")
        assert.is_truthy(h:find("text%-decoration: underline"))
        assert.is_truthy(h:find("GC", 1, true))
    end)

    it("no longer mangles \\hat{x} into literal text", function()
        local h = isRendered("\\hat{x}")
        assert.is_falsy(h:find("hatx", 1, true))
        assert.is_falsy(h:find("\\hat", 1, true))
        assert.is_truthy(h:find("x", 1, true))
        assert.is_truthy(h:find("\204\130", 1, true))   -- combining circumflex
    end)

    it("renders \\bar, \\vec, \\tilde and \\widehat with combining marks", function()
        for _, p in ipairs({
            { "\\bar{y}",     "\204\132" },
            { "\\vec{v}",     "\226\131\151" },
            { "\\tilde{z}",   "\204\131" },
            { "\\widehat{w}", "\204\130" },
        }) do
            local h = isRendered(p[1])
            assert.is_truthy(h:find(p[2], 1, true), "missing accent for " .. p[1])
        end
    end)
end)

describe("MathBackendLua environments", function()
    local ENVS = {
        "\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}",
        "\\begin{align} a &= b \\\\ c &= d \\end{align}",
        "\\begin{align*} a &= b \\\\ c &= d \\end{align*}",
        "\\begin{gather} a \\\\ b \\end{gather}",
        "\\begin{gathered} a \\\\ b \\end{gathered}",
        "\\begin{cases} x & y \\\\ z & w \\end{cases}",
        "\\begin{matrix} 1 & 0 \\\\ 0 & 1 \\end{matrix}",
        "\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}",
        "\\begin{bmatrix} 1 & 0 \\\\ 0 & 1 \\end{bmatrix}",
        "\\begin{array}{ll} a & b \\\\ c & d \\end{array}",
        "\\begin{split} a &= b \\\\ &= c \\end{split}",
        "\\begin{eqnarray} a &=& b \\end{eqnarray}",
    }

    it("renders every supported environment instead of degrading", function()
        for _, src in ipairs(ENVS) do
            local h = isRendered(src)
            assert.is_truthy(h:find("display: block", 1, true),
                "no row blocks for " .. src)
        end
    end)

    it("never emits a <div> (output lives inside a <p>)", function()
        for _, src in ipairs(ENVS) do
            assert.is_falsy(html(src):find("<div", 1, true), "div emitted for " .. src)
        end
    end)

    it("never leaks a raw & or \\\\ into the output", function()
        for _, src in ipairs(ENVS) do
            assertClean(html(src), src)
        end
    end)

    it("splits rows into separate blocks", function()
        local h = isRendered("\\begin{gather} a \\\\ b \\\\ c \\end{gather}")
        local n = 0
        for _ in h:gmatch("display: block") do n = n + 1 end
        assert.are.equal(4, n)      -- outer mathblock + three rows
    end)

    it("wraps pmatrix in parentheses and bmatrix in brackets", function()
        assert.is_truthy(html("\\begin{pmatrix} 1 \\end{pmatrix}"):find("(", 1, true))
        assert.is_truthy(html("\\begin{bmatrix} 1 \\end{bmatrix}"):find("[", 1, true))
    end)

    it("gives cases a leading brace", function()
        assert.is_truthy(html("\\begin{cases} a \\\\ b \\end{cases}"):find("{", 1, true))
    end)

    it("parses and discards the array column spec", function()
        for _, spec in ipairs({ "{ll}", "{c|c}", "{@{}rcl@{}}" }) do
            local h = isRendered("\\begin{array}" .. spec .. " a & b \\end{array}")
            assert.is_falsy(h:find("|", 1, true), "column spec leaked: " .. spec)
            assert.is_falsy(h:find("ll", 1, true))
        end
    end)

    it("renders nested math inside rows", function()
        local h = isRendered(
            "\\begin{aligned} \\sum_{f=1}^{m} y_f &\\le \\frac{a}{b} \\end{aligned}")
        assert.is_truthy(h:find("\226\136\145", 1, true))   -- sum
        assert.is_truthy(h:find("<sub>f=1</sub>", 1, true))
        assert.is_truthy(h:find("<sup>m</sup>", 1, true))
        assert.is_truthy(h:find("mathfrac", 1, true))
        assert.is_truthy(h:find("\226\137\164", 1, true))   -- leq
    end)

    it("handles a nested environment inside a row", function()
        local h = isRendered(
            "\\begin{aligned} a &= \\begin{cases} 1 \\\\ 2 \\end{cases} \\\\ b &= c \\end{aligned}")
        assertClean(h)
        assert.is_truthy(h:find("c", 1, true))
    end)

    it("treats && as a single separator", function()
        local h = isRendered("\\begin{aligned} a && b \\end{aligned}")
        assertClean(h)
    end)

    it("still degrades an unknown environment to source", function()
        local h = html("\\begin{tikzpicture} \\draw (0,0); \\end{tikzpicture}")
        assert.is_truthy(h:find("mathsrc", 1, true))
        assert.is_truthy(h:find("monospace", 1, true))
    end)

    it("escapes HTML entities inside environments", function()
        local h = isRendered("\\begin{aligned} a < b & c > d \\end{aligned}")
        assert.is_truthy(h:find("&lt;", 1, true))
        assert.is_truthy(h:find("&gt;", 1, true))
        assert.is_falsy(h:find("a < b", 1, true))
    end)

    it("renders prose and an environment in the same formula", function()
        local src = [[(\underline{\mathrm{GC}}) \qquad
\begin{aligned}
\min \;& \sum_{f=1}^{m} y_f \\
& \sum_{f=1}^{m} x_{if} = 1 && i = 1,\dots,n \\
& x_{if} + x_{jf} \le 1 && (i,j) \in A,\; f = 1,\dots,m \\
& y_f \ge x_{if} \ge 0 && i = 1,\dots,n,\; f = 1,\dots,m \\
& 1 \ge y_f \ge 0 && f = 1,\dots,m
\end{aligned}]]
        local h = isRendered(src)
        assertClean(h, "real-world example")
        assert.is_truthy(h:find("text%-decoration: underline"))
        assert.is_truthy(h:find("GC", 1, true))
        assert.is_truthy(h:find("\226\136\145", 1, true))    -- sum
        assert.is_truthy(h:find("\226\137\164", 1, true))    -- le
        assert.is_truthy(h:find("\226\137\165", 1, true))    -- ge
        assert.is_truthy(h:find("\226\136\136", 1, true))    -- in
        assert.is_falsy(h:find("<div", 1, true))
        -- five aligned rows plus the outer block
        local n = 0
        for _ in h:gmatch("display: block") do n = n + 1 end
        assert.are.equal(6, n)
    end)
end)

describe("MathBackendLua robustness", function()
    it("never raises and never returns nil for malformed environments", function()
        for _, src in ipairs({
            "\\begin{aligned}",
            "\\end{aligned}",
            "\\begin{aligned} a \\\\ \\end{align}",
            "\\begin{pmatrix} 1 & \\end{pmatrix} \\end{pmatrix}",
            "\\begin",
            "\\begin{}",
            "a \\\\ b",
            "a & b",
            "\\underline{",
            "\\underline",
            "\\begin{cases}\\begin{cases}x\\end{cases}",
        }) do
            local res
            assert.has_no_error(function() res = be:render(src, true) end,
                "raised for: " .. src)
            assert.is_not_nil(res, "nil for: " .. src)
            assert.are.equal("html", res.kind)
        end
    end)

    it("renders a bare \\\\ as a line break rather than degrading", function()
        local h = isRendered("a \\\\ b")
        assert.is_truthy(h:find("<br/>", 1, true))
        assertClean(h)
    end)

    it("renders a bare & as a gap rather than an ampersand", function()
        assertClean(isRendered("a & b"))
    end)

    it("isUnsupported only rejects genuinely unknown constructs", function()
        assert.is_false(MathBackendLua.isUnsupported("\\begin{aligned} a \\\\ b \\end{aligned}"))
        assert.is_false(MathBackendLua.isUnsupported("a & b \\\\ c"))
        assert.is_false(MathBackendLua.isUnsupported("\\underline{x}"))
        assert.is_true(MathBackendLua.isUnsupported("\\begin{tikzpicture}\\end{tikzpicture}"))
    end)
end)

--- Every rendered formula must be free of leftover backslash commands.
local function assertNoCommands(h, src)
    local leftover = h:match("\\%a+")
    assert.is_nil(leftover, "unrendered command " .. tostring(leftover)
        .. " for: " .. tostring(src))
end

local function clean(src)
    local h = isRendered(src)
    assertClean(h, src)
    assertNoCommands(h, src)
    return h
end

describe("MathBackendLua argument gluing", function()
    it("renders \\boxed{z} without gluing the argument onto the name", function()
        local h = clean("\\boxed{z(\\mathrm{PC}) = 5}")
        assert.is_falsy(h:find("boxedz", 1, true))
        assert.is_truthy(h:find("border", 1, true))
    end)

    it("never glues an argument onto an unknown command", function()
        local h = html("\\frobnicate{z}")
        assert.is_falsy(h:find("frobnicatez", 1, true))
        -- the argument is still shown
        assert.is_truthy(h:find("z", 1, true))
    end)

    it("renders \\textbf variants as styled text, not \\textbfedge", function()
        for cmd, needle in pairs({
            textbf = "bold", textit = "italic", texttt = "monospace",
            textsf = "normal", textrm = "normal",
        }) do
            local h = clean("\\" .. cmd .. "{edge}")
            assert.is_falsy(h:find(cmd .. "edge", 1, true))
            assert.is_truthy(h:find("edge", 1, true))
            assert.is_truthy(h:find(needle, 1, true), cmd .. " missing " .. needle)
        end
    end)

    it("renders \\operatorname upright without gluing", function()
        local h = clean("\\operatorname{rank}(A) = m")
        assert.is_falsy(h:find("operatornamerank", 1, true))
        assert.is_truthy(h:find("rank", 1, true))
    end)

    it("renders \\substack as stacked lines", function()
        local h = clean("\\substack{x \\\\ y}")
        assert.is_falsy(h:find("substackx", 1, true))
        assert.is_truthy(h:find("display: block", 1, true))
    end)
end)

describe("MathBackendLua sizing delimiters", function()
    it("drops the sizing prefix and keeps the delimiter", function()
        for _, cmd in ipairs({
            "Bigl", "Bigr", "bigl", "bigr", "Big", "big", "Bigg", "bigg",
            "Biggl", "Biggr", "biggl", "biggr",
        }) do
            local h = clean("\\" .. cmd .. "( a \\" .. cmd .. ") ")
            assert.is_truthy(h:find("(", 1, true) or h:find(")", 1, true),
                "delimiter lost for \\" .. cmd)
        end
    end)

    it("drops \\middle and keeps its delimiter", function()
        local h = clean("\\left\\{ a \\middle| b \\right\\}")
        assert.is_truthy(h:find("|", 1, true))
    end)
end)

describe("MathBackendLua added symbols", function()
    it("maps the newly required symbols to unicode", function()
        local cases = {
            square = "\226\150\161", mid = "\226\136\163",
            lvert = "|", rvert = "|",
            diamond = "\226\139\132", odot = "\226\138\153",
            longrightarrow = "\226\159\182",
            Longrightarrow = "\226\159\185",
            Longleftrightarrow = "\226\159\186",
            gtrsim = "\226\137\179",
            nearrow = "\226\134\151", searrow = "\226\134\152",
        }
        for cmd, glyph in pairs(cases) do
            local h = clean("\\" .. cmd)
            assert.is_truthy(h:find(glyph, 1, true), "missing glyph for \\" .. cmd)
        end
    end)

    it("renders \\bmod as an upright mod", function()
        local h = clean("H \\bmod 2\\pi")
        assert.is_truthy(h:find("mod", 1, true))
        assert.is_truthy(h:find("font-style: normal", 1, true))
    end)

    it("renders \\mathrel by rendering its argument", function()
        local h = clean("H\\mathrel{*}=60")
        assert.is_truthy(h:find("*", 1, true))
    end)

    it("renders \\not as a combining overlay on the next symbol", function()
        local h = clean("A \\not\\ge 0")
        assert.is_truthy(h:find("\204\184", 1, true))
        assert.is_truthy(h:find("\226\137\165", 1, true))
    end)
end)

describe("MathBackendLua structural commands", function()
    it("drops \\tag and its argument", function()
        local h = clean("x = 1 \\tag{6.6}")
        assert.is_falsy(h:find("6.6", 1, true))
        assert.is_truthy(h:find("x", 1, true))
    end)

    it("drops \\phantom and its argument", function()
        local h = clean("a \\phantom{bcd} e")
        assert.is_falsy(h:find("bcd", 1, true))
    end)

    it("drops \\hline inside an array", function()
        local h = clean("\\begin{array}{cc} a & b \\\\ \\hline c & d \\end{array}")
        assert.is_truthy(h:find("a", 1, true))
    end)

    it("renders \\underbrace{x}_{y} as x with y subscripted", function()
        local h = clean("\\underbrace{x+z}_{y}")
        assert.is_truthy(h:find("<sub>", 1, true))
        assert.is_truthy(h:find("y", 1, true))
    end)

    it("renders \\binom as a stacked pair in parentheses", function()
        local h = clean("\\binom{6}{1}=6")
        assert.is_truthy(h:find("6", 1, true))
        assert.is_truthy(h:find("1", 1, true))
        assert.is_truthy(h:find("(", 1, true))
    end)
end)

describe("MathBackendLua corpus regressions", function()
    it("renders the real-world formulas that used to leak commands", function()
        for _, src in ipairs({
            "\\boxed{\\; z = G^{-1}\\big(T(r)\\big) = G^{-1}(s) \\;}",
            "\\mathbf{w} - \\eta\\Bigl(\\underbrace{\\nabla L}_{\\text{cur}}\\Bigr)",
            "f(x) \\;\\longrightarrow\\; \\textbf{LUT} \\;\\longrightarrow\\; \\textbf{noise}",
            "\\max_j \\lvert r_j - a_j\\rvert \\le W/2",
            "g'(z) = g(z)\\,\\bigl(1 - g(z)\\bigr).",
            "F_k(s) = \\max\\left\\{ \\sum_i p_i \\;\\middle|\\; w \\le s \\right\\}",
            "\\begin{array}{c|cc} c & 1 & 2 \\\\ \\hline 1 & - & 3 \\end{array}",
            "\\textbf{Quantization:} \\qquad \\text{C} \\nearrow \\quad \\Longleftrightarrow \\quad \\text{Q} \\searrow",
            "\\sum_{\\substack{x \\\\ y}} z",
            "A_B^{-1} b \\not\\ge 0",
            "(P) \\qquad \\max\\{\\, cx \\;:\\; Ax \\le b \\,\\} \\tag{6.6}",
        }) do
            clean(src)
        end
    end)

    it("emits no <div> for any of the new constructs", function()
        for _, src in ipairs({
            "\\boxed{x}", "\\substack{a \\\\ b}", "\\binom{n}{k}",
            "\\underbrace{x}_{y}", "\\Bigl( x \\Bigr)",
        }) do
            assert.is_falsy(html(src, true):find("<div", 1, true), src)
            assert.is_falsy(html(src, false):find("<div", 1, true), src)
        end
    end)

    it("never raises on truncated forms of the new commands", function()
        for _, src in ipairs({
            "\\boxed", "\\boxed{", "\\binom{n}", "\\binom", "\\substack",
            "\\tag", "\\phantom", "\\not", "\\textbf", "\\operatorname",
            "\\Bigl", "\\middle", "\\mathrel", "\\underbrace",
        }) do
            local res
            assert.has_no_error(function() res = be:render(src, true) end,
                "raised for: " .. src)
            assert.is_not_nil(res, "nil for: " .. src)
        end
    end)
end)
