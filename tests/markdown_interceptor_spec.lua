package.path = package.path .. ";./plugins/markdownreader.koplugin/?.lua"
local MarkdownInterceptor = require("markdown_interceptor")

--- Counts the substitutions of a given kind.
local function countBlocks(subs)
    local n = 0
    for _, s in ipairs(subs) do if s.block then n = n + 1 end end
    return n
end

describe("MarkdownInterceptor", function()
    local mi

    before_each(function()
        mi = MarkdownInterceptor.new{ cache_dir = "/tmp/kobo-notes-test-cache" }
    end)

    ----------------------------------------------------------------------
    -- Basic extraction (token/substitution contract)
    ----------------------------------------------------------------------

    it("replaces block math with a placeholder token", function()
        local input = "Here is some math:\n\n$$a^2 + b^2 = c^2$$\n\nNeat."
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.is_true(subs[1].block)
        assert.are.equal("a^2 + b^2 = c^2", subs[1].latex)
        assert.is_truthy(out:find(subs[1].token, 1, true), "token missing from output")
        assert.is_falsy(out:match("%$%$"), "delimiters should be gone")
    end)

    it("replaces inline math with a placeholder token", function()
        local input = "The value of $x$ is 5."
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.is_false(subs[1].block)
        assert.are.equal("x", subs[1].latex)
        assert.is_truthy(out:find(subs[1].token, 1, true))
        assert.is_falsy(out:match("%$x%$"))
    end)

    it("preserves the surrounding prose exactly", function()
        local input = "The value of $x$ is 5."
        local out, subs = mi:process(input)
        local restored = out:gsub(subs[1].token, "$x$")
        assert.are.equal(input, restored)
    end)

    ----------------------------------------------------------------------
    -- Structural cases preserved from the original suite
    ----------------------------------------------------------------------

    it("handles multi-line block math ($$ on separate lines)", function()
        local input = "Multi-line equation:\n\n$$\na^2 + b^2 = c^2\n$$\n\nEnd."
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.is_true(subs[1].block)
        assert.is_falsy(out:match("%$%$"), "expected no $$ delimiters, got: " .. out)
        assert.is_truthy(subs[1].latex:find("a^2", 1, true))
    end)

    it("handles complex multi-line block math (cases/aligned)", function()
        local input = "Cases:\n\n$$\n\\begin{cases}\n  x &\\text{if } y\\\\\n"
            .. "  z &\\text{otherwise}\n\\end{cases}\n$$\n\nDone."
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.is_true(subs[1].block)
        assert.is_falsy(out:match("%$%$"))
        -- The Lua backend now renders `cases` as a stack of rows.
        assert.is_falsy(subs[1].html:match("monospace"))
        assert.is_falsy(subs[1].html:find("begin{cases}", 1, true))
        assert.is_truthy(subs[1].html:find("display: block", 1, true))
        assert.is_truthy(subs[1].html:find("if", 1, true))
        assert.is_truthy(subs[1].html:find("otherwise", 1, true))
    end)

    it("handles mixed inline and multi-line block math", function()
        local input = "Let $G = (N, A)$ be our graph. Then:\n\n$$\n"
            .. "\\sum_{e \\in A} w_e x_e\n$$\n\nwhere $w_e > 0$."
        local out, subs = mi:process(input)
        assert.are.equal(3, #subs, "expected 3 math spans, got " .. #subs)
        assert.are.equal(1, countBlocks(subs))
        assert.is_falsy(out:match("%$"), "no dollar signs should remain")
        for _, s in ipairs(subs) do
            assert.is_truthy(out:find(s.token, 1, true))
        end
    end)

    it("handles unclosed single $$ gracefully", function()
        local input = "Some text with unclosed $$ math expression"
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
        assert.is_truthy(out:match("%$%$"), "expected $$ to be preserved")
    end)

    it("handles an unclosed single $ gracefully", function()
        local input = "An unclosed $formula that never ends"
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("leaves non-math text byte-identical", function()
        local input = "Just some text without math."
        local out, subs = mi:process(input)
        assert.are.equal(input, out)
        assert.are.equal(0, #subs)
    end)

    it("leaves a whole document without math byte-identical", function()
        local input = table.concat({
            "# Title", "", "Some *emphasis* and a [link](http://x).", "",
            "- item one", "- item two", "",
            "> quote", "", "```lua", "local x = 1", "```", "", "Done.",
        }, "\n")
        local out, subs = mi:process(input)
        assert.are.equal(input, out)
        assert.are.equal(0, #subs)
    end)

    it("caches: identical formulas share one rendering", function()
        local input = "$cached$ and again $cached$"
        local out, subs = mi:process(input)
        assert.are.equal(2, #subs)
        assert.are.equal(subs[1].html, subs[2].html)
        assert.are.not_equal(subs[1].token, subs[2].token)
        assert.are.equal(1, mi.renderer.stats.misses)
        assert.are.equal(1, mi.renderer.stats.hits)
    end)

    ----------------------------------------------------------------------
    -- Code blocks and code spans (new cases)
    ----------------------------------------------------------------------

    it("does not extract math inside a fenced code block", function()
        local input = "Before.\n\n```\n$$x^2$$ and $y$\n```\n\nAfter."
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("does not extract math inside a fenced block with a language tag", function()
        local input = "```latex\n$$\\frac{a}{b}$$\n```"
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("does not extract math inside a tilde-fenced code block", function()
        local input = "~~~\n$$x^2$$\n~~~"
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("still extracts math outside a fenced code block", function()
        local input = "$a$\n\n```\n$b$\n```\n\n$c$"
        local out, subs = mi:process(input)
        assert.are.equal(2, #subs)
        assert.are.equal("a", subs[1].latex)
        assert.are.equal("c", subs[2].latex)
        assert.is_truthy(out:find("$b$", 1, true), "code block content was altered")
    end)

    it("does not extract math inside an inline code span", function()
        local input = "Use `$x$` as a shell variable."
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("does not extract block math inside an inline code span", function()
        local input = "Type ``$$a$$`` verbatim."
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("extracts math after an inline code span on the same line", function()
        local input = "Set `x` then compute $y^2$ now."
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.are.equal("y^2", subs[1].latex)
        assert.is_truthy(out:find("`x`", 1, true))
    end)

    it("treats an unclosed backtick as literal without swallowing math", function()
        local input = "A stray ` backtick and $z$ here."
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.are.equal("z", subs[1].latex)
    end)

    ----------------------------------------------------------------------
    -- Inline `$` disambiguation
    ----------------------------------------------------------------------

    it("does not treat currency amounts as math", function()
        local input = "It costs $5 and $10 in total."
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("does not treat '$ x $' with inner spaces as math", function()
        local input = "Give me $ 100 or $ 200 please."
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("does not let inline math span a blank line", function()
        local input = "A $lone dollar here\n\nand another $ over there."
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("allows inline math to span a single newline", function()
        local input = "See $a +\nb$ here."
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.are.equal("a +\nb", subs[1].latex)
    end)

    it("ignores escaped dollar signs", function()
        local input = "Literal \\$5 and \\$10 stay put."
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("does not treat an intra-word $ as an opener", function()
        local input = "var$name and other$thing."
        local out, subs = mi:process(input)
        assert.are.equal(0, #subs)
        assert.are.equal(input, out)
    end)

    it("ignores empty math delimiters", function()
        local out, subs = mi:process("empty $$ $$ pair")
        assert.are.equal(0, #subs)
    end)

    ----------------------------------------------------------------------
    -- Token properties
    ----------------------------------------------------------------------

    it("uses tokens made only of characters markdown cannot mangle", function()
        local _, subs = mi:process("$x$")
        assert.is_truthy(subs[1].token:match("^[A-Z0-9]+$"),
            "token must be alphanumeric uppercase: " .. subs[1].token)
    end)

    it("picks a token that does not collide with document content", function()
        local _, subs = mi:process("$x$ plus prose")
        local token = subs[1].token
        -- Feed the token back in as literal content: the new token must differ.
        local input2 = token .. " literally, plus $y$"
        local out2, subs2 = mi:process(input2)
        assert.are.not_equal(token, subs2[1].token)
        assert.is_truthy(out2:find(token, 1, true), "literal text was destroyed")
    end)

    ----------------------------------------------------------------------
    -- apply()
    ----------------------------------------------------------------------

    it("apply swaps tokens for rendered HTML", function()
        local out, subs = mi:process("Value $x^2$ here.")
        local html = "<p>" .. out .. "</p>"
        local final = mi:apply(html, subs)
        assert.is_falsy(final:find(subs[1].token, 1, true))
        assert.is_truthy(final:find("<sup>2</sup>", 1, true))
    end)

    it("apply handles HTML containing % characters", function()
        local out, subs = mi:process("Growth $g$ of 50%.")
        local final = mi:apply("<p>" .. out .. "</p>", subs)
        assert.is_truthy(final:find("50%", 1, true))
        assert.is_falsy(final:find(subs[1].token, 1, true))
    end)

    it("apply is a no-op with no substitutions", function()
        local html = "<p>nothing</p>"
        assert.are.equal(html, mi:apply(html, {}))
    end)

    it("apply replaces every occurrence of every token", function()
        local out, subs = mi:process("$a$ and $b$ and $a$")
        local final = mi:apply(out, subs)
        assert.is_falsy(final:match("XMATHTOKEN"))
    end)

    it("run() composes process, convert and apply", function()
        local final = mi:run("A $x^2$ B", function(md) return "<p>" .. md .. "</p>" end)
        assert.is_truthy(final:find("<sup>2</sup>", 1, true))
        assert.is_truthy(final:find("<p>A ", 1, true))
    end)

    ----------------------------------------------------------------------
    -- Robustness
    ----------------------------------------------------------------------

    it("handles empty and nil-ish input without raising", function()
        assert.has_no_error(function() mi:process("") end)
        assert.are.equal("", (mi:process("")))
        assert.has_no_error(function() mi:process(nil) end)
    end)

    it("never raises on pathological input", function()
        for _, src in ipairs({
            "$", "$$", "$$$", "$$$$", "```", "`", "$$\\begin{",
            "$a$$b$", "\\$$x$$", "$$\n\n\n$$",
        }) do
            assert.has_no_error(function() mi:process(src) end, "raised on: " .. src)
        end
    end)
end)

describe("Markdown tables", function()
    local mi
    before_each(function()
        mi = MarkdownInterceptor.new()
    end)

    it("parses a standard markdown table", function()
        local input = "Table:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nEnd."
        local out, _ = mi:process(input)
        assert.is_truthy(out:find('<table border="1" cellspacing="0" cellpadding="4"><thead><tr><th style="border: 1px solid #000;">a</th><th style="border: 1px solid #000;">b</th></tr></thead><tbody><tr><td style="border: 1px solid #000;">1</td><td style="border: 1px solid #000;">2</td></tr></tbody></table>', 1, true))
    end)

    it("does not parse tables inside code blocks", function()
        local input = "```\n| a |\n|---|\n| 1 |\n```"
        local out, _ = mi:process(input)
        assert.are.equal(input, out)
    end)
    
    it("parses math inside table cells", function()
        local input = "| a |\n|---|\n| $x^2$ |"
        local out, subs = mi:process(input)
        assert.is_truthy(out:find('<table border="1" cellspacing="0" cellpadding="4"><thead><tr><th style="border: 1px solid #000;">a</th></tr></thead><tbody><tr><td style="border: 1px solid #000;">XMATHTOKEN', 1, true))
        assert.are.equal(1, #subs)
        assert.are.equal("x^2", subs[1].latex)
    end)
end)

describe("Multiline bold text", function()
    local mi
    before_each(function()
        mi = MarkdownInterceptor.new()
    end)

    it("handles bold text spanning across newlines", function()
        local input = "This is **bold\ntext**."
        local out, _ = mi:process(input)
        assert.is_truthy(out:find("<strong>bold\ntext</strong>", 1, true))
    end)

    it("does not process bold inside code spans", function()
        local input = "Use `**bold\ntext**`."
        local out, _ = mi:process(input)
        assert.are.equal(input, out)
    end)

    it("does not process bold across blank lines", function()
        local input = "**bold\n\ntext**"
        local out, _ = mi:process(input)
        assert.are.equal(input, out)
    end)
end)

describe("Equation splitting (splitLongLatex)", function()
    local mi

    before_each(function()
        mi = MarkdownInterceptor.new{ cache_dir = "/tmp/kobo-notes-test-cache" }
    end)

    it("leaves formulas shorter than threshold unchanged", function()
        local short = "a^2 + b^2 = c^2"
        assert.are.equal(short, MarkdownInterceptor.splitLongLatex(short, 45))
    end)

    it("leaves formulas with a single equals unchanged on their own line even if >= 45 chars", function()
        local formula = "\\frac{d}{dx} \\int_0^x f(t) dt = f(x) + g(x) - h(x)"
        assert.is_true(#formula >= 45)
        local res = MarkdownInterceptor.splitLongLatex(formula, 45)
        assert.are.equal(formula, res)
    end)

    it("splits chained equalities into multiple aligned rows starting on second equals", function()
        local formula = "f(x) = x^2 + 2x + 1 = (x + 1)^2 = \\int 2(t + 1) dt"
        assert.is_true(#formula >= 45)
        local split = MarkdownInterceptor.splitLongLatex(formula, 45)
        assert.is_truthy(split:find("^\\begin{aligned}\n& f%(x%) = x%^2 %+ 2x %+ 1 \\\\\n&="))
        assert.is_truthy(split:find("\\\\\n&= %(x %+ 1%)%^2 \\\\\n&="))
    end)

    it("splits at formula separators like commas and arrows instead of equals", function()
        local formula = "a = b, b = c -> d = e + f + g + h + i + j + k + l + m"
        assert.is_true(#formula >= 45)
        local split = MarkdownInterceptor.splitLongLatex(formula, 45)
        assert.is_truthy(split:find("& a = b, \\\\\n& b = c \\\\\n& %-> d = e"))
    end)

    it("splits at implication commands like \\iff and \\implies", function()
        local formula = "g(x,y) = (h * f)(x,y) + \\eta(x,y) \\quad\\iff\\quad G(u,v) = H(u,v)F(u,v) + N(u,v)"
        local split = MarkdownInterceptor.splitLongLatex(formula, 45)
        assert.is_truthy(split:find("^\\begin{aligned}\n& g%(x,y%) = %(h %* f%)%(x,y%) %+ \\eta%(x,y%) \\\\\n& \\iff"))
    end)

    it("does not split at commas inside parentheses like g(x, y)", function()
        local formula = "g(x,y) = \\sum_{i=-1}^{1}\\sum_{j=-1}^{1} w(i,j)\\, f(x+i, y+j)"
        assert.is_true(#formula >= 45)
        local res = MarkdownInterceptor.splitLongLatex(formula, 45)
        assert.are.equal(formula, res)
    end)

    it("ignores composite relational operators and double equals", function()
        local formula = "a <= b + c + d + e + f + g + h + i + j == k != l := m"
        assert.is_true(#formula >= 45)
        local res = MarkdownInterceptor.splitLongLatex(formula, 45)
        assert.are.equal(formula, res)
    end)

    it("ignores = nested inside curly braces", function()
        local formula = "\\frac{a + b = c}{d + e + f + g + h + i + j + k + l}"
        assert.is_true(#formula >= 45)
        local res = MarkdownInterceptor.splitLongLatex(formula, 45)
        assert.are.equal(formula, res)
    end)

    it("ignores formulas already in an environment", function()
        local formula = "\\begin{cases} x = 1 & \\text{if } y > 0 \\\\ x = 0 & \\text{otherwise} \\end{cases}"
        assert.is_true(#formula >= 45)
        local res = MarkdownInterceptor.splitLongLatex(formula, 45)
        assert.are.equal(formula, res)
    end)

    it("splits chained block math in process()", function()
        local long_eq = "x_1 + x_2 + x_3 = y_1 + y_2 + y_3 = z_1 + z_2 + z_3"
        local input = "$$" .. long_eq .. "$$"
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.is_true(subs[1].block)
        assert.is_truthy(subs[1].latex:find("^\\begin{aligned}"))
        assert.is_truthy(out:find("<div class=\"math%-placeholder\">"))
    end)
end)

describe("Inline math promotion to newline/block", function()
    local mi

    before_each(function()
        mi = MarkdownInterceptor.new{ cache_dir = "/tmp/kobo-notes-test-cache" }
    end)

    it("isInsideParagraph helper detects prose surrounding math", function()
        local text = "This is some prose $formula$ with trailing words."
        local open = text:find("%$")
        local close = text:find("%$", open + 1)
        assert.is_true(MarkdownInterceptor.isInsideParagraph(text, open, close))

        local standalone = "\n$formula$\n"
        local s_open = standalone:find("%$")
        local s_close = standalone:find("%$", s_open + 1)
        assert.is_false(MarkdownInterceptor.isInsideParagraph(standalone, s_open, s_close))
    end)

    it("promotes inline math >= 40 chars in paragraph to block on newline", function()
        local long_inline = "a_1 + a_2 + a_3 + a_4 + a_5 + b_1 + b_2 + b_3 + b_4"
        assert.is_true(#long_inline >= 40)
        local input = "In our problem, the expression $" .. long_inline .. "$ appears frequently."
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.is_true(subs[1].block)
        assert.is_truthy(out:find("\n\n<div class=\"math%-placeholder\">"))
    end)

    it("leaves inline math < 40 chars inline within paragraph", function()
        local short_inline = "x + y = z"
        assert.is_true(#short_inline < 40)
        local input = "In our problem, the expression $" .. short_inline .. "$ appears frequently."
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.is_false(subs[1].block)
        assert.is_falsy(out:find("<div class=\"math%-placeholder\">"))
    end)

    it("splits and promotes inline chained equalities >= 45 chars even if standalone", function()
        local long_eq = "u_1 + u_2 + u_3 = v_1 + v_2 + v_3 = w_1 + w_2 + w_3"
        assert.is_true(#long_eq >= 45)
        local input = "\n$" .. long_eq .. "$\n"
        local out, subs = mi:process(input)
        assert.are.equal(1, #subs)
        assert.is_true(subs[1].block)
        assert.is_truthy(subs[1].latex:find("^\\begin{aligned}"))
    end)
end)

describe("LaTeX font size configuration and stylesheet", function()
    -- Set up mocks required to instantiate MarkdownReader
    package.preload["ui/widget/container/widgetcontainer"] = function()
        local WC = {}
        function WC:extend(t)
            t = t or {}
            setmetatable(t, { __index = self })
            return t
        end
        return WC
    end
    package.preload["document/documentregistry"] = function()
        return { addAuxProvider = function() end }
    end
    package.preload["util"] = function()
        return { getFileNameSuffix = function() return "md" end }
    end
    package.preload["gettext"] = function()
        return function(s) return s end
    end
    package.preload["apps/reader/readerui"] = function() return {} end
    package.preload["apps/filemanager/filemanagerconverter"] = function() return {} end
    package.preload["datastorage"] = function()
        return { getDataDir = function() return "/tmp/kobo-data" end }
    end
    package.preload["ui/widget/confirmbox"] = function() return {} end
    package.preload["ffi/util"] = function()
        return { template = function(s, ...) return s end }
    end

    local MarkdownReader = require("main")

    local saved_settings
    local fake_settings

    before_each(function()
        saved_settings = {}
        fake_settings = {
            readSetting = function(_, key, default)
                if saved_settings[key] ~= nil then return saved_settings[key] end
                return default
            end,
            saveSetting = function(_, key, val)
                saved_settings[key] = val
            end,
            flush = function() end,
        }
        _G.G_reader_settings = fake_settings
    end)

    after_each(function()
        _G.G_reader_settings = nil
    end)

    it("defaults to 1.0 font size scale", function()
        local reader = setmetatable({}, { __index = MarkdownReader })
        assert.are.equal(1.0, reader:getMathFontSize())
    end)

    it("persists font size changes via setMathFontSize", function()
        local reader = setmetatable({}, { __index = MarkdownReader })
        reader:setMathFontSize(1.2)
        assert.are.equal(1.2, reader:getMathFontSize())
        assert.are.equal(1.2, saved_settings["markdownreader_math_font_size"])
    end)

    it("injects configured math font size and zoom in getStylesheet", function()
        local reader = setmetatable({}, { __index = MarkdownReader })
        reader:setMathFontSize(1.4)
        local css = reader:getStylesheet()
        assert.is_truthy(css:find("%.mathblock, %.mathinline { font%-size: 1%.40em; }"))
        assert.is_truthy(css:find("img%.math%-display { display: block; margin: 0%.6em auto; text%-align: center; zoom: 1%.40; }"))
        assert.is_truthy(css:find("img%.math%-inline { display: inline%-block; vertical%-align: middle; zoom: 1%.40; }"))
    end)

    it("builds main menu item with LaTeX Font Size submenu", function()
        local reader = setmetatable({}, { __index = MarkdownReader })
        local menu_items = {}
        reader:addToMainMenu(menu_items)
        local mr_item = menu_items.markdownreader
        assert.is_not_nil(mr_item)
        local font_size_submenu
        for _, item in ipairs(mr_item.sub_item_table) do
            if item.text == "LaTeX Font Size" then
                font_size_submenu = item
                break
            end
        end
        assert.is_not_nil(font_size_submenu)
        assert.are.equal(4, #font_size_submenu.sub_item_table)
        -- Initially 1.0 is selected
        assert.is_false(font_size_submenu.sub_item_table[1].checked_func()) -- 0.8
        assert.is_true(font_size_submenu.sub_item_table[2].checked_func())  -- 1.0
        assert.is_false(font_size_submenu.sub_item_table[3].checked_func()) -- 1.2
        assert.is_false(font_size_submenu.sub_item_table[4].checked_func()) -- 1.4

        -- Select 120%
        font_size_submenu.sub_item_table[3].callback()
        assert.are.equal(1.2, reader:getMathFontSize())
        assert.is_true(font_size_submenu.sub_item_table[3].checked_func())
        assert.is_false(font_size_submenu.sub_item_table[2].checked_func())
    end)

    it("injects table styling with black borders, font size 0.9em, and padding", function()
        local reader = setmetatable({}, { __index = MarkdownReader })
        local css = reader:getStylesheet()
        assert.is_truthy(css:find("table { border%-collapse: collapse; width: 100%%; margin: 1%.5em 0; font%-size: 0%.9em; border: 1px solid #000;"))
        assert.is_truthy(css:find("border%-width: 1px; border%-style: solid; border%-color: #000;"))
        assert.is_truthy(css:find("th, td { border: 1px solid #000;"))
    end)
end)

describe("MarkdownInterceptor remote image downloading and embedding", function()
    local mi
    local test_cache_dir = "/tmp/kobo-notes-img-test"
    local test_render_dir = "/tmp/kobo-notes-img-render/"
    local orig_download

    before_each(function()
        os.execute("rm -rf " .. test_cache_dir .. " " .. test_render_dir)
        os.execute("mkdir -p " .. test_cache_dir .. " " .. test_render_dir)
        mi = MarkdownInterceptor.new{ cache_dir = test_cache_dir }
        orig_download = MarkdownInterceptor.downloadImage
    end)

    after_each(function()
        MarkdownInterceptor.downloadImage = orig_download
        os.execute("rm -rf " .. test_cache_dir .. " " .. test_render_dir)
    end)

    it("detects and replaces remote HTTP and HTTPS images with cached filenames when render_dir is supplied", function()
        local downloaded = {}
        MarkdownInterceptor.downloadImage = function(self_or_url, url_or_path, maybe_path)
            local url = type(self_or_url) == "table" and url_or_path or self_or_url
            local path = type(self_or_url) == "table" and maybe_path or url_or_path
            table.insert(downloaded, { url = url, path = path })
            local f = io.open(path, "wb")
            if f then f:write("dummy-image-data") f:close() end
            return true
        end

        local input = "Intro.\n\n![Cute Cat](https://example.com/cat.png)\n\n![Dog](http://example.com/dog.jpg)\n\nOutro."
        local out, subs = mi:process(input, test_render_dir)

        assert.are.equal(2, #downloaded)
        assert.are.equal("https://example.com/cat.png", downloaded[1].url)
        assert.are.equal("http://example.com/dog.jpg", downloaded[2].url)

        local hash1 = require("math_renderer").hash("https://example.com/cat.png")
        local hash2 = require("math_renderer").hash("http://example.com/dog.jpg")

        assert.is_truthy(out:find("![Cute Cat](img-" .. hash1 .. ".png)", 1, true))
        assert.is_truthy(out:find("![Dog](img-" .. hash2 .. ".jpg)", 1, true))
        assert.is_falsy(out:find("https://example.com/cat.png", 1, true))
        assert.is_falsy(out:find("http://example.com/dog.jpg", 1, true))
    end)

    it("preserves optional image titles in replacement", function()
        MarkdownInterceptor.downloadImage = function(_, _, path)
            local f = io.open(path, "wb")
            if f then f:write("data") f:close() end
            return true
        end

        local input = '![Architecture](https://example.com/arch.svg "System Overview")'
        local out = mi:process(input, test_render_dir)
        local hash = require("math_renderer").hash("https://example.com/arch.svg")
        assert.is_truthy(out:find('![Architecture](img-' .. hash .. '.svg "System Overview")', 1, true))
    end)

    it("uses full cache path when render_dir is not supplied", function()
        MarkdownInterceptor.downloadImage = function(_, _, path)
            local f = io.open(path, "wb")
            if f then f:write("data") f:close() end
            return true
        end

        local input = "![Cat](https://example.com/cat.png)"
        local out = mi:process(input)
        local hash = require("math_renderer").hash("https://example.com/cat.png")
        assert.is_truthy(out:find(test_cache_dir .. "/img-" .. hash .. ".png", 1, true))
    end)

    it("does not re-download already cached images", function()
        local hash = require("math_renderer").hash("https://example.com/cached.png")
        local cached_file = test_render_dir .. "img-" .. hash .. ".png"
        local f = io.open(cached_file, "wb")
        assert.is_not_nil(f)
        f:write("pre-existing")
        f:close()

        local dl_count = 0
        MarkdownInterceptor.downloadImage = function()
            dl_count = dl_count + 1
            return true
        end

        local input = "![Cached](https://example.com/cached.png)"
        local out = mi:process(input, test_render_dir)

        assert.are.equal(0, dl_count)
        assert.is_truthy(out:find("![Cached](img-" .. hash .. ".png)", 1, true))
    end)

    it("deduplicates downloads when identical URL appears multiple times", function()
        local dl_count = 0
        MarkdownInterceptor.downloadImage = function(_, _, path)
            dl_count = dl_count + 1
            local fh = io.open(path, "wb")
            if fh then fh:write("data") fh:close() end
            return true
        end

        local input = "![Top](https://example.com/logo.png)\n\n![Bottom](https://example.com/logo.png)"
        local out = mi:process(input, test_render_dir)

        assert.are.equal(1, dl_count)
        local hash = require("math_renderer").hash("https://example.com/logo.png")
        local count = 0
        for _ in out:gmatch("img%-" .. hash .. "%.png") do
            count = count + 1
        end
        assert.are.equal(2, count)
    end)

    it("ignores images inside fenced code blocks", function()
        local dl_called = false
        MarkdownInterceptor.downloadImage = function()
            dl_called = true
            return true
        end

        local input = "```markdown\n![Fake](https://example.com/not_an_image.png)\n```"
        local out = mi:process(input, test_render_dir)

        assert.is_false(dl_called)
        assert.are.equal(input, out)
    end)

    it("ignores images inside inline code spans", function()
        local dl_called = false
        MarkdownInterceptor.downloadImage = function()
            dl_called = true
            return true
        end

        local input = "Here is `![Code](https://example.com/inline.png)` in prose."
        local out = mi:process(input, test_render_dir)

        assert.is_false(dl_called)
        assert.are.equal(input, out)
    end)

    it("ignores local image paths and normal links", function()
        local dl_called = false
        MarkdownInterceptor.downloadImage = function()
            dl_called = true
            return true
        end

        local input = "![Local](images/test.png) and [Link](https://example.com)"
        local out = mi:process(input, test_render_dir)

        assert.is_false(dl_called)
        assert.are.equal(input, out)
    end)

    it("fails gracefully when downloading fails or network is unavailable", function()
        MarkdownInterceptor.downloadImage = function()
            return false, "connection refused"
        end

        local input = "![Failed](https://example.com/fails.png)"
        local out, subs = mi:process(input, test_render_dir)

        -- Document opening does not crash, original link preserved
        assert.is_truthy(out:find("![Failed](https://example.com/fails.png)", 1, true))
        assert.are.equal(0, #subs)
    end)
end)

describe("Orderly status and notifications manager", function()
    local StatusManager = require("status_manager")
    local UIManager = require("ui/uimanager")
    local MarkdownReader = require("main")

    local events
    local orig_show, orig_close, orig_setDirty, orig_forceRePaint

    before_each(function()
        events = {}
        StatusManager.reset()

        orig_show = UIManager.show
        orig_close = UIManager.close
        orig_setDirty = UIManager.setDirty
        orig_forceRePaint = UIManager.forceRePaint

        UIManager.show = function(_, widget)
            table.insert(events, { type = "show", text = widget and widget.text })
        end
        UIManager.close = function(_, widget)
            table.insert(events, { type = "close", text = widget and widget.text })
        end
        UIManager.setDirty = function(_, widget, mode)
            table.insert(events, { type = "setDirty", mode = mode })
        end
        UIManager.forceRePaint = function()
            table.insert(events, { type = "forceRePaint" })
        end
    end)

    after_each(function()
        StatusManager.reset()
        UIManager.show = orig_show
        UIManager.close = orig_close
        UIManager.setDirty = orig_setDirty
        UIManager.forceRePaint = orig_forceRePaint
    end)

    it("shows status and cleanly updates e-ink screen", function()
        StatusManager.showStatus("Opening note...")
        assert.is_not_nil(StatusManager.getActiveStatus())
        assert.are.equal("Opening note...", StatusManager.getActiveStatus().text)

        local has_show, has_dirty, has_repaint = false, false, false
        for _, ev in ipairs(events) do
            if ev.type == "show" and ev.text == "Opening note..." then has_show = true end
            if ev.type == "setDirty" and ev.mode == "ui" then has_dirty = true end
            if ev.type == "forceRePaint" then has_repaint = true end
        end
        assert.is_true(has_show)
        assert.is_true(has_dirty)
        assert.is_true(has_repaint)
    end)

    it("closes previous status FIRST before showing new status", function()
        StatusManager.showStatus("Stage 1")
        StatusManager.showStatus("Stage 2")

        local close_1_idx, show_2_idx
        for idx, ev in ipairs(events) do
            if ev.type == "close" and ev.text == "Stage 1" then
                close_1_idx = idx
            elseif ev.type == "show" and ev.text == "Stage 2" then
                show_2_idx = idx
            end
        end

        assert.is_not_nil(close_1_idx, "Stage 1 should have been closed")
        assert.is_not_nil(show_2_idx, "Stage 2 should have been shown")
        assert.is_true(close_1_idx < show_2_idx, "close(Stage 1) must occur BEFORE show(Stage 2)")
        assert.are.equal("Stage 2", StatusManager.getActiveStatus().text)
    end)

    it("clearStatus cleanly closes active message and sets active_info to nil", function()
        StatusManager.showStatus("Stage 1")
        assert.is_not_nil(StatusManager.getActiveStatus())

        StatusManager.clearStatus()
        assert.is_nil(StatusManager.getActiveStatus())

        local closed = false
        for _, ev in ipairs(events) do
            if ev.type == "close" and ev.text == "Stage 1" then closed = true end
        end
        assert.is_true(closed)

        -- Safe no-op on subsequent call
        StatusManager.clearStatus()
        assert.is_nil(StatusManager.getActiveStatus())
    end)

    it("document opening sequence closes each stage before next and clears on finish", function()
        -- Simulate the full pipeline
        StatusManager.showStatus("Opening Markdown...")
        StatusManager.showStatus("Downloading remote image...")
        StatusManager.showStatus("Rendering LaTeX math...")
        StatusManager.showStatus("Rendering Mermaid graph...")
        StatusManager.clearStatus()

        assert.is_nil(StatusManager.getActiveStatus())

        local sequence = {}
        for _, ev in ipairs(events) do
            if ev.type == "show" or ev.type == "close" then
                table.insert(sequence, ev.type .. ":" .. tostring(ev.text))
            end
        end

        -- Verify strict alternating show -> close -> show -> close pattern
        assert.are.equal("show:Opening Markdown...", sequence[1])
        assert.are.equal("close:Opening Markdown...", sequence[2])
        assert.are.equal("show:Downloading remote image...", sequence[3])
        assert.are.equal("close:Downloading remote image...", sequence[4])
        assert.are.equal("show:Rendering LaTeX math...", sequence[5])
        assert.are.equal("close:Rendering LaTeX math...", sequence[6])
        assert.are.equal("show:Rendering Mermaid graph...", sequence[7])
        assert.are.equal("close:Rendering Mermaid graph...", sequence[8])
        assert.are.equal(8, #sequence)
    end)

    it("openMarkdown calls showStatus and clears on error", function()
        local reader = setmetatable({}, { __index = MarkdownReader })
        -- Open a non-existent file
        local ok = reader:openMarkdown("/nonexistent/path/doc.md")
        assert.is_falsy(ok)
        -- active status must be nil
        assert.is_nil(StatusManager.getActiveStatus())

        local has_open_close = false
        for _, ev in ipairs(events) do
            if ev.type == "close" and ev.text == "Opening Markdown..." then
                has_open_close = true
            end
        end
        assert.is_true(has_open_close, "Opening Markdown... must be closed on file open failure")
    end)

    it("process with LaTeX math notifies StatusManager", function()
        local mi = MarkdownInterceptor.new{ cache_dir = "/tmp/kobo-notes-math-status" }
        local input = "Some math: $x^2 + y^2 = z^2$ here."
        mi:process(input)

        local has_math_status = false
        for _, ev in ipairs(events) do
            if ev.type == "show" and ev.text == "Rendering LaTeX math..." then
                has_math_status = true
            end
        end
        assert.is_true(has_math_status, "Rendering LaTeX math... status should be shown")
    end)

    it("downloadImage handles HTTPS, redirects, and writes binary content", function()
        local ltn12 = {
            sink = {
                table = function(t)
                    return function(chunk)
                        if chunk then table.insert(t, chunk) end
                    end
                end,
            }
        }
        package.loaded["ltn12"] = ltn12

        local requested_urls = {}
        local fake_https = {
            request = function(req)
                table.insert(requested_urls, req.url)
                if req.url == "https://example.com/redirect.png" then
                    return 1, 302, { location = "https://example.com/final.png" }
                else
                    req.sink("binary-image-data")
                    return 1, 200, {}
                end
            end
        }
        package.loaded["ssl.https"] = fake_https

        local dest_file = "/tmp/kobo-notes-dl-test/img_final.png"
        os.execute("rm -rf /tmp/kobo-notes-dl-test")

        local ok, err = MarkdownInterceptor.downloadImage("https://example.com/redirect.png", dest_file)
        assert.is_true(ok)
        assert.is_nil(err)
        assert.are.equal(2, #requested_urls)
        assert.are.equal("https://example.com/redirect.png", requested_urls[1])
        assert.are.equal("https://example.com/final.png", requested_urls[2])

        local f = io.open(dest_file, "rb")
        assert.is_not_nil(f)
        local content = f:read("*a")
        f:close()
        assert.are.equal("binary-image-data", content)

        os.execute("rm -rf /tmp/kobo-notes-dl-test")
        package.loaded["ssl.https"] = nil
        package.loaded["ltn12"] = nil
    end)
end)
