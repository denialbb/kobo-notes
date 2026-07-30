package.path = package.path .. ";./plugins/markdownreader.koplugin/?.lua"
local MathRenderer   = require("math_renderer")
local MathBackendLua = require("math_backend_lua")

describe("MathRenderer.hash", function()
    it("is deterministic for the same input", function()
        assert.are.equal(MathRenderer.hash("x^2"), MathRenderer.hash("x^2"))
    end)

    it("produces 8 hex characters", function()
        local h = MathRenderer.hash("\\frac{a}{b}")
        assert.are.equal(8, #h)
        assert.is_truthy(h:match("^%x%x%x%x%x%x%x%x$"))
    end)

    it("differs for different input", function()
        assert.are.not_equal(MathRenderer.hash("x^2"), MathRenderer.hash("x^3"))
    end)

    it("handles the empty string without erroring", function()
        assert.has_no_error(function() MathRenderer.hash("") end)
    end)
end)

describe("MathRenderer.cacheKey", function()
    it("is stable across calls", function()
        assert.are.equal(
            MathRenderer.cacheKey("lua", "x^2", false),
            MathRenderer.cacheKey("lua", "x^2", false))
    end)

    it("distinguishes inline from block", function()
        assert.are.not_equal(
            MathRenderer.cacheKey("lua", "x^2", false),
            MathRenderer.cacheKey("lua", "x^2", true))
    end)

    it("distinguishes backends", function()
        assert.are.not_equal(
            MathRenderer.cacheKey("lua", "x^2", false),
            MathRenderer.cacheKey("microtex", "x^2", false))
    end)
end)

describe("MathRenderer backend selection", function()
    it("defaults to the pure-Lua backend", function()
        local r = MathRenderer.new()
        assert.are.equal("lua", r.backend_id)
    end)

    it("honours an explicitly requested available backend", function()
        local r = MathRenderer.new{ backend = "lua" }
        assert.are.equal("lua", r.backend_id)
    end)

    it("falls back to Lua when the requested backend does not exist", function()
        local r = MathRenderer.new{ backend = "definitely-not-a-backend" }
        assert.are.equal("lua", r.backend_id)
        assert.is_not_nil(r.fallback_reason)
    end)

    it("falls back to Lua when a native backend is unavailable", function()
        -- 'microtex' is registered but its module does not exist: this is the
        -- exact "no .so on the device" case, and it must never raise.
        assert.has_no_error(function() MathRenderer.new{ backend = "microtex" } end)
        local r = MathRenderer.new{ backend = "microtex" }
        assert.are.equal("lua", r.backend_id)
    end)

    it("allows registering a new backend without touching the facade", function()
        MathRenderer.registerBackend("fake", {
            id = "fake",
            isAvailable = function() return true end,
            new = function()
                return { render = function() return { kind = "html", html = "<b>fake</b>" } end }
            end,
        })
        local r = MathRenderer.new{ backend = "fake" }
        assert.are.equal("fake", r.backend_id)
        local res = r:render("x", false)
        assert.are.equal("<b>fake</b>", res.html)
    end)

    it("falls back when a registered backend reports itself unavailable", function()
        MathRenderer.registerBackend("broken", {
            id = "broken",
            isAvailable = function() return false end,
            new = function() return {} end,
        })
        local r = MathRenderer.new{ backend = "broken" }
        assert.are.equal("lua", r.backend_id)
    end)

    it("lists registered backends", function()
        local names = MathRenderer.listBackends()
        local found = false
        for _, n in ipairs(names) do if n == "lua" then found = true end end
        assert.is_true(found)
    end)
end)

describe("MathRenderer:render", function()
    it("returns an html result from the Lua backend", function()
        local r = MathRenderer.new()
        local res = r:render("x^2", false)
        assert.is_not_nil(res)
        assert.are.equal("html", res.kind)
        assert.is_truthy(res.html:match("<sup>2</sup>"))
    end)

    it("rejects empty input", function()
        local r = MathRenderer.new()
        local res, err = r:render("   ", false)
        assert.is_nil(res)
        assert.is_not_nil(err)
    end)

    it("never raises on a backend that throws", function()
        MathRenderer.registerBackend("throwing", {
            id = "throwing",
            isAvailable = function() return true end,
            new = function() return { render = function() error("boom") end } end,
        })
        local r = MathRenderer.new{ backend = "throwing" }
        local res, err
        assert.has_no_error(function() res, err = r:render("x", false) end)
        assert.is_nil(res)
        assert.is_not_nil(err)
    end)
end)

describe("MathRenderer caching", function()
    it("returns the identical result table on a cache hit", function()
        local r = MathRenderer.new()
        local a = r:render("a+b", false)
        local b = r:render("a+b", false)
        assert.are.equal(a, b)          -- same table identity
        assert.are.equal(1, r.stats.misses)
        assert.are.equal(1, r.stats.hits)
    end)

    it("only invokes the backend once per distinct formula", function()
        local calls = 0
        MathRenderer.registerBackend("counting", {
            id = "counting",
            isAvailable = function() return true end,
            new = function()
                return { render = function(_, latex)
                    calls = calls + 1
                    return { kind = "html", html = latex }
                end }
            end,
        })
        local r = MathRenderer.new{ backend = "counting" }
        r:render("q", false)
        r:render("q", false)
        r:render("q", false)
        assert.are.equal(1, calls)
        r:render("q", true)             -- block variant is a different key
        assert.are.equal(2, calls)
    end)

    it("separates the cache between renderer instances", function()
        local r1 = MathRenderer.new()
        local r2 = MathRenderer.new()
        r1:render("z", false)
        assert.are.equal(0, r2.stats.hits)
    end)

    it("clearCache forces a re-render", function()
        local r = MathRenderer.new()
        r:render("w", false)
        r:clearCache()
        r:render("w", false)
        assert.are.equal(2, r.stats.misses)
    end)

    it("builds a cache path under the configured cache dir", function()
        local r = MathRenderer.new{ cache_dir = "/some/cache/dir" }
        local p = r:cachePath("abcd1234", "svg")
        assert.is_truthy(p:match("^/some/cache/dir/math_abcd1234%.svg$"))
    end)

    it("returns no cache path when no cache dir was configured", function()
        local r = MathRenderer.new()
        assert.is_nil(r:cachePath("abcd1234", "svg"))
    end)
end)

describe("MathBackendLua", function()
    local be
    before_each(function() be = MathBackendLua.new() end)

    it("is always available", function()
        assert.is_true(MathBackendLua.isAvailable())
    end)

    it("renders superscripts and subscripts", function()
        assert.is_truthy(be:render("x^2", false).html:match("<sup>2</sup>"))
        assert.is_truthy(be:render("a_i", false).html:match("<sub>i</sub>"))
        assert.is_truthy(be:render("x^{10}", false).html:match("<sup>10</sup>"))
    end)

    it("maps greek letters and symbols to unicode", function()
        local h = be:render("\\alpha \\leq \\infty", false).html
        assert.is_truthy(h:find("α", 1, true))
        assert.is_truthy(h:find("≤", 1, true))
        assert.is_truthy(h:find("∞", 1, true))
        assert.is_falsy(h:find("\\alpha", 1, true))
    end)

    it("maps the remaining required symbols", function()
        local pairs_to_check = {
            { "\\sum", "∑" }, { "\\int", "∫" }, { "\\in", "∈" },
            { "\\geq", "≥" }, { "\\neq", "≠" }, { "\\times", "×" },
            { "\\cdot", "⋅" }, { "\\rightarrow", "→" }, { "\\partial", "∂" },
        }
        for _, p in ipairs(pairs_to_check) do
            local h = be:render(p[1], false).html
            assert.is_truthy(h:find(p[2], 1, true), "missing mapping for " .. p[1])
        end
    end)

    it("renders \\frac as a fraction span", function()
        local h = be:render("\\frac{a}{b}", false).html
        assert.is_truthy(h:match("mathfrac"))
        assert.is_truthy(h:find("a", 1, true))
        assert.is_truthy(h:find("b", 1, true))
    end)

    it("renders \\text upright", function()
        local h = be:render("\\text{if } x", false).html
        assert.is_truthy(h:find("if", 1, true))
    end)

    it("styles \\mathbb and \\mathbf", function()
        assert.is_truthy(be:render("\\mathbb{R}", false).html:match("font%-weight: bold"))
        assert.is_truthy(be:render("\\mathbf{v}", false).html:match("font%-weight: bold"))
    end)

    it("escapes HTML entities in the source", function()
        local h = be:render("a < b", false).html
        assert.is_truthy(h:find("&lt;", 1, true))
        assert.is_falsy(h:find("a < b", 1, true))
    end)

    it("escapes HTML entities in the unsupported fallback", function()
        local h = be:render("\\begin{weirdenv} a<b & c \\end{weirdenv}", true).html
        assert.is_truthy(h:find("&lt;", 1, true))
        assert.is_truthy(h:find("&amp;", 1, true))
    end)

    it("falls back to monospace source for unknown environments", function()
        for _, src in ipairs({
            "\\begin{tikzpicture} x \\end{tikzpicture}",
            "\\begin{nosuchenv} a &= b \\end{nosuchenv}",
        }) do
            local res = be:render(src, true)
            assert.is_not_nil(res)
            assert.are.equal("html", res.kind)
            assert.is_truthy(res.html:match("monospace"), "expected monospace fallback for " .. src)
        end
    end)

    it("never returns nil for valid-looking input", function()
        for _, src in ipairs({
            "x", "\\unknowncommand{y}", "\\begin{foo}bar\\end{foo}",
            "{{{unbalanced", "a^", "_", "\\", "100%", "$",
        }) do
            local res = be:render(src, false)
            assert.is_not_nil(res, "returned nil for: " .. src)
            assert.are.equal("html", res.kind)
        end
    end)

    it("returns nil only for empty input", function()
        assert.is_nil(be:render("", false))
        assert.is_nil(be:render("   \n  ", false))
    end)

    it("marks block math as display block", function()
        assert.is_truthy(be:render("x", true).html:match("display: block"))
        assert.is_falsy(be:render("x", false).html:match("display: block"))
    end)
end)
