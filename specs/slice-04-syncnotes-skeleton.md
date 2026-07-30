# Slice 4: syncnotes.koplugin skeleton + menu

> **Status: IMPLEMENTED — historical record (verified 2026-07-30).**
> Shipped in `plugins/syncnotes.koplugin/` (`_meta.lua`, `main.lua`).
> This is a record of how the work was sliced, not pending work.
> Divergences: the shipped menu has two extra items, "Open Notes Folder" and
> "Set Download Path"; the notes location is a configurable `notes_root`
> setting (`getNotesDir()` returns `notes_root .. "/" .. repo .. "/"`) rather
> than the hardcoded path below; and `init()` also auto-detects a PAT from
> `secrets/`.

Depends on: nothing (independent of markdownreader)

## Goal

Create the `syncnotes.koplugin` directory structure with `_meta.lua` and a functional `main.lua` that registers a Tools menu entry with "Sync Now", "Configure Repo", and "Set/Change Token" sub-items.

## Files to create

### `plugins/syncnotes.koplugin/_meta.lua`

```lua
local _ = require("gettext")
return {
    name = "syncnotes",
    fullname = _("Sync Notes"),
    description = _("Sync markdown notes from a GitHub repo over Wi-Fi. Third-party plugin."),
}
```

### `plugins/syncnotes.koplugin/main.lua`

A WidgetContainer plugin with:

1. `init()` that loads settings from `DataStorage:getSettingsDir() .. "/syncnotes.lua"`
2. Menu entries: "Sync Now", "Configure Repo" (owner/repo/branch), "Set/Change Token", "Clear Token"
3. **All handlers are stubs** that show InfoMessages (actual logic in later slices)
4. Config file `syncnotes.lua` stores: `owner`, `repo`, `branch`, `pat`
5. Settings file dedicated LuaSettings (not G_reader_settings)

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager         = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local DataStorage       = require("datastorage")
local LuaSettings       = require("luasettings")
local _                 = require("gettext")
local T                 = require("ffi/util").template

local SyncNotes = WidgetContainer:extend{
    name = "syncnotes",
    is_doc_only = false,
}

function SyncNotes:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/syncnotes.lua"
    self.settings = LuaSettings:open(self.settings_file)
    -- Set defaults if not configured
    if not self.settings:readSetting("owner") then
        self.settings:saveSetting("owner", "denialbb")
        self.settings:saveSetting("repo", "AI-2526")
        self.settings:saveSetting("branch", "master")
        self.settings:flush()
    end
    self.ui.menu:registerToMainMenu(self)
end

function SyncNotes:addToMainMenu(menu_items)
    menu_items.syncnotes = {
        text = _("Sync Notes"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Sync Now"),
                callback = function() self:onSyncNow() end,
            },
            {
                text = _("Configure Repo"),
                callback = function() self:onConfigureRepo() end,
            },
            {
                text = _("Set/Change Token"),
                callback = function() self:onSetToken() end,
            },
            {
                text = _("Clear Token"),
                callback = function()
                    self.settings:delSetting("pat")
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Token cleared."),
                        timeout = 2,
                    })
                end,
            },
        }
    }
end

function SyncNotes:onSyncNow()
    -- Stub: will be implemented in Slice 7
    UIManager:show(InfoMessage:new{
        text = _("Sync not yet implemented."),
        timeout = 3,
    })
end

function SyncNotes:onConfigureRepo()
    -- Stub: will be implemented in Slice 5
    UIManager:show(InfoMessage:new{
        text = _("Configuration dialog coming in a future slice."),
        timeout = 3,
    })
end

function SyncNotes:onSetToken()
    -- Stub: will be implemented in Slice 5
    UIManager:show(InfoMessage:new{
        text = _("Token dialog coming in a future slice."),
        timeout = 3,
    })
end

return SyncNotes
```

## Notes directory derivation

The local notes directory is derived from the repo name:
`notes/{repo}/` where `{repo}` is the configured repo name.

Helper function to add in a later slice, but note for now:

```lua
function SyncNotes:getNotesDir()
    return DataStorage:getDataDir() .. "/notes/" .. self.settings:readSetting("repo") .. "/"
end
```

## Acceptance

- Plugin appears in Tools menu under "more_tools" section
- All four menu items visible and tappable
- Each shows its stub message
- `settings/syncnotes.lua` created on first load with defaults
- Plugin management shows "Sync Notes" as toggleable
