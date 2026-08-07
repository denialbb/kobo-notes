package.path = package.path .. ";./plugins/flashcards.koplugin/?.lua"
local Parser = require("parser")

describe("Parser.parse basics", function()
    it("parses a single Q/A pair", function()
        local cards = Parser.parse("Q: question\nA: answer")
        assert.are.equal(1, #cards)
        assert.are.equal("question", cards[1].question)
        assert.are.equal("answer", cards[1].answer)
    end)

    it("parses multiple cards separated by ---", function()
        local cards = Parser.parse("Q: one\nA: 1\n---\nQ: two\nA: 2")
        assert.are.equal(2, #cards)
        assert.are.equal("one", cards[1].question)
        assert.are.equal("2", cards[2].answer)
    end)

    it("ignores leading/trailing separators and blank blocks", function()
        local cards = Parser.parse("\n---\n---\n Q: ok\n A: yes\n---\n")
        assert.are.equal(1, #cards)
        assert.are.equal("yes", cards[1].answer)
    end)
end)

describe("Parser.parse multi-line content", function()
    it("appends continuation lines to the question", function()
        local cards = Parser.parse("Q: line one\n   line two\nA: yes")
        assert.are.equal(1, #cards)
        assert.are.equal("line one\nline two", cards[1].question)
    end)

    it("appends continuation lines to the answer", function()
        local cards = Parser.parse("Q: q\nA: a1\n   a2\n   a3")
        assert.are.equal("a1\na2\na3", cards[1].answer)
    end)

    it("strips the surrounding blank space from each block", function()
        local cards = Parser.parse("\n\n---\n\n   \nQ: padded  \nA: guts\n\n\n---\n\n")
        assert.are.equal(1, #cards)
        assert.are.equal("padded", cards[1].question)
        assert.are.equal("guts", cards[1].answer)
    end)
end)

describe("Parser.parse skips unusable blocks", function()
    it("drops a block with only a question", function()
        local cards = Parser.parse("Q: no answer here\n---\nQ: full\nA: yes")
        assert.are.equal(1, #cards)
        assert.are.equal("full", cards[1].question)
    end)

    it("drops a block with only an answer", function()
        local cards = Parser.parse("A: no question\n---\nQ: full\nA: yes")
        assert.are.equal(1, #cards)
        assert.are.equal("full", cards[1].question)
    end)

    it("drops Q:/A: prefixes with no content", function()
        local cards = Parser.parse("Q:\nA:\n---\nQ: real\nA: real")
        assert.are.equal(1, #cards)
    end)

    it("returns an empty list for empty or separator-only input", function()
        assert.are.equal(0, #Parser.parse(""))
        assert.are.equal(0, #Parser.parse("---\n---\n---"))
    end)
end)

describe("Parser.parse robustness", function()
    it("handles CRLF line endings", function()
        local cards = Parser.parse("Q: what\r\nA: yes\r\n---\r\nQ: next\r\nA: great\r\n")
        assert.are.equal(2, #cards)
        assert.are.equal("what", cards[1].question)
        assert.are.equal("next", cards[2].question)
    end)

    it("accepts indented Q:/A: prefixes", function()
        local cards = Parser.parse("   Q: indented\n   A: with space copy that got stripped")
        assert.are.equal(1, #cards)
        assert.are.equal("indented", cards[1].question)
    end)

    it("requires a separator; a bare Q then A in one block is still one card", function()
        local cards = Parser.parse("Q: first\nA: x\n\nQ: second\nA: y")
        -- No '---', so all of it is a single block (mirrors the desktop tool).
        -- The blank line lands in the current section (the answer); the second
        -- Q:/A: pair continues that same card.
        assert.are.equal(1, #cards)
        assert.are.equal("first\nsecond", cards[1].question)
        assert.are.equal("x\n\ny", cards[1].answer)
    end)

    it("preserves interior blank lines inside a card (parity with quiz.py)", function()
        local cards = Parser.parse("Q: first paragraph\n\nsecond paragraph\nA: yes")
        assert.are.equal(1, #cards)
        assert.are.equal("first paragraph\n\nsecond paragraph", cards[1].question)
    end)

    it("splits on a literal --- even inside prose (parity with quiz.py)", function()
        -- Python's content.split('---') splits on the literal substring anywhere;
        -- we mirror that exactly even though a lone dash-triple inside a card is
        -- unusual. This documents the (intended) quirk.
        local cards = Parser.parse("Q: x\nA: saw a --- then\nQ: later\nA: y")
        assert.are.equal(2, #cards)
    end)
end)

describe("Parser.parse returned shape", function()
    it("never returns nil and every card has both keys", function()
        local cards = Parser.parse("Q: a\nA: b\n---\nQ: c\nA: d")
        for _, card in ipairs(cards) do
            assert.is_string(card.question)
            assert.is_string(card.answer)
            assert.is_truthy(card.question ~= "")
            assert.is_truthy(card.answer ~= "")
        end
    end)
end)