#!/usr/bin/env lua
--[[--
Terminal flashcard quiz using the EXACT parser + quiz engine shipped in the
KOReader plugin (plugins/flashcards.koplugin). This is how you exercise the
flashcard logic locally, off the device:

    lua tools/flashcards-cli.lua [notes-root-or-file]   # interactive
    lua tools/flashcards-cli.lua [notes-root-or-file] --auto   # scripted smoke test

With --auto every card is judged "correct", nothing is read from stdin, and a
summary is printed — handy for a headless end-to-end check (the test suite
uses it). Without a path it defaults to tests/fixtures/notes.
]]

package.path = package.path .. ";./plugins/flashcards.koplugin/?.lua"
local Parser = require("parser")
local Quiz = require("quiz")

local Colors = {
    reset = "\27[0m", bold = "\27[1m",
    blue = "\27[94m", green = "\27[92m",
    yellow = "\27[93m", red = "\27[91m", cyan = "\27[96m", magenta = "\27[95m",
}

local function findFlashcardFiles(dir)
    local pipe = io.popen('find "' .. dir .. '" -type f -name flashcards.md 2>/dev/null')
    if not pipe then return {} end
    local paths = {}
    for line in pipe:lines() do
        if line ~= "" then paths[#paths + 1] = line end
    end
    pipe:close()
    table.sort(paths)
    return paths
end

local function dirName(path)
    local dir = path:match("^(.*)/[^/]+$")
    return dir and dir:match("([^/]+)$") or "flashcards"
end

local function isDir(p)
    local pipe = io.popen('test -d "' .. p .. '" && echo yes || echo no')
    local out = pipe:read("*l")
    pipe:close()
    return out == "yes"
end

local function isFile(p)
    local pipe = io.popen('test -f "' .. p .. '" && echo yes || echo no')
    local out = pipe:read("*l")
    pipe:close()
    return out == "yes"
end

local function luaDir(p)
    if isFile(p) then return "file" end
    if isDir(p) then return "dir" end
    return nil
end

-- Load { theme = { path, cards } }. A bare file arg becomes one theme.
local function loadThemes(arg)
    local themes = {}
    local mode = luaDir(arg)
    if mode == "file" then
        local f = io.open(arg, "rb")
        local cards = f and Parser.parse(f:read("*a")) or {}
        if f then f:close() end
        if #cards > 0 then
            themes[dirName(arg)] = { path = arg, cards = cards }
        end
        return themes
    end
    for _, path in ipairs(findFlashcardFiles(arg)) do
        local f = io.open(path, "rb")
        if f then
            local cards = Parser.parse(f:read("*a"))
            f:close()
            if #cards > 0 then
                themes[dirName(path)] = { path = path, cards = cards }
            end
        end
    end
    return themes
end

local auto = false
local root = nil
for _, a in ipairs(arg) do
    if a == "--auto" then auto = true
    elseif root == nil then root = a
    end
end
if not root then root = "." end

local kind = luaDir(root)
if not kind then
    io.stderr:write(("No such path: %s\n"):format(root))
    os.exit(2)
end

local themes = loadThemes(root)
local theme_names = {}
for name in pairs(themes) do theme_names[#theme_names + 1] = name end
table.sort(theme_names)

io.write(Colors.bold .. Colors.magenta .. "Welcome to the Flashcard Quiz (KOReader engine)\n" .. Colors.reset)

if #theme_names == 0 then
    io.write(Colors.red, "No flashcards.md files found.\n", Colors.reset)
    os.exit(0)
end

local deck = {}
local label = "All Themes"
if #theme_names == 1 then
    -- A single theme (or single-file run): use it directly.
    local t = themes[theme_names[1]]
    deck = t.cards
    label = theme_names[1]
else
    io.write(Colors.cyan, "Themes:\n", Colors.reset)
    for i, name in ipairs(theme_names) do
        io.write(("  [%d] %s (%d cards)\n"):format(i, name, #themes[name].cards))
    end
    io.write(("  [%d] All themes combined\n"):format(#theme_names + 1))
    local choice
    if auto then
        choice = #theme_names + 1
    else
        io.write(Colors.yellow .. "Pick a theme number: " .. Colors.reset)
        choice = tonumber((io.read() or "")) or 0
    end
    if choice == #theme_names + 1 then
        for _, name in ipairs(theme_names) do
            for _, c in ipairs(themes[name].cards) do deck[#deck + 1] = c end
        end
    elseif choice >= 1 and choice <= #theme_names then
        deck = themes[theme_names[choice]].cards
        label = theme_names[choice]
    else
        io.write(Colors.red .. "Bad choice, aborting.\n" .. Colors.reset)
        os.exit(0)
    end
end

local count = #deck
if not auto then
    io.write(("\n%d cards. Press Enter to reveal each answer, then y/n for correct/missed, q to quit.\n"):format(count))
end

local quiz = Quiz.new{ cards = deck, theme = label, shuffle = true, seed = auto and 42 or nil }

while not quiz:done() do
    local card = quiz:current()
    io.write(("\n%sCard %d/%d%s  %s(%s)%s\n"):format(
        Colors.magenta, quiz.index + 1, quiz:total(), Colors.reset,
        Colors.cyan, label, Colors.reset))
    io.write(Colors.bold .. Colors.blue .. "Q: " .. card.question .. Colors.reset .. "\n")

    if auto then
        quiz:mark(true)
        io.write("  ✓ (auto-correct)\n")
    else
        local reveal = io.read()
        if reveal == nil or reveal == "q" or reveal == "quit" then
            quiz.quit = true
            break
        end
        io.write(Colors.green .. "A: " .. card.answer .. Colors.reset .. "\n\n")
        local verdict
        repeat
            io.write(Colors.yellow .. "Got it right? (y/n): " .. Colors.reset)
            verdict = (io.read() or "q"):lower()   -- EOF counts as quit
        until verdict == "y" or verdict == "n" or verdict == "q"
        if verdict == "q" then
            quiz.quit = true
            break
        end
        quiz:mark(verdict == "y")
    end
end

local s = quiz:summary()
io.write(("\n%s%sSummary: %d/%d (%d%%)%s\n"):format(Colors.reset, Colors.bold,
    s.score, s.answered, s.percent, Colors.reset))
if s.missed_count > 0 then
    io.write(("%sMissed (%d):%s\n"):format(Colors.yellow, s.missed_count, Colors.reset))
    for _, c in ipairs(s.missed) do
        io.write("  - " .. c.question .. "\n")
    end
end

-- Machine-parseable line for the test suite.
io.write(("CARDS=%d SCORE=%d ANSWERED=%d MISSED=%d\n"):format(s.total, s.score, s.answered, s.missed_count))
os.exit(0)