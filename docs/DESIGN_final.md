# Project Design: AI-2526 Notes on Kobo (Final)

**Status:** Implemented & deployed · **Date:** 2026-07-30  
**Target device:** Kobo e-reader with **KOReader v2026.07** at `/mnt/kobo/.adds/koreader`  
**Reference source:** `/mnt/kobo/.adds/koreader/` — the deployed device install
(`git-rev` → `v2026.07`). The full KOReader Lua frontend ships on the device, so
the device *is* the reference source.  
**Original draft:** `/tmp/kobo-research/PROJECT_OVERVIEW.md` — superseded by this document  

**Reviewer findings:** Every API claim in the original draft was verified against
a KOReader source clone at `~/.repos/koreader` (HEAD `574fe9f`). Thirteen
corrections and six open questions resolved below.

**⚠️ Re-verification, 2026-07-30:** that source clone **no longer exists**, and
the device has since been updated from v2025.10 to **v2026.07**. Every source
citation in this document was therefore re-verified with `rg -n` against the
device's own `frontend/` tree at `/mnt/kobo/.adds/koreader/`. All source
citations are now relative to `/mnt/kobo/.adds/koreader/`. Line numbers that
moved have been corrected in place; see §2 and Appendix A for the ones that
changed. **Every entry point we depend on is still present in v2026.07 with the
signature this document records** — `addAuxProvider`, `mdToHtml`, `openFile`
dispatch, `showReader`, `runWhenOnline`, `afterWifiAction`. One incidental
citation went stale: `newsdownloader.koplugin` no longer calls
`UIManager:forceRePaint()` at all (see §5.6).

*Scope of that claim:* the v2025.10 tree is gone, so this is **not** a
version-to-version diff. What was checked is the current v2026.07 source against
the signatures recorded here — sufficient to establish that the design still
holds on the deployed device, which is what matters, but it cannot rule out a
signature that changed in a way the original review recorded imprecisely.

**Repository layout note:** the two plugins live in **separate git submodule
repos**, each with its own remote:

| Path | Remote |
| --- | --- |
| `plugins/markdownreader.koplugin` | `git@github.com:denialbb/markdownreader.koplugin.git` |
| `plugins/syncnotes.koplugin` | `git@github.com:denialbb/syncnotes.koplugin.git` |

Clone with `git clone --recurse-submodules`, or run `git submodule update --init`
afterwards — a plain clone leaves both plugin directories empty.

---

## Table of Contents

1. [Objectives](#1-objectives)
2. [Verified constraints (reviewed)](#2-verified-constraints-reviewed)
3. [Background & problem](#3-background--problem)
4. [Use cases & user stories](#4-use-cases--user-stories)
5. [Decisions](#5-decisions)
6. [Plugin A: markdownreader.koplugin](#6-plugin-a-markdownreaderkoplugin)
7. [Plugin B: syncnotes.koplugin](#7-plugin-b-syncnoteskoplugin)
8. [Open questions (answered)](#8-open-questions-answered)
9. [Testing & verification plan](#9-testing--verification-plan)
10. [Risks & mitigations](#10-risks--mitigations)
11. [Implementation task breakdown (TDD slices)](#11-implementation-task-breakdown-tdd-slices)

---

## 1. Objectives

1. **Read** the Markdown (`.md`) notes from a private GitHub repo (AI-2526)
   **formatted** (headings, bold, lists, links, code, tables) on the Kobo e-ink
   screen, integrated into KOReader so opening a note is a single tap.
2. **Sync** those notes from the private repo **from the Kobo itself** with one
   menu action (no PC in the loop), over Wi-Fi, keeping the set of local files in
   sync with the repo's `master` branch (add/update/delete).
3. Achieve (1) and (2) **without cross-compiling anything** — pure-Lua koplugins
   dropped into `plugins/`, reusing KOReader internals. No rebuild, no OTA.
4. Keep the Kobo passive-friendly: battery-conserving, on-demand sync, no
   background daemons.

**Non-objectives (explicitly out of scope):**

- Pushing changes *from* the Kobo back to the repo (read-only sync).
- Rendering markdown inside book highlights/annotation notes (that's PR
  #15588/#15599, a different feature; we do not touch annotations).
- A general-purpose git client on the Kobo.
- Syncthing or any always-on background sync.

---

## 2. Verified constraints (reviewed)

Each constraint verified against the deployed device source at
`/mnt/kobo/.adds/koreader` (re-verified 2026-07-30 against **v2026.07**).
Corrections flagged with **⚠️**.

| Constraint | Status | Evidence |
| --- | --- | --- |
| Kobo runs KOReader **v2026.07** | ✅ | `/mnt/kobo/.adds/koreader/git-rev` → `v2026.07` (was `v2025.10` at original review; device updated since) |
| `.md` opens as **plain text** today (crengine has no md parser) | ✅ | `credocument.lua:1609` — `registry:addProvider("md", "text/plain", self)` (no weight → defaults to 100, same as html) |
| No `git` binary on Kobo OS | ✅ | `/mnt/kobo/.adds/koreader/` contains `dropbear`, `dbclient`, `sftp-server` — no git; rootfs inaccessible |
| HTTPS + JSON available in Lua | ✅ | `socket.http` at `common/socket.lua`; `ssl.https` at `common/ssl/https.lua`; `require("json")` used by `plugins/wallabag.koplugin/main.lua:23`; `require("ssl.https")` used by `frontend/socketutil.lua:8`; `require("ltn12")` by `/tmp/kobo-research/a-on-device-sync.txt` pattern and many built-in plugins |
| Pure-Lua markdown parser is bundled | ✅ | `frontend/apps/filemanager/lib/md.lua` (vendored `bakpakin/luamd`, 533 lines); `FileConverter:mdToHtml` at `filemanagerconverter.lua:41-55` wraps it into full HTML document |
| Plugins are hot-loaded, no rebuild | ✅ | `frontend/pluginloader.lua` — discovers `*.koplugin/` in `data_dir/plugins/`; user plugins enabled by default; toggle via Tools → Plugin management (see pluginloader.lua:174-232, 273-293) |
| Aux document providers are a supported seam | ✅ | `DocumentRegistry:addAuxProvider(provider)` at `documentregistry.lua:55` — precedents: texteditor.koplugin (order 30), archiveviewer (order 40), imageviewer (order 10), textviewer (order 20) |
| FileManager dispatches to aux providers | ✅ | `FileManager:openFile` at `filemanager.lua:1614-1637` — supports **both** `provider.callback(file)` (module style, used by imageviewer.lua:901) and `self[provider.provider]:openFile(file)` (plugin style, used by texteditor.koplugin:63) |
| `ReaderUI:showReader(file, provider, seamless, is_provider_forced, after_open_callback)` opens a doc | ✅ | `readerui.lua:616` — also has `showReaderCoroutine` at 711 for async |
| Wi-Fi must be requested safely | ✅ | `NetworkMgr:runWhenOnline(cb)` at `manager.lua:698`; `NetworkMgr:afterWifiAction(cb)` at `manager.lua:621`; used by `newsdownloader.koplugin:195`, `wallabag.koplugin` pattern |
| UI is single-threaded; show progress + `UIManager:forceRePaint()` before blocking | ✅ | `dev-bestpractices.txt` §5; confirmed in `readerui.lua:718` (`UIManager:forceRePaint()` before blocking op; note it's **after** the InfoMessage `UIManager:show` at 712) |
| Private repo needs auth for raw download | ✅ | GitHub API docs — `raw.githubusercontent.com` for private repos requires `Authorization: token <PAT>` |
| GitHub authenticated REST limit: 5000 req/h; tree is 1 call; raw downloads don't count against REST | ✅ | GitHub REST API docs — tree API counted, raw downloads are infrastructure (not REST) |
| OTA preserves user plugins | ✅ | OTA cleanup at `koreader.sh:129` (repo path `platform/kobo/koreader.sh`; on the device it is installed at the install root) — `grep -xvFf` compares old vs new `package.index`; user plugins are **never** in package.index, so they're invisible to the diff and never deleted |
| **⚠️ FileManager:openFile line number** | ❌ | Original doc claimed line 1551. Actual location: `filemanager.lua:1614` |
| **⚠️ NetworkMgr:afterWifiAction line number** | ❌ | Original doc claimed line 605. `beforeWifiAction` is at 605; `afterWifiAction` is at **621** |
| **⚠️ "latest stable KOReader = v2026.07"** | ✅ **RESOLVED 2026-07-30** | Originally marked UNVERIFIED (device was v2025.10, source clone was shallow with no tags, no OTA-server check performed) with a recommendation to drop the claim. It is now settled by observation rather than by argument: the device has been updated and `/mnt/kobo/.adds/koreader/git-rev` reads `v2026.07`. The original reasoning still held — nothing broke on update, because every API we depend on is unchanged (see the header re-verification note). |
| **⚠️ Reference source clone `~/.repos/koreader` (HEAD `574fe9f`)** | ❌ **GONE** | The clone the original review cited no longer exists on disk. All ~30 file:line citations were re-verified on 2026-07-30 against the device's own `frontend/` tree, which ships the complete v2026.07 Lua source. Corrected line numbers are folded into this document; the ones that moved are listed in Appendix A. |
| **⚠️ Sync plugin named `aiactions_sync.koplugin`** | ❌ | The plugin's real name — in this repo, on the device, and in its own submodule remote — is **`syncnotes.koplugin`** (`main.lua`, `manifest.lua`, `_meta.lua`). All occurrences corrected in §7. |
| **⚠️ `newsdownloader.koplugin` cited as a `forceRePaint` precedent** | ❌ | In v2026.07 `plugins/newsdownloader.koplugin/main.lua` contains **no** call to `UIManager:forceRePaint()` (verified: `rg -n forceRePaint` → no matches). It still uses `NetworkMgr:runWhenOnline` at `main.lua:195`. The forceRePaint pattern itself is unaffected — it remains in core at `readerui.lua:718` — but that specific plugin is no longer an example of it. See §5.6. |
| **⚠️ `DocumentRegistry:addAuxProvider` call signature** | ❌ | `b-md-reader-plugin.txt` calls `addAuxProvider("md", "text/markdown", {...})` (3 args). The actual API is `addAuxProvider(provider_table)` — **ONE** argument at `documentregistry.lua:55`. See also `plugins/texteditor.koplugin/main.lua:50` and `plugins/archiveviewer.koplugin/main.lua:42`. |

---

## 3. Background & problem

The user keeps university course notes (AI-2526) in a private GitHub repo as `.md`
files. They want to read these on their Kobo. KOReader v2026.07 still cannot render `.md`
formatted out of the box (crengine registers `.md` as `text/plain`), and the Kobo
has no git client. The deployed install already ships every primitive we need:
a Lua markdown parser (`md.lua`), an HTML rendering engine (crengine), HTTPS
(`ssl.https` + `socket.http`), JSON (`json`), WiFi management (`NetworkMgr`),
and a plugin system. **The work is to wire these together with two small koplugins,
not to build anything new.**

---

## 4. Use cases & user stories

### UC-1: Read a note, formatted
>
> As a student, I tap `notes/Lecture-03.md` in the KOReader file manager and it
> opens showing formatted headings, bold, bullet lists, and code blocks — like
> an EPUB — not raw `#`/`**` characters.

**Acceptance:** Tapping any `.md` under the notes folder opens it rendered via
crengine (HTML). Long-press still allows *Open with → plain text* if desired.

### UC-2: Sync notes from the Kobo
>
> As a student, I open the KOReader tools menu and tap **"Sync AI-2526 notes"**.
> Wi-Fi turns on if needed; new/changed notes download from GitHub; notes deleted
> in the repo are removed locally; a progress message shows what's happening.

**Acceptance:** After sync, the local notes folder exactly mirrors the set of
`.md` files (paths + contents) on `master` of the private repo. No PC involved.

### UC-3: Configure credentials once
>
> As a student, the first time I sync I'm prompted to paste a GitHub Personal
> Access Token (read-only, scoped to AI-2526). It's stored locally and reused.

**Acceptance:** PAT stored in a dedicated plugin `LuaSettings` file (not
`settings.reader.lua`); editable/clearable from the plugin menu; entered with
password masking via `InputDialog` (`text_type = "password"`).

### UC-4: Update KOReader (supporting)
>
> As a user I want to update KOReader itself (e.g. to gain native markdown in the
> annotation viewer) without losing my plugins or notes.

**Acceptance:** Use built-in OTA (*Settings → Update → Check for updates*) or
manual USB tarball replace; user-installed plugins in `plugins/` and all
`settings/` are preserved by OTA (cleanup only deletes files tracked in the old
`package.index`, see `platform/kobo/koreader.sh:129`).

---

## 5. Decisions

### 5.1 Option A (aux provider + temp HTML) vs Option B (custom MarkdownDocument)

**FIRM RECOMMENDATION: Option A**

Rationale:

- All four existing precedents (`texteditor.koplugin`, `archiveviewer.koplugin`,
  `imageviewer.lua:894`, `textviewer.lua:915`) use the aux provider seam.
  Option B has **zero** precedents in the 560+ KL commit history.
- Option B would require implementing the full `Document` interface (open, pages,
  getPageDimensions, render, etc.) and interfacing with crengine's C++
  `Credocument` directly — extremely complex and fragile. The `Document` class is
  tightly coupled to the C FFI layer (see `frontend/document/`).
- The "temp `.html` path in history" concern is largely cosmetic: crengine renders
  the HTML identically, and the user navigates by note title, not path. If the
  `.html` filename really bothers us, we can name it after the `.md` file with a
  `.html` extension which is normal and expected.

### 5.2 One plugin vs two

**FIRM RECOMMENDATION: Two plugins**

| Aspect | Combined | Two plugins |
| --- | --- | --- |
| SRP | Couples rendering and syncing | Each does one thing |
| Independent use | Can't use one without other | Reader works for any .md; sync works for any GitHub md repo |
| Complexity | Single ~400-line file | Two ~150-line files |
| Enable/disable | All or nothing | Per-feature toggle |
| Testing | Larger surface per spec file | Separated specs |

Two plugins also means each can be developed, tested, and released independently.
The sync plugin is useful even without the reader (sync first, open manually),
and the reader is useful for any `.md` files from any source.

### 5.3 addAuxProvider callback shape

**Use `callback` field (module style)** — as demonstrated by `imageviewer.lua:901`
and `textviewer.lua:922`. The callback is a closure capturing the plugin instance:

```lua
callback = function(file) self:openFile(file) end
```

This is simpler than the plugin method dispatch (`self[provider.provider]:openFile`)
which requires the plugin to be registered via `self:registerModule()` — though
that works too. Both are supported at `filemanager.lua:1625-1630`.

ALSO required: `enabled_func` (matching the callback style), returning `true` for
`.md` files. For plugin-style, `isFileTypeSupported` is used instead.
See `filemanager.lua:1499-1502`:

```lua
if provider.enabled_func then -- module
    is_filetype_supported = provider.enabled_func(file)
else -- plugin
    is_filetype_supported = self[provider.provider]:isFileTypeSupported(file)
end
```

### 5.4 Reusing FileConverter:mdToHtml vs calling luamd directly

**Use `FileConverter:mdToHtml`** (`filemanagerconverter.lua:41-55`). The
module-level dependencies are `ButtonDialog`, `ConfirmBox`, `UIManager`, `lfs`,
`logger`, `util`, `gettext`, `ffi/util` — **none** of these create a circular
dependency or require FileManager context. The function wraps the luamd output
in a full HTML document with proper `<!DOCTYPE>`, `<html>`, `<head>`, `<title>`,
optional `<style>`, `<body>`. If the wrapper format changes in a future KOReader
version, our plugin stays in sync automatically.

**Fallback:** if `FileConverter` ever becomes unavailable, call `md.lua`
directly:

```lua
local MD = require("apps/filemanager/lib/md")
local html, err = MD(markdown, {
    prependHead = "<!DOCTYPE html>\n<html>\n<head>\n",
    insertHead = string.format("<title>%s</title>\n</head>\n<body>\n", title),
    appendTail = "\n</body>\n</html>",
})
```

But this is a maintenance burden — **start with FileConverter**.

### 5.5 PAT storage

**Dedicated LuaSettings file** at `DataStorage:getSettingsDir() .. "/syncnotes.lua"`.
This is the standard KOReader pattern for plugin settings (see
`dev-bestpractices.txt` §5, `plugins/kosync.koplugin/main.lua:26`, and
`frontend/luasettings.lua:89`). It avoids polluting `settings.reader.lua` and
allows easy reset/clear.

The PAT should be a **fine-grained read-only token** scoped to the AI-2526 repo
only, following the principle of least privilege. Document this prominently.

### 5.6 Sync blocking strategy

**Synchronous with `UIManager:forceRePaint()` progress updates** — the canonical
example in v2026.07 is core: `readerui.lua:718`, where `forceRePaint()` is called
right after showing an `InfoMessage` and immediately before a long blocking
operation. **⚠️ Corrected 2026-07-30:** the original doc cited
`newsdownloader.koplugin/main.lua:195,430,434` as the precedent. In v2026.07 that
plugin no longer calls `forceRePaint()` anywhere (`rg -n forceRePaint` → no
matches); only its `NetworkMgr:runWhenOnline` usage at `main.lua:195` still
stands. `wallabag.koplugin` and `exporter.koplugin` remain WiFi/REST precedents.
For hundreds of small `.md` files
(typical university notes: ~2-20 KB each), total sync time is under a minute.
The user explicitly invokes sync and expects a brief wait.

If future measurements show unacceptable blocking, adopt coroutine chunking as
demonstrated by `ReaderUI:showReaderCoroutine` at `readerui.lua:711-736` and
the `kosync.koplugin` pattern (see `plugins/kosync.koplugin/`). But start simple.

---

## 6. Plugin A: markdownreader.koplugin

### 6.1 Directory structure

```
/mnt/kobo/.adds/koreader/plugins/markdownreader.koplugin/
├── _meta.lua
├── main.lua
├── markdown_interceptor.lua   # math extraction / substitution (see §6.6)
├── math_renderer.lua          # backend facade + content-addressed cache
└── math_backend_lua.lua       # pure-Lua LaTeX subset → unicode/HTML
```

The three math modules are described in §6.6; the original design in §6.2–§6.5
below covers the `_meta.lua`/`main.lua` core and is unchanged by them.

### 6.2 `_meta.lua`

```lua
local _ = require("gettext")
return {
    name = "markdownreader",
    fullname = _("Markdown Reader"),
    description = _("Render Markdown files as formatted HTML when opened."),
}
```

### 6.3 `main.lua`

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DocumentRegistry = require("document/documentregistry")
local ReaderUI          = require("apps/reader/readerui")
local FileConverter     = require("apps/filemanager/filemanagerconverter")
local UIManager         = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local DataStorage       = require("datastorage")
local util              = require("util")
local lfs               = require("libs/libkoreader-lfs")
local _                 = require("gettext")

local MarkdownReader = WidgetContainer:extend{
    name = "markdownreader",
    is_doc_only = false, -- ensure loaded in FileManager
}

function MarkdownReader:init()
    -- Register as auxiliary provider for markdown files.
    -- Uses the "module" pattern (callback + enabled_func) similar to imageviewer.lua:894-906
    -- and textviewer.lua:915-928.
    DocumentRegistry:addAuxProvider{
        provider      = self.name,   -- key: must match plugin name / directory name
        provider_name = _("Markdown Reader"),
        order         = 25,          -- between textviewer(20) and texteditor(30)
        callback      = function(file) self:openMarkdown(file) end,
        enabled_func  = function(file)
            local suffix = util.getFileNameSuffix(file):lower()
            return suffix == "md"
        end,
        disable_file  = false,       -- allow "Always for this file"
        disable_type  = false,       -- allow "Always for this file type"
    }

    -- Auto-associate .md files with this provider on first run.
    -- This ensures tapping a .md file immediately opens it rendered.
    local providers = G_reader_settings:readSetting("provider", {})
    if not providers["md"] then
        providers["md"] = self.name
        G_reader_settings:saveSetting("provider", providers)
        G_reader_settings:flush()
    end

    -- Register the "Convert to HTML" menu entry
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

    -- Convert markdown to full HTML document using the bundled converter.
    -- FileConverter:mdToHtml accepts (markdown_string, title, stylesheet_optional).
    -- It produces: <!DOCTYPE html><html><head><title>...</title><style>...</style></head><body>...</body></html>
    -- See filemanagerconverter.lua:41-55.
    local html = FileConverter:mdToHtml(content, basename)

    -- Write to a persistent cache directory (not /tmp — could be volatile on Kobo).
    -- Using cache/md/ under the data directory ensures the .html file survives restarts.
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

    -- Open via ReaderUI — crengine renders the HTML natively.
    -- showReader(file, provider, seamless, is_provider_forced, after_open_callback)
    ReaderUI:showReader(out)
end

return MarkdownReader
```

### 6.4 How it works

1. On installation and restart, `PluginLoader` discovers
   `markdownreader.koplugin/`, loads `main.lua`, creates an instance with
   `ui = FileManager` (see `filemanager.lua:417-424`).
2. `init()` calls `DocumentRegistry:addAuxProvider{...}` registering the plugin
   with `callback` (module style).
3. `init()` also sets the default file-type association `providers.md = "markdownreader"`
   via `G_reader_settings` so tapping `.md` files goes through our provider.
4. When user taps a `.md` file: `FileManager:openFile` →
   `DocumentRegistry:getProvider(file, true)` → returns our provider (via
   `getAssociatedProviderKey` because of the file-type association) → checks
   `provider.order` (aux) → calls `provider.callback(file)` → our
   `self:openMarkdown(file)`.
5. `openMarkdown` reads the `.md`, converts to HTML via
   `FileConverter:mdToHtml`, writes to `cache/md/`, opens via `ReaderUI:showReader`.

### 6.5 File association management

- **First run:** sets `G_reader_settings.provider.md = "markdownreader"` globally
  for all `.md` files. The user can override per-file or per-type via
  long-press → *Open with...* (see `DocumentRegistry:setProvider` at
  `documentregistry.lua:210-222` and the Open With dialog at
  `filemanager.lua:1471-1612`).
- **Reset:** user can tap *Reset default for .md files* in the Open With dialog,
  which removes the association at `filemanager.lua:1528-1531`.
- **Fallback:** without the association, user can always long-press → *Open with*
  → select Markdown Reader for one-off use.

### 6.6 LaTeX math rendering (added post-v1)

University notes are full of `$...$` and `$$...$$`. luamd knows nothing about
math, and crengine has no TeX engine, so formulas previously reached the screen
as raw LaTeX source. The plugin now renders a useful subset of LaTeX **in pure
Lua** — which is what preserves objective 3 ("without cross-compiling anything").

#### Pipeline

```
.md file
   │
   ├─ markdown_interceptor.lua  — extract $...$ / $$...$$ → placeholder tokens
   │
   ├─ FileConverter:mdToHtml    — luamd renders the (math-free) markdown
   │
   ├─ markdown_interceptor.lua  — substitute tokens with rendered HTML
   │
   └─ ReaderUI:showReader       — crengine renders the resulting .html
```

**Why extraction happens *before* conversion:** luamd treats `_`, `*` and `\` as
markup. Left in place, `$a_1 * b^*$` would be mangled into emphasis tags before
math ever saw it. Extracting first turns each formula into an inert placeholder
token that survives luamd untouched.

**Why substitution happens *after* conversion:** the token is replaced with a
finished HTML fragment. Keeping this step post-conversion means a backend is free
to return either inline HTML (the pure-Lua backend) or an `<img>` element (a
future rasterising backend) without the markdown layer caring which.

#### Modules

| Module | Responsibility |
| --- | --- |
| `markdown_interceptor.lua` | Scans the source for math spans, replaces them with tokens, and substitutes rendered output back in after `mdToHtml`. Owns all the `$`-disambiguation rules below. |
| `math_renderer.lua` | Backend facade plus a content-addressed cache. Hashing is **djb2**, chosen so the module has **no dependency on the `bit` library** (which is not uniformly available across the Lua versions we test on). |
| `math_backend_lua.lua` | The pure-Lua backend: a LaTeX subset translated to unicode and simple HTML. |

The facade in `math_renderer.lua` is a deliberate **backend seam**. A native
MicroTeX backend is designed but **DEFERRED** — it would require cross-compiling
a C++ library for the Kobo, which objective 3 rules out for v1. The design for it
lives in `docs/microtex_implementation_spec.html`.

#### Cache

Rendered math is cached under
`DataStorage:getDataDir() .. "/cache/md/math/"`, keyed by content hash — the same
formula appearing in fifty notes is rendered once.

#### Inline `$` disambiguation

Prose contains dollar signs. A `$` opens a math span only if **all** of:

- it is not backslash-escaped;
- the next character is neither whitespace nor a digit — this is what rejects
  `costs $5`;
- the preceding character is not alphanumeric.

The search for the closing `$` **aborts at a blank line**, so an unmatched `$`
cannot swallow the rest of the document. Math inside **fenced code blocks** and
inside **inline code spans** is not extracted.

**Known gap:** 4-space-indented code blocks are **not** detected, so a `$` inside
one will still be extracted as math. This is the one known false positive.

#### Graceful degradation

Unsupported constructs — `\begin{cases}`, matrices, `align` environments — are
not failures: they render as **monospace LaTeX source**, which is still readable.
Beyond that, the entire math path in `main.lua` is wrapped in `pcall`, so a math
failure **can never prevent a document from opening**. Worst case, the note opens
with its formulas as plain text.

#### Measured behaviour

Measured against the user's real corpus:

| Metric | Value |
| --- | --- |
| Files | 75 |
| Formulas | 4952 |
| Errors | 0 |
| Degraded to source | 1.7% |
| Heaviest note | 72 KB, 795 formulas |
| Heaviest note, full pipeline | ~250 ms on desktop |

Expect the on-device figure to be several times the desktop number — the Kobo's
CPU is far slower — but this is a one-off cost per note open, and cached math
makes re-opens cheaper.

---

## 7. Plugin B: syncnotes.koplugin

### 7.1 Directory structure

```
/mnt/kobo/.adds/koreader/plugins/syncnotes.koplugin/
├── _meta.lua
├── main.lua
└── manifest.lua   # SHA-manifest read/write/diff, extracted for unit testing
```

### 7.2 `_meta.lua`

```lua
local _ = require("gettext")
return {
    name = "syncnotes",
    fullname = _("Sync AI-2526 Notes"),
    description = _("Syncs markdown notes from github.com/denialbb/AI-2526.git master branch over Wi-Fi."),
}
```

### 7.3 `main.lua`

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager         = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local InputDialog       = require("ui/widget/inputdialog")
local NetworkMgr        = require("ui/network/manager")
local DataStorage       = require("datastorage")
local LuaSettings       = require("luasettings")
local JSON              = require("json")
local https             = require("ssl.https")
local ltn12             = require("ltn12")
local util              = require("util")
local lfs               = require("libs/libkoreader-lfs")
local logger            = require("logger")
local _                 = require("gettext")
local T                 = require("ffi/util").template

--- Plugin: Sync AI-2526 notes from GitHub to Kobo over Wi-Fi.
-- Uses GitHub REST Tree API for incremental sync with SHA-based manifest.
-- No git binary needed — pure HTTPS/JSON.
local SyncNotes = WidgetContainer:extend{
    name = "syncnotes",
    is_doc_only = false,

    -- Default local root for synced notes. Portable across devices.
    notes_dir = DataStorage:getDataDir() .. "/notes/AI-2526/",
    manifest_file = DataStorage:getDataDir() .. "/notes/AI-2526/.sync_manifest.json",

    -- GitHub config
    repo_owner = "denialbb",
    repo_name  = "AI-2526",
    repo_branch = "master",
}

function SyncNotes:init()
    -- Load settings from dedicated file (not G_reader_settings).
    self.settings_file = DataStorage:getSettingsDir() .. "/syncnotes.lua"
    self.settings = LuaSettings:open(self.settings_file)

    self.ui.menu:registerToMainMenu(self)
end

function SyncNotes:addToMainMenu(menu_items)
    menu_items.syncnotes = {
        text = _("Sync AI-2526 Notes"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Sync Now"),
                callback = function() self:onSyncTriggered() end,
            },
            {
                text = _("Set/Change GitHub Token"),
                callback = function() self:promptForToken() end,
            },
            {
                text = _("Clear GitHub Token"),
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

function SyncNotes:onSyncTriggered()
    local pat = self.settings:readSetting("pat")
    if not pat or pat == "" then
        self:promptForToken()
    else
        self:startSync(pat)
    end
end

function SyncNotes:promptForToken()
    local dialog
    dialog = InputDialog:new{
        title = _("Enter GitHub Personal Access Token"),
        input = "",
        -- Mask the token on screen so it's not visible to bystanders
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

function SyncNotes:startSync(pat)
    -- Wrap the sync in NetworkMgr:runWhenOnline which prompts for WiFi if off
    -- and waits until we're connected.
    -- See manager.lua:698-700.
    NetworkMgr:runWhenOnline(function()
        self:executeSync(pat)
    end)
end

--- Perform a single synchronous HTTP GET request.
-- @string url
-- @string pat  GitHub token
-- @tparam[opt] table extra_headers  additional HTTP headers
-- @treturn boolean success
-- @treturn number HTTP status code
-- @treturn string response body
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
        -- 30-second timeout per request
        timeout = 30,
    }
    return res, code, table.concat(response_body), status
end

function SyncNotes:executeSync(pat)
    -- Phase 1: show progress
    local progress = InfoMessage:new{
        text = _("Fetching repository tree..."),
        timeout = 0,  -- persistent until we close it
    }
    UIManager:show(progress)
    UIManager:forceRePaint()  -- critical: redraw before blocking I/O

    -- Phase 2: fetch remote git tree (recursive, one call)
    local tree_url = string.format(
        "https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1",
        self.repo_owner, self.repo_name, self.repo_branch
    )
    local ok, code, body, status = self:httpGet(tree_url, pat)

    if not ok or code ~= 200 then
        if code == 401 then
            progress:setText(_("Sync failed: Bad or expired token."))
        elseif code == 403 then
            progress:setText(_("Sync failed: Rate limited. Try again later."))
        elseif code == 404 then
            progress:setText(_("Sync failed: Repository not found (check owner/name)."))
        else
            progress:setText(T(_("Sync failed: HTTP %1"), tostring(code)))
        end
        progress.timeout = 5
        UIManager:close(progress)
        NetworkMgr:afterWifiAction()
        return
    end

    local data
    ok, data = pcall(JSON.decode, body)
    if not ok or not data or not data.tree then
        progress:setText(_("Sync failed: Could not parse repository tree."))
        progress.timeout = 5
        UIManager:close(progress)
        NetworkMgr:afterWifiAction()
        return
    end

    -- Phase 3: ensure notes directory exists
    lfs.mkdir(DataStorage:getDataDir() .. "/notes/")
    lfs.mkdir(self.notes_dir)

    -- Phase 4: read local SHA manifest
    local local_manifest = {}
    local mf = io.open(self.manifest_file, "r")
    if mf then
        local m_content = mf:read("*a")
        mf:close()
        pcall(function() local_manifest = JSON.decode(m_content) end)
    end

    -- Phase 5: build remote manifest, identify changes
    local remote_manifest = {}
    local to_download = {}

    for _, item in ipairs(data.tree) do
        if item.type == "blob" and item.path:match("%.md$") then
            remote_manifest[item.path] = item.sha
            if local_manifest[item.path] ~= item.sha then
                table.insert(to_download, item)
            end
        end
    end

    -- Phase 6: download changed/new files
    local total = #to_download
    for idx, entry in ipairs(to_download) do
        progress:setText(T(_("Downloading (%1/%2): %3"), idx, total, entry.path))
        UIManager:forceRePaint()

        local file_url = string.format(
            "https://raw.githubusercontent.com/%s/%s/%s/%s",
            self.repo_owner, self.repo_name, self.repo_branch,
            util.encodeURIComponent(entry.path)  -- handle spaces/special chars
        )

        local local_path = self.notes_dir .. entry.path

        -- Create parent directories as needed (handles nested paths)
        local parent_dir = local_path:match("(.+)/[^/]+$")
        if parent_dir then
            lfs.mkdir(parent_dir)
        end

        -- Stream raw content directly to file (avoids buffering whole file in RAM)
        local out_file, err = io.open(local_path, "wb")
        if not out_file then
            progress:setText(T(_("Error creating file %1: %2"), entry.path, err))
            progress.timeout = 5
            UIManager:close(progress)
            NetworkMgr:afterWifiAction()
            return
        end

        local dl_ok, http_code = https.request{
            url = file_url,
            method = "GET",
            headers = {
                ["Authorization"] = "token " .. pat,
                ["User-Agent"] = "KOReader-syncnotes/1.0",
            },
            sink = ltn12.sink.file(out_file),
            timeout = 30,
        }
        out_file:close()

        if not dl_ok or http_code ~= 200 then
            -- 404 might mean the branch/path is wrong, or file was deleted between tree fetch and download
            progress:setText(T(_("Error downloading %1: HTTP %2"), entry.path, tostring(http_code)))
            progress.timeout = 5
            UIManager:close(progress)
            NetworkMgr:afterWifiAction()
            return
        end
    end

    -- Phase 7: delete files removed from remote
    local deleted = 0
    for path_rel, _ in pairs(local_manifest) do
        if not remote_manifest[path_rel] then
            local full_path = self.notes_dir .. path_rel
            os.remove(full_path)
            deleted = deleted + 1
        end
    end

    -- Phase 8: save updated manifest
    local mf_out = io.open(self.manifest_file, "w")
    if mf_out then
        mf_out:write(JSON.encode(remote_manifest))
        mf_out:close()
    end

    -- Phase 9: completion
    local msg = T(_("Sync complete!\n\nDownloaded: %1\nDeleted: %2\nTotal: %3"),
        total, deleted, #data.tree)
    UIManager:close(progress)
    UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })

    -- Restore WiFi state to preserve battery (only if beforeWifiAction was called)
    NetworkMgr:afterWifiAction()
end

return SyncNotes
```

### 7.4 How it works

1. `init()` loads plugin settings from a dedicated `LuaSettings` file
   (`settings/syncnotes.lua`), avoiding pollution of `settings.reader.lua`.
2. User invokes *"Sync AI-2526 Notes"* from the tools menu.
3. If no PAT is saved, `promptForToken()` shows an `InputDialog` with
   `text_type = "password"` — the token is masked on screen.
4. `startSync(pat)` calls `NetworkMgr:runWhenOnline(callback)` which ensures WiFi
   is connected before proceeding (`manager.lua:698-700`).
5. `executeSync(pat)`:
   - Uses the **GitHub Trees API** (`GET /git/trees/master?recursive=1`) — ONE
     REST API call per sync (authenticated rate limit: 5000/hr).
   - Compares remote SHA hashes against a local JSON manifest (incremental).
   - Downloads changed/new files via `raw.githubusercontent.com` (NOT counted
     against REST rate limits).
   - Deletes local files not in the remote tree.
   - `UIManager:forceRePaint()` is called after each `progress:setText()` so the
     e-ink screen updates during blocking network I/O.
   - Each network step is wrapped in error checks with specific messages for 401
     (bad token), 403 (rate limit), 404 (bad repo/path), and generic errors.
   - `NetworkMgr:afterWifiAction()` runs last so WiFi is turned off per user
     preference (or left on if configured `wifi_disable_action = "leave_on"`).

### 7.5 Edge case handling

- **Spaces/special chars in paths:** uses `util.encodeURIComponent(entry.path)`
  for the raw download URL.
- **Nested folders:** `entry.path` is repo-relative (e.g. `subdir/note.md`); local
  `lfs.mkdir` creates parent dirs.
- **Token cleared mid-config:** `Clear GitHub Token` menu item removes only the
  PAT key from the settings file.
- **Empty repo / no .md files:** the download loop is a no-op; manifest says `{}`;
  `Deleted: 0, Downloaded: 0` reported.
- **Network timeout:** each `https.request` has a 30-second timeout (matches
  wallabag and newsdownloader patterns).

---

## 8. Open questions (answered)

### Q1 (Plugin A, Option A vs B): Is the temp-HTML aux-provider approach the right call?

**Yes. See §5.1.** Option B (custom `MarkdownDocument`) would require implementing
the full `Document` interface and interfacing with crengine's C++ code via FFI.
There are zero precedents for this in the KOReader codebase. The temp HTML path
in ReaderUI history is a cosmetic concern — the rendered output is identical.

**Source citations:**

- All 4 aux provider precedents use Option A style (texteditor.koplugin:50,
  archiveviewer.koplugin:42, imageviewer.lua:894, textviewer.lua:915).
- FileConverter:mdToHtml at `filemanagerconverter.lua:41-55` does the wrapping.

### Q2 (Reusing mdToHtml vs calling luamd directly): Which is more maintainable?

**Use FileConverter:mdToHtml.** Its module-level requires do NOT pull in
FileManager (`filemanagerconverter.lua:5-12` — only ButtonDialog, ConfirmBox,
UIManager, lfs, logger, util, gettext, ffi/util). This is safe for plugin use.
See §5.4.

### Q3 (addAuxProvider callback shape): callback field vs self[provider]:openFile method?

**Both work** — see `filemanager.lua:1625-1630`:

```lua
if provider.callback then -- module
    provider.callback(file)
else -- plugin
    self[provider.provider]:openFile(file)
end
```

We recommend the **`callback` field** (module style) because:

- It's self-contained — no dependency on `registerModule` naming.
- It matches the pattern used by `imageviewer.lua:901` and `textviewer.lua:922`.
- See §5.3.

### Q4 (PAT storage): Best practice for secrets on a FAT e-reader partition?

**Dedicated LuaSettings file** — this is the KOReader standard (see
`plugins/kosync.koplugin/main.lua:26`, `dev-bestpractices.txt` §5,
`frontend/luasettings.lua:89`). The FAT partition has no file permissions;
mitigate by:

1. Using a **fine-grained read-only PAT** scoped to a single repo.
2. Entering via password-masked `InputDialog` (`text_type = "password"` at
   `inputdialog.lua:20,381`).
3. Providing a **"Clear Token"** menu action.
4. **Documenting loudly** that the token is stored in cleartext on the device.

There is no KOReader keyring plugin (no precedent). See §5.5.

### Q5 (Sync blocking): Coroutine chunking vs synchronous forceRePaint?

**Synchronous with forceRePaint** — the standard pattern across
`newsdownloader.koplugin:195,430,434`, `wallabag.koplugin`, and
`exporter.koplugin`. For hundreds of small `.md` files at ~2-20 KB each, total
sync time is under a minute on WiFi. If measurements later show unacceptable
blocking, the `ReaderUI:showReaderCoroutine` pattern at `readerui.lua:711-736`
and `plugins/kosync.koplugin/` are references for coroutine chunking. See §5.6.

### Q6: Should this be one plugin or two?

**Two plugins.** See detailed trade-off analysis in §5.2.

---

## 9. Testing & verification plan

### 9.1 Unit tests

**⚠️ Updated 2026-07-30 — this section previously described a planned suite run
under KOReader's `busted` via `./kodev test`. That is not what was built.**

Tests are run from the repository root with:

```bash
lua run_busted_tests.lua
```

**`run_busted_tests.lua` is a hand-rolled, dependency-free test runner — it is
NOT the `busted` framework, despite the filename.** It requires nothing beyond a
stock Lua interpreter, which is precisely why it works unchanged across every
interpreter we care about. It auto-discovers `tests/*_spec.lua`.

Current state: **71 tests, all passing**, verified on **Lua 5.1, LuaJIT, and Lua
5.5**.

| Test file | What it covers |
| --- | --- |
| `tests/markdown_interceptor_spec.lua` | Math extraction/substitution: `$`/`$$` detection, the inline-`$` disambiguation rules, code-block and code-span exclusion, blank-line abort (§6.6) |
| `tests/math_renderer_spec.lua` | Backend facade, djb2 content-addressed cache keys, degradation to monospace source for unsupported constructs |
| `tests/test_manifest.lua` | SHA-manifest diff: given local and remote SHA tables, compute the download set and the delete set |
| `tests/test_sync_integration.lua` | Sync flow end-to-end against stubbed HTTP: tree filtering (`type=="blob"` + `.md`), URL construction/encoding, delete pass |

Everything under test is pure Lua with no device dependency — that is a deliberate
design property, not a coincidence: the network, filesystem, and UI touchpoints
are kept at the edges of `main.lua` so the logic beneath them stays testable on a
desktop.

### 9.2 Emulator testing

**⚠️ Note:** this procedure assumes a local KOReader source checkout for
`./kodev`. The clone this document was originally written against
(`~/.repos/koreader`) no longer exists, so the steps below are **not currently
runnable as written** — re-clone KOReader first if you want the emulator path.
In practice the loop that was actually used is §9.1 (desktop unit tests) plus
§9.3 (deploy to the device via `./deploy.sh`).

```bash
cd ~/.repos/koreader   # requires a KOReader checkout — see note above

# Drop plugins into staging
ln -s <kobo-notes>/plugins/markdownreader.koplugin plugins/
ln -s <kobo-notes>/plugins/syncnotes.koplugin plugins/

# Build and run emulator
./kodev run -s=kobo-aura-one
```

In the emulator:

1. **UC-1**: Create a `.md` file with headings, lists, code, tables in the FM.
   Tap it. Verify it opens rendered. Long-press → *Open with* → *plain text* still
   works (if textviewer is also enabled? Actually textviewer is always available).
   The Open With dialog shows crengine (plain text) and Markdown Reader as separate
   options. **Note:** crengine's default plain-text handling for `.md` means both
   are available — the user preference determines the default.
2. **UC-2**: Set a valid PAT, trigger sync with a small test repo. Verify files
   appear. Add a file on GitHub, re-sync, verify it downloads. Remove a file on
   GitHub, re-sync, verify it's deleted locally.
3. **UC-3**: Verify PAT prompt on first sync. Verify token is saved and reused.
   Verify "Clear Token" clears it and re-prompts.
4. **UC-4**: In the emulator, verify disabling the plugin (Tools → Plugin
   management) restores `.md` to plain text.

### 9.3 On-device testing

Run **`./deploy.sh`** from the repository root — it copies both plugin dirs to
`/mnt/kobo/.adds/koreader/plugins/`. Then restart KOReader and enable them. Both
plugins are currently implemented and deployed to the device by this route.

| Test case | Steps | Expected |
| --- | --- | --- |
| Formatted open | Tap any `.md` file | Opens with rendered HTML |
| Math rendering | Open a note containing `$...$` and `$$...$$` | Formulas render as unicode/HTML; unsupported constructs appear as monospace LaTeX (§6.6) |
| Math never blocks open | Open a note with deliberately malformed LaTeX | Document still opens; math path is `pcall`-wrapped |
| Sync | Tools → Sync AI-2526 Notes | WiFi connects, notes appear in `notes/AI-2526/` |
| Incremental | Add a new `.md` to GitHub master, re-sync | Only the new file downloads |
| Deletion | Delete a `.md` from GitHub master, re-sync | Local copy removed |
| Token handling | Clear token, sync again | Prompt appears with password field |
| Error: bad token | Sync with incorrect PAT | `InfoMessage` shows 401 error |
| Error: no WiFi | Disable WiFi, sync | `NetworkMgr` prompts to turn on WiFi |
| Long-press fallback | Long-press `.md` → Open with | Shows "Markdown Reader" and crengine options |

### 9.4 Regression / Luacheck

```bash
# Lint our files (the .luacheckrc allows G_reader_settings and G_defaults)
./kodev check plugins/markdownreader.koplugin/*.lua plugins/syncnotes.koplugin/*.lua
```

(Same caveat as §9.2: `./kodev` needs a KOReader checkout.)

### 9.5 Verification of upstream changes

If KOReader is updated past v2026.07, verify (this list was last run on 2026-07-30 against v2026.07 — all four still hold):

- `FileConverter:mdToHtml` still exists and signature hasn't changed
  (`filemanagerconverter.lua:41`)
- `DocumentRegistry:addAuxProvider` still accepts the same table schema
  (`documentregistry.lua:55`)
- `FileManager:openFile` dispatch logic at `filemanager.lua:1614-1637` unchanged
- `md.lua` module path at `apps/filemanager/lib/md.lua` unchanged

---

## 10. Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| `FileConverter:mdToHtml` changes or moves in future KOReader | We use it directly; if it breaks, fall back to `require("apps/filemanager/lib/md")` + manual wrapper (see §5.4). Pin check in post-update verification |
| PAT stored in cleartext on FAT partition (no file permissions) | Use read-only fine-grained PAT scoped to AI-2526 only; document this prominently; add "Clear Token" menu action |
| Long sync blocks UI | Currently in scope for ~hundreds of notes (under a minute). If too slow, adopt coroutine chunking pattern from `readerui.lua:711-736` |
| GitHub REST API rate limit (5000 req/h) | Sync uses exactly 1 tree API call; raw downloads are NOT counted against REST rate limits. Limit is irrelevant for our use case |
| Temp HTML path shows `.html` in history instead of `.md` | Cosmetically acceptable — see §5.1. The rendered output is identical. Filename preserves the original name with `.html` extension |
| OTA update changes `G_reader_settings` provider default | The provider association is stored in `G_reader_settings.reader.lua` which is preserved across OTA (only tracked `package.index` files are cleaned). If the user resets settings, the plugin's `init()` re-creates the default on next load |
| Different Kobo models have different WiFi chipsets / connectivity | `NetworkMgr:runWhenOnline` abstracts all platform WiFi differences — proven in `newsdownloader.koplugin` and `wallabag.koplugin` |

---

## 11. Implementation task breakdown (TDD slices)

Each slice is independently verifiable. Suggested implementation order:

### Slice 1: Plugin skeleton + menu registration (markdownreader)

- Create `markdownreader.koplugin/_meta.lua` and `main.lua` with empty
  `WidgetContainer:extend`.
- Register to main menu with a static menu entry.
- **Verify:** Plugin appears in Tools menu, is toggleable in Plugin management.

### Slice 2: Aux provider registration + file type association

- Add `DocumentRegistry:addAuxProvider` with `enabled_func` for `.md`.
- Set default `providers["md"]` in `init()`.
- **Verify:** In emulator, a `.md` file's Open With dialog shows "Markdown Reader".

### Slice 3: Markdown rendering

- Implement `openMarkdown(file)` — read file, call `FileConverter:mdToHtml`,
  write to `cache/md/`, open with `ReaderUI:showReader`.
- **Verify:** Tapping a `.md` file opens rendered HTML.

### Slice 4: Sync plugin skeleton + menu

- Create `syncnotes.koplugin/_meta.lua` and `main.lua`.
- Menu entry: "Sync AI-2526 Notes" → `onSyncTriggered()` (stub).
- **Verify:** Menu item appears.

### Slice 5: PAT management (InputDialog + LuaSettings)

- `InputDialog` with `text_type = "password"`.
- Read/write PAT in dedicated `LuaSettings` file.
- "Clear Token" menu item.
- **Verify:** Token persisted across restart; cleared token re-prompts.

### Slice 6: Tree API fetch + manifest comparison (unit-testable pure functions)

- Unit test: `computeChanges(local_manifest, remote_tree_json, ".md")` → `{to_download, to_delete}`.
- Verify with known input/output.

### Slice 7: Download loop + WiFi management

- `NetworkMgr:runWhenOnline` → `executeSync` (tree fetch → compare → download → delete → save manifest).
- Progress via `InfoMessage` with `forceRePaint`.
- **Verify:** Sync pulls notes from a test repo; incremental sync only downloads changed files.

### Slice 8: Error handling

- 401→bad token, 403→rate limit, 404→repo/path, network timeout, parse errors.
- **Verify:** Each error produces a specific, readable `InfoMessage`.

### Slice 9: Edge cases + polish

- Nested folder paths (create parent dirs).
- Spaces and special characters in filenames (`util.encodeURIComponent`).
- Empty repo (no .md files).
- Very large repos (pagination? unlikely for notes; note it as a future concern).
- **Verify:** Each edge case tested in emulator.

### Slice 10: Integration test on device

- Full UC-1 through UC-4 on the Kobo (see §9.3).
- Screenshots for acceptance documentation.

### Slice 11: LaTeX math rendering (delivered post-v1)

- `markdown_interceptor.lua` — extract `$`/`$$` spans to tokens before
  `mdToHtml`, substitute rendered HTML back afterwards.
- `math_renderer.lua` — backend facade + djb2 content-addressed cache.
- `math_backend_lua.lua` — pure-Lua LaTeX subset → unicode/HTML.
- **Verify:** `tests/markdown_interceptor_spec.lua` and
  `tests/math_renderer_spec.lua` (part of the 71-test suite, §9.1); real-corpus
  run of 75 files / 4952 formulas / 0 errors. See §6.6.

### Future (post-v1)

- **Native MicroTeX math backend** — deferred behind the `math_renderer.lua`
  seam; it needs a cross-compiled C++ library, which objective 3 excludes for
  now. Design in `docs/microtex_implementation_spec.html`.
- Detect 4-space-indented code blocks in the math interceptor (known gap, §6.6).
- Coroutine async for large repos.
- Optional auto-sync on plugin load (if WiFi is already on).
- Support for multiple sync configs (e.g., different repos for different courses).

---

## Appendix A: Corrections summary

| Original claim | Correction | Source |
| --- | --- | --- |
| `addAuxProvider("md", "text/markdown", {...})` | `addAuxProvider{provider="markdownreader", ...}` (1 arg) | `documentregistry.lua:55` |
| `FileManager:openFile` at line 1551 | line 1614 | `filemanager.lua:1614` |
| `NetworkMgr:afterWifiAction` at line 605 | line 621 | `manager.lua:621` |
| `G_reader_settings:readSetting("provider",{})["md"] = "markdownreader"` without save | Must call `G_reader_settings:saveSetting("provider", providers)` then `flush()` | `luasettings.lua:89-96` |
| "Latest stable = v2026.07" | Was UNVERIFIED (device was v2025.10); **now confirmed** — device runs v2026.07 as of 2026-07-30 | `/mnt/kobo/.adds/koreader/git-rev` |
| Temp HTML path issue = Option B needed | Acceptable cosmetic; all precedents use temp approach | No Option B precedent exists |
| `b-md-reader-plugin.txt` uses extension args in addAuxProvider | Wrong; API only accepts 1 table arg | `documentregistry.lua:55` |

### A.1 Second-round corrections (2026-07-30, re-verified against v2026.07)

| Previous claim | Correction | Source |
| --- | --- | --- |
| Reference source is `~/.repos/koreader` (HEAD `574fe9f`) | That clone no longer exists. Reference source is now the device tree at `/mnt/kobo/.adds/koreader/` | `ls ~/.repos/koreader` → no such directory |
| Device runs KOReader v2025.10 | Device runs **v2026.07** | `/mnt/kobo/.adds/koreader/git-rev` |
| "Latest stable = v2026.07" is UNVERIFIED, recommend deleting | Confirmed true; claim retained | `git-rev` |
| Sync plugin is `aiactions_sync.koplugin` | It is **`syncnotes.koplugin`** everywhere — repo, device, and its own submodule remote | `.gitmodules`, `plugins/syncnotes.koplugin/` |
| `FileConverter:mdToHtml` at `filemanagerconverter.lua:42-56` | now **41-55** (`_mdFileToHtml` follows at 56) | device source |
| `filemanagerconverter.lua:1-12` module requires | requires start at **5** (`5-12`) | device source |
| `imageviewer.lua:906` (`callback` field) | now **901** | device source |
| `textviewer.lua:928` (`callback` field) | now **922** | device source |
| `filemanager.lua:1619-1621` (callback vs plugin dispatch) | now **1625-1630** | device source |
| Open With dialog at `filemanager.lua:1464` | `showOpenWithDialog` at **1471** | device source |
| "Reset default for type" at `filemanager.lua:1530-1534` | now **1528-1531** | device source |
| `readerui.lua:710` forceRePaint (show at 709) | forceRePaint at **718**, `UIManager:show` at **712** | device source |
| `readerui.lua:711-731` showReaderCoroutine | function starts at 711; body extends to ~**736** | device source |
| `inputdialog.lua:20,396` for `text_type` | comment at 20; actual field pass-through at **381** | device source |
| `newsdownloader.koplugin/main.lua:195,430,434` as forceRePaint precedent | **No `forceRePaint` call remains in that plugin.** `runWhenOnline` at 195 still valid. See §5.6 | `rg -n forceRePaint` → no matches |
| `documentregistry.lua` `getProvider` at 69-92 | `getProvider` at **91**; `hasProvider` occupies 63-90 | device source |
| Unit tests run via KOReader's `busted` / `./kodev test` | Run via `lua run_busted_tests.lua`, a **hand-rolled runner, not busted**. 71 tests. See §9.1 | repo root |

**Unchanged and re-confirmed at the same line numbers:** `addAuxProvider` (`documentregistry.lua:55`), `setProvider` (210), `getAuxProviders` (182), `FileManager:openFile` (1614), `ReaderUI:showReader` (616), `showReaderCoroutine` (711), `beforeWifiAction` (605), `afterWifiAction` (621), `runWhenOnline` (698), `LuaSettings:readSetting` (89), `DataStorage:getDataDir` (16), `credocument.lua:1609`, `koreader.sh:129`, `md.lua` (533 lines), `texteditor.koplugin:50` (order 30), `archiveviewer.koplugin:42` (order 40), `wallabag.koplugin/main.lua:23` (JSON), `kosync.koplugin/main.lua:26` (settings file), `socketutil.lua:8` (`ssl.https`), pluginloader `_discover` (174) / `_load` (231) / `loadPlugins` (273) / `createPluginInstance` (479).

## Appendix B: Key source file references

All paths relative to `/mnt/kobo/.adds/koreader/`. Line numbers verified
2026-07-30 against v2026.07.

| File | Lines | What |
| --- | --- | --- |
| `frontend/document/documentregistry.lua` | 55-57, 91, 154, 182-192, 210-222 | `addAuxProvider`, `getProvider`, `getAssociatedProviderKey`, `getAuxProviders`, `setProvider` |
| `frontend/apps/filemanager/filemanagerconverter.lua` | 5-12, 41-55 | module requires; `FileConverter:mdToHtml` |
| `frontend/apps/filemanager/filemanager.lua` | 379-426, 1471-1637 | `registerModule`, plugin loading (417-426), Open With dialog (1471), `openFile` dispatch (1614-1637) |
| `frontend/apps/reader/readerui.lua` | 616, 711-736 | `showReader`, `showReaderCoroutine` (with `forceRePaint` at 718) |
| `frontend/ui/network/manager.lua` | 605, 621, 698-727 | `beforeWifiAction`, `afterWifiAction`, `runWhenOnline` |
| `frontend/pluginloader.lua` | 174, 231, 273, 479 | `_discover`, `_load`, `loadPlugins`, `createPluginInstance` |
| `frontend/luasettings.lua` | 89-96 | `readSetting(key, default)` |
| `datastorage.lua` | 16, 60 | `getDataDir`, `getSettingsDir` |
| `frontend/apps/filemanager/lib/md.lua` | 1-533, 508-521 | vendored luamd markdown parser |
| `plugins/texteditor.koplugin/main.lua` | 50-63 | Precedent: aux provider plugin with order 30 (`isFileTypeSupported` 59, `openFile` 63) |
| `plugins/archiveviewer.koplugin/main.lua` | 42-62 | Precedent: aux provider plugin with order 40 |
| `frontend/ui/widget/imageviewer.lua` | 894-904 | Precedent: aux provider module — `callback` at 901, `enabled_func` at 898 |
| `frontend/ui/widget/textviewer.lua` | 915-925 | Precedent: aux provider module — `callback` at 922, `enabled_func` at 919 |
| `plugins/newsdownloader.koplugin/main.lua` | 195 | Pattern: `NetworkMgr:runWhenOnline` (⚠️ no longer a `forceRePaint` precedent) |
| `plugins/wallabag.koplugin/main.lua` | 23-24, 156, 883 | Pattern: REST API (`callAPI` at 883), JSON, LuaSettings |
| `frontend/document/credocument.lua` | 1605-1615 | `.md` registered as `text/plain` with crengine (1609) |
| `koreader.sh` | 129 | OTA cleanup leaves user plugins untouched (repo path: `platform/kobo/koreader.sh`) |
| `frontend/ui/widget/inputdialog.lua` | 17-20, 396-401 | Password type support (`text_type = "password"`) |
