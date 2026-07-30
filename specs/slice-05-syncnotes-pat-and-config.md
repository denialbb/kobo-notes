# Slice 5: syncnotes — PAT management + repo configuration dialogs

> **Status: IMPLEMENTED — historical record (verified 2026-07-30).**
> Shipped in `plugins/syncnotes.koplugin/main.lua`.
> This is a record of how the work was sliced, not pending work.
> Divergences: saving a token starts a sync immediately instead of showing a
> "Token saved." message; `repo` is declared `local` in the repo parser (the
> code below leaks it as a global); and a "Set Download Path" dialog was added
> alongside these two.

Depends on: Slice 4 (menu stubs exist)

## Goal

Implement the `Set/Change Token` and `Configure Repo` dialogs with `InputDialog`. Token uses `text_type = "password"` for screen masking.

## Files to modify

### `plugins/syncnotes.koplugin/main.lua`

Replace the stub `onSetToken()` and `onConfigureRepo()` with real `InputDialog` implementations.

```lua
local InputDialog = require("ui/widget/inputdialog")

function SyncNotes:onSetToken()
    local dialog
    dialog = InputDialog:new{
        title = _("Enter GitHub Personal Access Token"),
        input = "",
        text_type = "password",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        if text and text ~= "" then
                            self.settings:saveSetting("pat", text)
                            self.settings:flush()
                            UIManager:close(dialog)
                            UIManager:show(InfoMessage:new{
                                text = _("Token saved."),
                                timeout = 2,
                            })
                        end
                    end,
                },
            }
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SyncNotes:onConfigureRepo()
    local current_owner = self.settings:readSetting("owner") or "denialbb"
    local current_repo = self.settings:readSetting("repo") or "AI-2526"
    local current_branch = self.settings:readSetting("branch") or "master"

    local dialog
    dialog = InputDialog:new{
        title = _("Configure Repository"),
        input = current_owner .. "/" .. current_repo .. "@" .. current_branch,
        description = _("Format: owner/repo@branch"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        if text and text ~= "" then
                            -- Parse "owner/repo@branch" format
                            local owner, repo_branch, branch
                            local at_pos = text:find("@")
                            if at_pos then
                                branch = text:sub(at_pos + 1)
                                repo_branch = text:sub(1, at_pos - 1)
                            else
                                branch = "master"
                                repo_branch = text
                            end
                            local slash_pos = repo_branch:find("/")
                            if slash_pos then
                                owner = repo_branch:sub(1, slash_pos - 1)
                                repo = repo_branch:sub(slash_pos + 1)
                            else
                                owner = current_owner
                                repo = repo_branch
                            end
                            self.settings:saveSetting("owner", owner)
                            self.settings:saveSetting("repo", repo)
                            self.settings:saveSetting("branch", branch)
                            self.settings:flush()
                            UIManager:close(dialog)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Configured: %1/%2@%3"), owner, repo, branch),
                                timeout = 3,
                            })
                        end
                    end,
                },
            }
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end
```

## Acceptance

- "Set/Change Token" opens a password-masked InputDialog
- Token persists in settings/syncnotes.lua
- "Clear Token" removes the saved token
- "Configure Repo" opens with current value pre-filled ("denialbb/AI-2526@master")
- Entering "owner/repo@branch" saves and confirms with InfoMessage
- Entering "owner/repo" defaults branch to "master"
- Entering "repo" keeps current owner
