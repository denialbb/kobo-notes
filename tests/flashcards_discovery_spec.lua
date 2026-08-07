package.path = package.path .. ";./plugins/flashcards.koplugin/?.lua"
local Discovery = require("discovery")
local lfs = require("lfs")

describe("Discovery.find", function()
    it("finds themes when root has no trailing slash", function()
        local themes = Discovery.find("tests/fixtures/notes", lfs)
        assert.is_not_nil(themes)
        assert.are.equal("tests/fixtures/notes/algebra/flashcards.md", themes.algebra)
        assert.are.equal("tests/fixtures/notes/history/flashcards.md", themes.history)
    end)

    it("yields identical theme map when root has a trailing slash", function()
        local themes_no_slash = Discovery.find("tests/fixtures/notes", lfs)
        local themes_with_slash = Discovery.find("tests/fixtures/notes/", lfs)
        assert.are.same(themes_no_slash, themes_with_slash)
    end)

    it("returns empty table for invalid or empty root", function()
        assert.are.same({}, Discovery.find(nil, lfs))
        assert.are.same({}, Discovery.find("", lfs))
        assert.are.same({}, Discovery.find(123, lfs))
    end)
end)
