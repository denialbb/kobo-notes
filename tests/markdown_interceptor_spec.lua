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
        assert.is_truthy(out:find("<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>", 1, true))
    end)

    it("does not parse tables inside code blocks", function()
        local input = "```\n| a |\n|---|\n| 1 |\n```"
        local out, _ = mi:process(input)
        assert.are.equal(input, out)
    end)
    
    it("parses math inside table cells", function()
        local input = "| a |\n|---|\n| $x^2$ |"
        local out, subs = mi:process(input)
        assert.is_truthy(out:find("<table><thead><tr><th>a</th></tr></thead><tbody><tr><td>XMATHTOKEN", 1, true))
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
