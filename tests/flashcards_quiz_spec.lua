package.path = package.path .. ";./plugins/flashcards.koplugin/?.lua"
local Quiz = require("quiz")

local function makeCards(n)
    local cards = {}
    for i = 1, n do
        cards[i] = { question = "q" .. i, answer = "a" .. i }
    end
    return cards
end

describe("Quiz.new", function()
    it("copies cards and reports the total", function()
        local q = Quiz.new{ cards = makeCards(5), shuffle = false }
        assert.are.equal(5, q:total())
        assert.are.equal("q1", q:current().question)
    end)

    it("shuffles when asked (deterministic under a fixed seed)", function()
        local a = Quiz.new{ cards = makeCards(100), seed = 7 }
        local b = Quiz.new{ cards = makeCards(100), seed = 7 }
        assert.are.equal(a.cards[1].question, b.cards[1].question)
        assert.are.equal(a.cards[50].question, b.cards[50].question)
        -- It must actually reorder something for a 100-card deck.
        local same_order = true
        for i = 1, 100 do
            if a.cards[i].question ~= "q" .. i then same_order = false break end
        end
        assert.is_false(same_order)
    end)

    it("keeps the given order when shuffle is false", function()
        local q = Quiz.new{ cards = makeCards(4), shuffle = false }
        assert.are.equal("q1", q.cards[1].question)
        assert.are.equal("q4", q.cards[4].question)
    end)

    it("does not mutate the caller's card table", function()
        local cards = makeCards(2)
        local q = Quiz.new{ cards = cards, shuffle = false }
        q.cards[1].question = "mutated"
        assert.are.equal("q1", cards[1].question)
    end)
end)

describe("Quiz flow", function()
    it("walks every card and reports done() only at the end", function()
        local q = Quiz.new{ cards = makeCards(3), shuffle = false }
        assert.is_false(q:done())
        q:mark(true)
        assert.are.equal(1, q.index)   -- after judging card 1
        q:mark(false)
        assert.are.equal(2, q.index)
        q:mark(true)
        assert.are.equal(3, q.index)
        assert.is_true(q:done())
        assert.is_nil(q:current())
    end)

    it("reveal() is a no-op on an already revealed card", function()
        local q = Quiz.new{ cards = makeCards(1) }
        assert.is_true(q:reveal())
        assert.is_false(q:reveal())
    end)

    it("tracks score and misses", function()
        local q = Quiz.new{ cards = makeCards(4), shuffle = false }
        q:mark(true)   -- card 1 correct
        q:mark(false)  -- card 2 missed
        q:mark(true)   -- card 3 correct
        q:mark(false)  -- card 4 missed
        local s = q:summary()
        assert.are.equal(2, s.score)
        assert.are.equal(4, s.answered)
        assert.are.equal(50, s.percent)
        assert.are.equal(2, s.missed_count)
        assert.are.equal("q2", s.missed[1].question)
        assert.are.equal("q4", s.missed[2].question)
    end)

    it("computes percent with rounding", function()
        local q = Quiz.new{ cards = makeCards(3), shuffle = false }
        q:mark(true); q:mark(true); q:mark(false)
        assert.are.equal(67, q:summary().percent)
    end)

    it("mark() returns the next card", function()
        local q = Quiz.new{ cards = makeCards(2), shuffle = false }
        local next_card = q:mark(true)
        assert.are.equal("q2", next_card.question)
        assert.is_nil(q:mark(true))
    end)
end)

describe("Quiz early quit", function()
    it("records a partial summary when quit", function()
        local q = Quiz.new{ cards = makeCards(5), shuffle = false }
        q:mark(true)
        q:mark(false)
        q.quit = true
        local s = q:summary()
        assert.is_true(q:done())
        assert.are.equal(2, s.answered)
        assert.are.equal(1, s.score)
        assert.are.equal(1, s.missed_count)
    end)
end)

describe("Quiz.fromMissed", function()
    it("builds a fresh shuffled quiz over the missed cards", function()
        local q = Quiz.new{ cards = makeCards(6), shuffle = false, theme = "t" }
        q:mark(true)   -- 1
        q:mark(false)  -- 2 missed
        q:mark(true)   -- 3
        q:mark(false)  -- 4 missed
        local review = Quiz.fromMissed(q)
        assert.are.equal(2, review:total())
        assert.are.equal("t", review.theme)
        -- Both original missed cards are present, in either order.
        local seen = {}
        for _, c in ipairs(review.cards) do
            seen[c.question] = true
        end
        assert.is_true(seen["q2"])
        assert.is_true(seen["q4"])
        assert.are.equal(0, review.score)
        assert.are.equal(0, review.index)
    end)
end)