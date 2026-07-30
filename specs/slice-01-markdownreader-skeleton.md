# Slice 1: markdownreader.koplugin skeleton + menu

> **Status: IMPLEMENTED — historical record (verified 2026-07-30).**
> Shipped in `plugins/markdownreader.koplugin/` (`_meta.lua`, `main.lua`).
> This is a record of how the work was sliced, not pending work.
> Divergence: the `Placeholder` sub-item below was replaced in Slice 2 by
> "Preview current file as HTML"; nothing else changed.

## Goal

Create the directory structure and files for `markdownreader.koplugin` so it appears in KOReader's Tools menu and is toggleable in Plugin management.

## Acceptance criteria

- Plugin appears in Tools menu with a static entry (just a placeholder submenu)
- Plugin shows in Plugin management (Settings → Plugin management) as toggleable
- No errors on KOReader startup (check with `logger.warn` or inspect KOReader crash.log)

## Files to create

### `plugins/markdownreader.koplugin/_meta.lua`

```lua
local _ = require("gettext")
return {
    name = "markdownreader",
    fullname = _("Markdown Reader"),
    description = _("Render Markdown (.md) files as formatted HTML. Third-party plugin."),
}
```

### `plugins/markdownreader.koplugin/main.lua`

A minimal WidgetContainer plugin that registers an empty submenu item in the Tools menu:

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local MarkdownReader = WidgetContainer:extend{
    name = "markdownreader",
    is_doc_only = false,
}

function MarkdownReader:init()
    self.ui.menu:registerToMainMenu(self)
end

function MarkdownReader:addToMainMenu(menu_items)
    menu_items.markdownreader = {
        text = _("Markdown Reader"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Placeholder"),
                callback = function()
                end,
            },
        }
    }
end

return MarkdownReader
```

## Style

- No underscores in function/variable names where KOReader convention uses camelCase
- Follow existing plugin patterns (reference `plugins/texteditor.koplugin/main.lua`)
- 2-space indentation
- Single blank line between function definitions

## Verification

1. Copy plugins/ to /mnt/kobo/.adds/koreader/plugins/ (USB mount)
2. Restart KOReader on device
3. Tools menu shows "Markdown Reader" with a "Placeholder" sub-item
4. Plugin management shows "Markdown Reader" as toggleable
5. No errors in KOReader crash.log

## Constraints

- Pure Lua 5.1, no external dependencies
- Must not error when loaded (must not require nonexistent modules)
- Only KOReader built-in modules may be required
