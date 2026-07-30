# Slice 3: markdownreader — markdown rendering

> **Status: IMPLEMENTED — historical record (verified 2026-07-30).**
> Shipped in `plugins/markdownreader.koplugin/main.lua`.
> This is a record of how the work was sliced, not pending work.
> Divergences from the shipped `openMarkdown`: **LaTeX math support was added
> later** — the shipped version extracts math before `FileConverter:mdToHtml`
> and substitutes the rendered math back into the HTML afterwards, via
> `markdown_interceptor.lua` (see `docs/microtex_implementation_spec.html`).
> It also shows an "Opening Markdown..." InfoMessage, uses
> `util.splitFilePathName` (not `ffi/util`), and returns `true` on success.

Depends on: Slice 2 (aux provider + stub openMarkdown)

## Goal

Implement `openMarkdown(file)` to read a `.md` file, convert to HTML using `FileConverter:mdToHtml`, write to `cache/md/`, and open via `ReaderUI:showReader`.

## Files to modify

### `plugins/markdownreader.koplugin/main.lua`

Replace the stub `openMarkdown` with the full implementation:

```lua
function MarkdownReader:openMarkdown(file)
    -- Read the .md file content
    local f = io.open(file, "rb")
    if not f then
        UIManager:show(InfoMessage:new{
            text = _("Cannot open file."),
            timeout = 3,
        })
        return
    end
    local content = f:read("*a")
    f:close()

    -- Extract file name for the HTML title
    local _, name = require("ffi/util").splitFilePathName(file)
    local basename = name:match("(.+)%.[^%.]+$") or name

    -- Convert markdown to full HTML document
    -- FileConverter:mdToHtml(content, title, stylesheet_optional)
    local html = FileConverter:mdToHtml(content, basename, self:getStylesheet())

    -- Write to cache/md/ directory
    local tmpdir = DataStorage:getDataDir() .. "/cache/md/"
    lfs.mkdir(tmpdir)
    local out = tmpdir .. name .. ".html"
    local w = io.open(out, "w")
    if not w then
        UIManager:show(InfoMessage:new{
            text = _("Cannot write temp file."),
            timeout = 3,
        })
        return
    end
    w:write(html)
    w:close()

    -- Open via ReaderUI — crengine renders HTML natively
    ReaderUI:showReader(out)
end

-- Clean up stale HTML cache on plugin init (Cache is small, but keep it tidy)
-- Call this at end of init() after the provider registration
function MarkdownReader:cleanCache()
    local cachedir = DataStorage:getDataDir() .. "/cache/md/"
    if lfs.attributes(cachedir, "mode") == "directory" then
        for f in lfs.dir(cachedir) do
            if f ~= "." and f ~= ".." then
                os.remove(cachedir .. "/" .. f)
            end
        end
    end
end
```

### New requires needed in main.lua

Add these to the top of main.lua:

```lua
local ReaderUI       = require("apps/reader/readerui")
local FileConverter  = require("apps/filemanager/filemanagerconverter")
local DataStorage    = require("datastorage")
local lfs            = require("libs/libkoreader-lfs")
```

### E-ink stylesheet

Add a `getStylesheet()` method with e-ink-friendly CSS:

```lua
function MarkdownReader:getStylesheet()
    return [[
body {
    font-family: serif;
    font-size: 1em;
    line-height: 1.5;
    color: #000;
    background: #fff;
    margin: 1em;
}
h1 { font-size: 1.6em; margin: 0.8em 0 0.4em; }
h2 { font-size: 1.3em; margin: 0.7em 0 0.3em; }
h3 { font-size: 1.15em; margin: 0.6em 0 0.3em; }
code, pre {
    font-family: monospace;
    background: #eee;
    color: #000;
}
pre {
    padding: 0.5em;
    overflow-x: auto;
}
code { padding: 0.1em 0.3em; }
pre code { padding: 0; background: none; }
blockquote {
    border-left: 3px solid #ccc;
    margin-left: 0;
    padding-left: 1em;
    color: #333;
}
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ccc; padding: 0.4em; }
th { background: #eee; }
ul, ol { padding-left: 1.5em; }
a { color: #000; text-decoration: underline; }
]]
end
```

Future enhancement: load stylesheet from settings file. For v1, hardcode this default.

## init() should call cleanCache

Add `self:cleanCache()` at the end of `init()`.

## Acceptance

- Tapping a `.md` file opens it rendered via crengine (headings, bold, lists, code, tables)
- HTML cache is cleaned on every KOReader restart
- "Preview current file as HTML" from the menu also opens the rendered version
- Non-.md files are unaffected (textviewer / crengine handles them as before)
- Opening the same `.md` twice in one session regenerates the HTML (fresh each time)
