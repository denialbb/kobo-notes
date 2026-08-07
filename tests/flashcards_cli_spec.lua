-- End-to-end smoke test: the CLI driver exercises the exact parser + quiz
-- engine shipped in the plugin against the fixture corpus, off-device.
describe("flashcards CLI (tools/flashcards-cli.lua)", function()
    it("runs an auto quiz over the fixture corpus and reports the totals", function()
        local pipe = io.popen("lua tools/flashcards-cli.lua tests/fixtures/notes --auto 2>/dev/null", "r")
        assert.is_not_nil(pipe, "could not start the CLI")
        local output = pipe:read("*a")
        local ok = pipe:close()

        assert.is_truthy(output:find("CARDS=7 SCORE=7 ANSWERED=7 MISSED=0", 1, true),
            "expected a perfect 7/7 run, got:\n" .. output)
        assert.are.equal(true, ok, "CLI exited non-zero")
    end)

    it("runs an auto quiz on a single file (theme = parent dir)", function()
        local pipe = io.popen("lua tools/flashcards-cli.lua tests/fixtures/notes/history/flashcards.md --auto 2>/dev/null", "r")
        local output = pipe:read("*a")
        pipe:close()
        assert.is_truthy(output:find("CARDS=3 SCORE=3", 1, true), "got:\n" .. output)
    end)

    it("exits cleanly when the path has no flashcards", function()
        local pipe = io.popen("lua tools/flashcards-cli.lua /tmp --auto 2>/dev/null", "r")
        local output = pipe:read("*a")
        local ok = pipe:close()
        assert.are.equal(true, ok)
        assert.is_truthy(output:find("No flashcards.md files found", 1, true), "got:\n" .. output)
    end)
end)