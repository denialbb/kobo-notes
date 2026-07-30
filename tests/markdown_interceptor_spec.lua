package.path = package.path .. ";./plugins/markdownreader.koplugin/?.lua"
local MarkdownInterceptor = require("markdown_interceptor")

describe("MarkdownInterceptor", function()
    before_each(function()
        os.execute("rm -rf /tmp/microtex-cache")
        MarkdownInterceptor:init("./plugins/markdownreader.koplugin/libmicrotex.so")
    end)

    local function extract_svg_path(output)
        -- Extract filesystem path from image tag: ![math](/path/to/file.svg)
        local full = output:match("!%[math%]%((.-)%)$")
        return full
    end

    it("should replace block math with an image tag", function()
        local input = "Here is some math:\n\n$$a^2 + b^2 = c^2$$\n\nNeat."
        local output = MarkdownInterceptor:process(input)
        assert.is_truthy(output:match("!%[math%]%(/tmp/microtex%-cache/.-%.svg%)"))
        assert.is_falsy(output:match("%$%$"))
    end)

    it("should replace inline math with an image tag", function()
        local input = "The value of $x$ is 5."
        local output = MarkdownInterceptor:process(input)
        assert.is_truthy(output:match("!%[math%]%(/tmp/microtex%-cache/.-%.svg%)"))
        assert.is_falsy(output:match("%$x%$"))
    end)

    it("should cache rendered formulas", function()
        local input = "$cached$"
        local output1 = MarkdownInterceptor:process(input)
        local path = extract_svg_path(output1)
        assert.is_not_nil(path, "Could not extract path from: " .. output1)
        
        -- Modify the file to prove cache hit
        local f = io.open(path, "w")
        f:write("CACHED_CONTENT")
        f:close()
        
        local output2 = MarkdownInterceptor:process(input)
        local path2 = extract_svg_path(output2)
        assert.is_not_nil(path2, "Could not extract path from second output")
        
        assert.are.equal(path, path2)
        
        local f2 = io.open(path2, "r")
        local content = f2:read("*all")
        f2:close()
        assert.are.equal("CACHED_CONTENT", content)
    end)
    
    it("should replace multi-line block math ($$ on separate lines)", function()
        local input = "Multi-line equation:\n\n$$\na^2 + b^2 = c^2\n$$\n\nEnd."
        local output = MarkdownInterceptor:process(input)
        assert.is_truthy(output:match("!%[math%]%(/tmp/microtex%-cache/.-%.svg%)"),
            "Expected image tag for multi-line math, got: " .. output)
        assert.is_falsy(output:match("%$%$"), "Expected no $$ delimiters in output")
    end)

    it("should replace complex multi-line block math (aligned/cases)", function()
        local input = "Cases:\n\n$$\n\\begin{cases}\n  x &\\text{if } y\\\\\n  z &\\text{otherwise}\n\\end{cases}\n$$\n\nDone."
        local output = MarkdownInterceptor:process(input)
        assert.is_truthy(output:match("!%[math%]%(/tmp/microtex%-cache/.-%.svg%)"),
            "Expected image tag for complex multi-line math")
        assert.is_falsy(output:match("%$%$"), "Expected no $$ delimiters in output")
    end)

    it("should handle mixed inline and multi-line block math", function()
        local input = "Let $G = (N, A)$ be our graph. Then:\n\n$$\n\\sum_{e \\in A} w_e x_e\n$$\n\nwhere $w_e > 0$."
        local output = MarkdownInterceptor:process(input)
        -- Should have three image tags (one block + two inline)
        local _, count = output:gsub("!%[math%]", "")
        assert.are.equal(3, count, "Expected 3 image tags for mixed math, got " .. count)
    end)

    it("should handle unclosed single $$ gracefully", function()
        local input = "Some text with unclosed $$ math expression"
        local output = MarkdownInterceptor:process(input)
        assert.is_falsy(output:match("!%[math%]"))
        assert.is_truthy(output:match("%$%$"), "Expected $$ to be preserved")
    end)

    it("should leave non-math text untouched", function()
        local input = "Just some text without math."
        local output = MarkdownInterceptor:process(input)
        assert.are.equal(input, output)
    end)
end)
