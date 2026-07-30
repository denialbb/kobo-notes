local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DocumentRegistry = require("document/documentregistry")
local UIManager         = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local util              = require("util")
local _                 = require("gettext")
local ReaderUI       = require("apps/reader/readerui")
local FileConverter  = require("apps/filemanager/filemanagerconverter")
local DataStorage    = require("datastorage")
local lfs            = require("libs/libkoreader-lfs")

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
    self:cleanCache()
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

return MarkdownReader
