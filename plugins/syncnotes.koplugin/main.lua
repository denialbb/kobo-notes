local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager         = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local InputDialog       = require("ui/widget/inputdialog")
local DataStorage       = require("datastorage")
local LuaSettings       = require("luasettings")
local NetworkMgr        = require("ui/network/manager")
local JSON              = require("json")
local https             = require("ssl.https")
local ltn12             = require("ltn12")
local logger            = require("logger")
local util              = require("util")
local Manifest          = require("manifest")
local lfs               = require("libs/libkoreader-lfs")
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
  end
  if not self.settings:readSetting("notes_root") then
    self.settings:saveSetting("notes_root", DataStorage:getDataDir() .. "/notes")
  end
  self.settings:flush()
  -- Auto-detect PAT file deployed via secrets/
  self:autoDetectPatFile()
  self.ui.menu:registerToMainMenu(self)
end

--- Check for a PAT file on startup and save it to settings if not yet configured.
function SyncNotes:autoDetectPatFile()
  local pat = self:readPatFile()
  if not pat then return end
  -- Only save if no PAT is stored yet (file takes precedence)
  local saved = self.settings:readSetting("pat")
  if not saved or saved == "" then
    self.settings:saveSetting("pat", pat)
    self.settings:flush()
    logger.info("SyncNotes: PAT auto-detected from secrets/pat and saved.")
  end
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
        text = _("Set Download Path"),
        callback = function() self:onSetDownloadPath() end,
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

function SyncNotes:getNotesDir()
  local root = self.settings:readSetting("notes_root") or DataStorage:getDataDir() .. "/notes"
  local repo = self.settings:readSetting("repo") or "AI-2526"
  return root .. "/" .. repo .. "/"
end

--- Read PAT from a file in the secrets/ directory.
-- Scans secrets/ for any file (pat, pat.txt, token.txt, etc.)
-- and reads the first line as the token.
-- File location: {koreader_data_dir}/secrets/
function SyncNotes:readPatFile()
  local secrets_dir = DataStorage:getDataDir() .. "/secrets/"
  local mode = lfs.attributes(secrets_dir, "mode")
  if mode ~= "directory" then return nil end

  -- Scan for any file in the directory
  for f in lfs.dir(secrets_dir) do
    if f ~= "." and f ~= ".." then
      local path = secrets_dir .. f
      local attr = lfs.attributes(path)
      if attr and attr.mode == "file" then
        local file = io.open(path, "r")
        if file then
          local token = file:read("*l")
          file:close()
          if token and token ~= "" then
            logger.info("SyncNotes: read token from secrets/" .. f)
            return token
          end
        end
      end
    end
  end
  return nil
end

function SyncNotes:onSyncNow()
  -- 1. Try file-based token (deployed via secrets/)
  local pat = self:readPatFile()
  if pat then
    self:startSync(pat)
    return
  end
  -- 2. Fall back to saved setting
  pat = self.settings:readSetting("pat")
  if pat and pat ~= "" then
    self:startSync(pat)
    return
  end
  -- 3. Prompt user to enter one
  self:onSetToken()
end

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
              self:startSync(text)
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
              local owner, repo_branch, branch, repo
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

function SyncNotes:onSetDownloadPath()
  local current_root = self.settings:readSetting("notes_root") or DataStorage:getDataDir() .. "/notes"
  local dialog
  dialog = InputDialog:new{
    title = _("Download Path"),
    input = current_root,
    description = _("Full path where repos are synced. Repo name is appended."),
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
              self.settings:saveSetting("notes_root", text)
              self.settings:flush()
              UIManager:close(dialog)
              UIManager:show(InfoMessage:new{
                text = T(_("Download path set to: %1"), text),
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

function SyncNotes:startSync(pat)
  NetworkMgr:runWhenOnline(function()
    self:executeSync(pat)
  end)
end

function SyncNotes:httpGet(url, pat, extra_headers)
  local response_body = {}
  local headers = {
    ["Authorization"] = "token " .. pat,
    ["User-Agent"] = "KOReader-syncnotes/1.0",
    ["Accept"] = "application/vnd.github+json",
  }
  if extra_headers then
    for k, v in pairs(extra_headers) do
      headers[k] = v
    end
  end
  local res, code, response_headers, status = https.request{
    url = url,
    method = "GET",
    headers = headers,
    sink = ltn12.sink.table(response_body),
    timeout = 30,
  }
  return res, code, table.concat(response_body), status
end

--- Render an ASCII progress bar.
-- @int current  0-based or 1-based index
-- @int total    total count
-- @int width    bar width in characters (default 12)
-- @treturn string  e.g. "[####------]"
local function progressBar(current, total, width)
  width = width or 12
  if total == 0 then
    return "[" .. string.rep("-", width) .. "]"
  end
  local filled = math.max(0, math.min(math.floor(current / total * width + 0.5), width))
  return "[" .. string.rep("#", filled) .. string.rep("-", width - filled) .. "]"
end

function SyncNotes:executeSync(pat)
  local function showMsg(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 8 })
  end

  -- Show a persistent info banner that stays until we close it
  local progress

  local function setProgress(text)
    if progress then
      UIManager:close(progress)
    end
    progress = InfoMessage:new{ text = text, timeout = 0 }
    UIManager:show(progress)
    UIManager:forceRePaint()
  end

  local function done(text)
    if progress then
      UIManager:close(progress)
      progress = nil
    end
    showMsg(text, 10)
    NetworkMgr:afterWifiAction()
  end

  -- Wrap everything in pcall so no error goes silent
  local ok, err = pcall(function()
    setProgress(_("Starting sync..."))

    local owner = self.settings:readSetting("owner") or "denialbb"
    local repo = self.settings:readSetting("repo") or "AI-2526"
    local branch = self.settings:readSetting("branch") or "master"
    local notes_dir = self:getNotesDir()

    setProgress(T(_("Fetching tree: %1/%2@%3"), owner, repo, branch))

    local tree_url = string.format(
      "https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1",
      owner, repo, branch
    )
    local ok_res, code, body = self:httpGet(tree_url, pat)

    if not ok_res or code ~= 200 then
      local reason
      if code == 401 then reason = _("Bad or expired token.")
      elseif code == 403 then reason = _("Rate limited. Try again later.")
      elseif code == 404 then reason = _("Repo not found. Check owner/name.")
      else reason = T(_("HTTP %1"), tostring(code)) end
      done(T(_("Sync failed: %1"), reason))
      return
    end

    local data
    local parse_ok, parsed = pcall(JSON.decode, body)
    if not parse_ok or not parsed or not parsed.tree then
      done(_("Sync failed: Could not parse repository tree."))
      return
    end
    data = parsed

    -- Show the sync directory
    setProgress(T(_("Syncing to: %1"), notes_dir))
    -- Create notes directory and all parents
    lfs.mkdir(notes_dir:match("(.+)/[^/]+/$") or notes_dir:match("(.+)/[^/]+$") or notes_dir)
    lfs.mkdir(notes_dir)

    local manifest_file = notes_dir .. ".sync_manifest.json"

    -- Read local manifest
    local local_manifest = {}
    local mf = io.open(manifest_file, "r")
    if mf then
      local_manifest = Manifest.decodeManifest(mf:read("*a"))
      mf:close()
    end

    -- Compute changes
    local remote_files = Manifest.filterMdFiles(data)
    local remote_manifest = Manifest.buildManifest(remote_files)
    local changes = Manifest.computeChanges(local_manifest, remote_manifest)
    local to_download = changes.to_download
    local to_delete = changes.to_delete
    local total = #to_download

    if total == 0 and #to_delete == 0 then
      done(_("All notes up to date.\n\n(0 new, 0 deleted)"))
      return
    end

    -- Download each file
    for idx, entry in ipairs(to_download) do
      local bar = progressBar(idx, total)
      setProgress(bar .. " " .. T(_("%1/%2"), idx, total) .. "  " .. entry.path)

      local file_url = string.format(
        "https://raw.githubusercontent.com/%s/%s/%s/%s",
        owner, repo, branch,
        util.urlEncode(entry.path)
      )

      local local_path = notes_dir .. entry.path

      -- Create parent directories for nested paths
      local dir = notes_dir
      for sub in entry.path:gmatch("([^/]+)/") do
        dir = dir .. sub .. "/"
        lfs.mkdir(dir)
      end

      local dl_chunks = {}
      local dl_ok, http_code = https.request{
        url = file_url,
        method = "GET",
        headers = {
          ["Authorization"] = "token " .. pat,
          ["User-Agent"] = "KOReader-syncnotes/1.0",
        },
        sink = ltn12.sink.table(dl_chunks),
        timeout = 30,
      }

      if dl_ok and http_code == 200 then
        local out_file = io.open(local_path, "wb")
        if not out_file then
          done(T(_("Error: cannot create '%1'"), entry.path))
          return
        end
        out_file:write(table.concat(dl_chunks))
        out_file:close()
      end

      if not dl_ok or http_code ~= 200 then
        done(T(_("Error downloading %1: HTTP %2"), entry.path, tostring(http_code)))
        return
      end
    end

    -- Delete removed files
    for _, path_rel in ipairs(to_delete) do
      os.remove(notes_dir .. path_rel)
    end

    -- Save manifest
    local mf_out = io.open(manifest_file, "w")
    if mf_out then
      mf_out:write(Manifest.encodeManifest(remote_manifest))
      mf_out:close()
    end

    -- Done
    done(T(_("Sync complete!\n\nDownloaded: %1\nDeleted: %2\nTotal notes: %3"),
      total, #to_delete, #remote_files))
  end)

  if not ok then
    -- Lua error we didn't handle — show it on screen
    local msg = T(_("Sync error: %1"), tostring(err))
    logger.warn("SyncNotes: unhandled error:", err)
    if progress then
      UIManager:close(progress)
    end
    showMsg(msg, 15)
    NetworkMgr:afterWifiAction()
  end
end

return SyncNotes
