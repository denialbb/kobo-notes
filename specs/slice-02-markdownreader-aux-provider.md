# Slice 2: markdownreader — aux provider registration

Depends on: Slice 1 (files exist at `plugins/markdownreader.koplugin/`)

## Goal

Register the markdown reader as an auxiliary document provider for `.md` files and set the default file-type association.

## Files to modify

### `plugins/markdownreader.koplugin/main.lua`

Replace the placeholder submenu with the aux provider registration and file association logic. Keep the Tools menu entry for "Preview current file as HTML".

The main changes:

1. `init()` calls `DocumentRegistry:addAuxProvider{...}` with `callback` (module style) and `enabled_func`
2. `init()` sets `G_reader_settings.providers["md"] = "markdownreader"` on first run
3. Keep a smaller submenu with "Preview current file as HTML"
4. Add `openMarkdown(file)` — for now, just a stub that shows an InfoMessage

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DocumentRegistry = require("document/documentregistry")
local UIManager         = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local util              = require("util")
local _                 = require("gettext")

local MarkdownReader = WidgetContainer:extend{
    name = "markdownreader",
    is_doc_only = false,
}

function MarkdownReader:init()
    -- Register as auxiliary provider for .md files
    DocumentRegistry:addAuxProvider{
        provider      = self.name,
        provider_name = _("Markdown Reader"),
        order         = 25,  -- between textviewer(20) and texteditor(30)
        callback      = function(file) self:openMarkdown(file) end,
        enabled_func  = function(file)
            local suffix = util.getFileNameSuffix(file):lower()
            return suffix == "md"
        end,
        disable_file  = false,
        disable_type  = false,
    }

    -- Auto-associate .md files on first run
    local providers = G_reader_settings:readSetting("provider", {})
    if not providers["md"] then
        providers["md"] = self.name
        G_reader_settings:saveSetting("provider", providers)
        G_reader_settings:flush()
    end

    self.ui.menu:registerToMainMenu(self)
end

function MarkdownReader:addToMainMenu(menu_items)
    menu_items.markdownreader = {
        text = _("Markdown Reader"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Preview current file as HTML"),
                enabled_func = function()
                    return self.ui and self.ui.file and
                        util.getFileNameSuffix(self.ui.file):lower() == "md"
                end,
                callback = function()
                    self:openMarkdown(self.ui.file)
                end,
            },
        }
    }
end

-- Stub: will be implemented in Slice 3
function MarkdownReader:openMarkdown(file)
    UIManager:show(InfoMessage:new{
        text = _("Markdown rendering coming in next slice."),
        timeout = 3,
    })
end

return MarkdownReader
```

## Dependencies required

- `document/documentregistry`
- `ui/uimanager`
- `ui/widget/infomessage`
- `util`

These are all built-in KOReader modules.

## Acceptance

- KOReader's Open With dialog shows "Markdown Reader" for `.md` files
- Long-press a `.md` → Open With → shows both crengine and Markdown Reader
- Plugin menu shows "Preview current file as HTML" (greyed out when on non-.md)
- Tapping a `.md` file shows the stub InfoMessage (not yet rendered)
