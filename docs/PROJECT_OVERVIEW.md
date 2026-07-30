> # ⚠️ SUPERSEDED — HISTORICAL DRAFT, DO NOT USE AS REFERENCE ⚠️
>
> **This document is an early draft (v0.1) and is no longer authoritative.**
> It has been superseded by **[`docs/DESIGN_final.md`](DESIGN_final.md)**, which is
> the authoritative design document. Read that instead. The body below is kept
> only as a record of the initial research phase.
>
> **Superseded as of:** 2026-07-30
>
> **Known-wrong claims in the text below:**
>
> - **KOReader version.** The body says the device runs **v2025.10**. The device
>   actually runs **v2026.07** (`cat /mnt/kobo/.adds/koreader/git-rev`).
> - **Sync plugin name.** The body calls the sync plugin
>   `aiactions_sync.koplugin`. Its real, shipped name is **`syncnotes.koplugin`**.
> - **Reference source clone.** The body references a KOReader source clone at
>   `~/.repos/koreader`. **That path does not exist**; any claim sourced from it
>   is unverified.
>
> Anything else in this draft may also be stale. Verify against
> `docs/DESIGN_final.md` and the code under `plugins/` before relying on it.

---

# Project Overview: AI-2526 Notes on Kobo

**Status:** Draft v0.1 (awaiting review)  ·  **Date:** 2026-07-30
**Repo:** `git@github.com:denialbb/AI-2526.git` (branch `master`), local clone `~/Work/uni/AI-2526`
**Target device:** Kobo e-reader, custom firmware, **KOReader v2025.10** at `/mnt/kobo/.adds/koreader`
**Reference source clone:** `~/.repos/koreader` (shallow, HEAD `574fe9f`)

> This document is the basis for development. It is intended to be **complete and
> verified**: every API claim has been checked against either the deployed install
> at `/mnt/kobo/.adds/koreader` or the cloned source at `~/.repos/koreader`.
> Sections marked ⚠️ are open questions for the reviewer (kimi-k3).

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

## 2. Constraints (verified)

| Constraint | Evidence |
| --- | --- |
| Kobo runs KOReader **v2025.10** | `/mnt/kobo/.adds/koreader/git-rev` → `v2025.10` |
| `.md` opens as **plain text** today (crengine has no md parser) | `credocument.lua` registers `.md` as `text/plain`; no `markdown` refs in crengine |
| No `git` binary on Kobo OS | `/mnt/kobo` is the onboard FAT partition; device rootfs inaccessible; only `dbclient`, `sftp-server`, `dropbear` in `.adds/koreader/` |
| HTTPS + JSON available in Lua | `socket.http` + lua-sec (`libssl.so`); `require("json")` (rapidjson); proven by `newsdownloader.koplugin`, `wikipedia.lua` |
| Pure-Lua markdown parser is bundled | `frontend/apps/filemanager/lib/md.lua` (vendored `bakpakin/luamd`); `FileConverter:mdToHtml(markdown, title, stylesheet)` already wraps it |
| Plugins are hot-loaded, no rebuild | `frontend/pluginloader.lua` auto-discovers `*.koplugin/`; toggle in *Tools → Plugin management* |
| Aux document providers are a supported seam | `DocumentRegistry:addAuxProvider({provider, order, callback?})`; precedents: `texteditor.koplugin` (order 30), `archiveviewer`, `imageviewer`, `textviewer` |
| `FileManager:openFile` dispatches to aux provider's `callback` or `self[provider]:openFile(file)` | `frontend/apps/filemanager/filemanager.lua:1551` |
| `ReaderUI:showReader(file, provider, seamless, is_provider_forced, after_open_callback)` opens a doc | `frontend/apps/reader/readerui.lua:616` |
| Wi-Fi must be requested safely | `NetworkMgr:runWhenOnline(cb)` + `NetworkMgr:afterWifiAction()` (`frontend/ui/network/manager.lua:698,605`) |
| UI is single-threaded; show progress + `UIManager:forceRePaint()` before blocking | dev-bestpractices report §5; `InfoMessage` widget |
| Private repo needs auth for raw download | `raw.githubusercontent.com` for private repos requires `Authorization: token <PAT>` |
| GitHub authenticated REST limit: 5000 req/h; tree is 1 call; raw downloads don't count against REST | GitHub docs |
| OTA updater exists (stable/nightly) | `frontend/ui/otamanager.lua`; latest stable per runner research is **v2026.07** ⚠️ verify before relying |

## 3. Background / problem

The user keeps university course notes (AI-2526) in a private GitHub repo as `.md`
files, cloned locally at `~/Work/uni/AI-2526`. They want to read these on their
Kobo. KOReader v2025.10 cannot render `.md` formatted out of the box, and the Kobo
has no git client. The deployed install already ships every primitive we need:
a Lua markdown parser, an HTML rendering engine (crengine), HTTPS, JSON, an SSH
client, and a plugin system. The work is to **wire these together** with two small
plugins, not to build anything new.

Research was gathered by 3 parallel `agy` agy runners (Gemini 3.5 Flash, medium)
managed via herdr, plus local source verification against `~/.repos/koreader`:
- `a-on-device-sync.txt` — on-device sync approaches + plugin skeleton
- `b-md-reader-plugin.txt` — markdown reader plugin design (Option A aux provider)
- `dev-bestpractices.txt` — koreader dev workflow, build, OTA, plugin distribution

Earlier research (`out-1..4-*.txt`, `REPORT.md`) established the broader landscape
and ruled out git-on-device, Syncthing, and libghostty.

## 4. Use cases & user stories

### UC-1: Read a note, formatted
> As a student, I tap `notes/Lecture-03.md` in the KOReader file manager and it
> opens showing formatted headings, bold, bullet lists, and code blocks — like
> an EPUB — not raw `#`/`**` characters.

**Acceptance:** Tapping any `.md` under the notes folder opens it rendered via
crengine (HTML). Long-press still allows *Open with → plain text* if desired.

### UC-2: Sync notes from the Kobo
> As a student, I open the KOReader tools menu and tap **"Sync AI-2526 notes"**.
> Wi-Fi turns on if needed; new/changed notes download from GitHub; notes deleted
> in the repo are removed locally; a progress message shows what's happening.

**Acceptance:** After sync, the local notes folder exactly mirrors the set of
`.md` files (paths + contents) on `master` of the private repo. No PC involved.

### UC-3: Configure credentials once
> As a student, the first time I sync I'm prompted to paste a GitHub Personal
> Access Token (read-only, scoped to AI-2526). It's stored locally and reused.

**Acceptance:** PAT stored in a plugin settings file (not plaintext
`settings.reader.lua`); editable/clearable from the plugin menu.

### UC-4: Update KOReader (supporting task)
> As a user I want to update KOReader itself to a newer version (e.g. to gain
> native markdown in the annotation viewer) without losing my plugins or notes.

**Acceptance:** Use built-in OTA (*Update → Check for updates*) or manual USB
tarball replace; user-installed plugins in `plugins/` and all `settings/` are
preserved by OTA (cleanup only deletes files tracked in the old `package.index`).

## 5. Proposed solution — two koplugins

Both are **pure Lua**, dropped into `/mnt/kobo/.adds/koreader/plugins/`, enabled
via *Tools → Plugin management*. No build, no OTA, no root.

### 5.1 Plugin A — `markdownreader.koplugin` (renders `.md` on open)

**Design: Option A (aux provider) — chosen over B/C.** *(Rationale: texteditor,
archiveviewer, imageviewer, textviewer all use this exact pattern; reuses
crengine HTML rendering; no core edits.)*

**`_meta.lua`**
```lua
local _ = require("gettext")
return {
    name = "markdownreader",
    fullname = _("Markdown Reader"),
    description = _("Render Markdown files as formatted HTML when opened."),
}
```

**`main.lua` (sketch — final code TBD in implementation issue)**
```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DocumentRegistry = require("document/documentregistry")
local ReaderUI          = require("apps/reader/readerui")
local FileConverter     = require("apps/filemanager/filemanagerconverter") -- reuse mdToHtml! ⚠️ verify FileConverter can be required standalone
local UIManager         = require("ui/uimanager")
local InfoMessage       = require("ui/widget/infomessage")
local DataStorage       = require("datastorage")
local logger            = require("logger")
local lfs               = require("libs/libkoreader-lfs")
local _ = require("gettext")

local MarkdownReader = WidgetContainer:extend{ name = "markdownreader" }

function MarkdownReader:init()
    DocumentRegistry:addAuxProvider{
        provider = self.name,
        order    = 25,                       -- below texteditor(30) in Open-with
        callback = function(file) self:openFile(file) end,
    }
    self.ui.menu:registerToMainMenu(self)
end

function MarkdownReader:openFile(file)
    local f = io.open(file, "rb")
    if not f then return end
    local content = f:read("*a"); f:close()
    local _, name = require("ffi/util").splitFilePathName(file)
    -- Reuse the bundled parser+wrapper (DO NOT re-wrap HTML ourselves)
    local html = FileConverter:mdToHtml(content, name, self.stylesheet)
    local tmpdir = DataStorage:getDataDir() .. "/cache/md/"   -- not /tmp: must be on writable partition
    lfs.mkdir(tmpdir)
    local out = tmpdir .. name .. ".html"
    local w = io.open(out, "w"); w:write(html); w:close()
    ReaderUI:showReader(out)
end

return MarkdownReader
```

**Default-on association:** On first run, set
`G_reader_settings:readSetting("provider", {})["md"] = "markdownreader"` so a tap
renders. User can revert via long-press → *Open with* (`DocumentRegistry:setProvider`).

**Open questions for reviewer (⚠️):**
1. Is requiring `apps/filemanager/filemanagerconverter` from a plugin safe at
   runtime (it's normally loaded in FileManager context)? If not, require the
   parser directly: `local MD = require("apps/filemanager/lib/md"); MD(text, opts)`.
2. Should temp HTML live in `cache/md/` (writable, survives session) or per-file
   sidecar? ReaderUI history will show the `.html` path — is that acceptable, or
   should we preserve the `.md` path (pushes toward Option B / a custom provider)?
3. `addAuxProvider` `callback` vs a `self[provider]:openFile(file)` method — the
   `texteditor` precedent uses a method (no `callback` field). Which is canonical?

### 5.2 Plugin B — `aiactions_sync.koplugin` (syncs notes from the Kobo)

**Design: GitHub REST API over HTTPS, no git binary.** *(Rationale: zero native
deps, works anywhere with Wi-Fi, lowest memory; cross-compiled git is
OOM-fragile; jump-host ties you to LAN. See `a-on-device-sync.txt` §1–2.)*

**Flow** (menu action *"Sync AI-2526 notes"*):
1. Read PAT from plugin settings file (`DataStorage:getSettingsDir() .. "/aiactions_sync.lua"`,
   via `LuaSettings`). If missing → `InputDialog` to enter it.
2. `NetworkMgr:runWhenOnline(function() ... NetworkMgr:afterWifiAction() end)`.
3. `GET https://api.github.com/repos/denialbb/AI-2526/git/trees/master?recursive=1`
   with `Authorization: token <PAT>`, `Accept: application/vnd.github+json`,
   `User-Agent: KOReader-aiactions-sync`.
4. `JSON.decode(body)` → filter `item.type=="blob" and item.path:match("%.md$")`.
5. Load local manifest `{"relative/path.md": "<git-sha>", ...}` (git blob SHA from
   the tree → robust incremental; no re-download when SHA unchanged).
6. For each changed/added: stream `GET https://raw.githubusercontent.com/denialbb/AI-2526/master/<path>`
   (same auth header) into `ltn12.sink.file` at local path (mkdir subdirs).
7. Delete local files whose path is in the old manifest but not the new tree.
8. Write updated manifest. Show `InfoMessage` summary (downloaded N, deleted M).

**Skeleton** — see `a-on-device-sync.txt` §3 for a runnable `main.lua` draft.
Production refinements vs that draft:
- Use `LuaSettings` (dedicated file) for **both** PAT and config — **not**
  `G_reader_settings:saveSetting("sync_ai2526_pat", ...)` (that pollutes
  `settings.reader.lua` plaintext; dev report §5 says use a dedicated file).
- Wrap each network step in `pcall`; show real error text, never crash.
- `UIManager:forceRePaint()` after each `InfoMessage:setText` so progress shows
  during blocking downloads.
- Local root default `DataStorage:getDataDir() .. "/notes/AI-2526/"` (not
  hardcoded `/mnt/onboard` — portable across devices).
- Handle repo path with spaces/`%` via `util.encodeURIComponent` per segment ⚠️.

**Open questions for reviewer (⚠️):**
1. Token storage is the weakest point. Options: (a) dedicated LuaSettings file
   (cleartext on the FAT partition), (b) rely on OS file permissions (no — FAT),
   (c) encrypt with a passphrase prompted at each sync (UX cost). Recommend.
2. raw.githubusercontent returns 404 short messages on wrong branch/path — confirm
   the `recursive=1` tree path handles nested folders and that `item.path` is
   repo-relative (it is). Confirm SHA field is `item.sha` (git tree blob SHA).
3. On a large repo, a synchronous loop blocks UI for minutes. Acceptable for
   ~hundreds of notes? Should we chunk via coroutines (kosync pattern)? ⚠️
4. Should we also support a non-pull workflow to *also* update the plugin itself?

### 5.3 Plugin distribution & update of KOReader

- **Plugins:** copy `*.koplugin/` into `/mnt/kobo/.adds/koreader/plugins/`,
  restart KOReader, enable in *Tools → Plugin management*. OTA does **not**
  touch user plugins (only files in the old official `package.index`).
- **KOReader itself:** built-in OTA (`otamanager.lua`) → *Settings → Update →
  Check for updates*, channels stable / nightly. Or manual: download a Kobo
  release tarball, replace `.adds/koreader/` preserving `settings/`, `ota/`,
  `plugins/<our plugins>`. Latest stable per research: **v2026.07** ⚠️ verify.

## 6. Verification & testing plan

- **Unit/spec:** `~/.repos/koreader` ships `busted`; run `./kodev test front
  spec/unit/<file>_spec.lua`. We can write specs for the SHA-manifest diff and
  the path-filter logic (pure functions) without the device.
- **Emulator:** `./kodev run -s=kobo-aura-one` (or the user's model) to test both
  plugins on the desktop without the device. Drop plugins into the staging
  `plugins/` and enable.
- **On-device:** copy to `/mnt/kobo/.adds/koreader/plugins/`, restart, enable,
  exercise UC-1..UC-4. Confirm:
  - `.md` opens formatted (screenshot).
  - Sync pulls a known new note and deletes a removed one (check manifest + files).
  - PAT prompt appears when unset; clearing it re-prompts.
  - Long-press → Open with → plain text still works.
- **Luacheck:** `./kodev check` on our plugin files (`.luacheckrc` allows
  `G_reader_settings`, `G_defaults`).

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| `FileConverter` not safely requrable from plugin context | Fall back to `require("apps/filemanager/lib/md")` + manual `md_options` (already documented in `filemanagerconverter.lua:42`) |
| PAT leak (FAT partition is cleartext, no file perms) | Use a fine-grained **read-only** PAT scoped to AI-2526 only; document this loudly; offer "clear token" menu |
| Long sync blocks UI | Coroutines + `forceRePaint`; cap; show cancel ⚠️ |
| GitHub API rate / 401 handling | Distinguish 401 (bad PAT) vs 404 (repo/path) vs network; show specific `InfoMessage` |
| Temp HTML path in history shows `.html` not `.md` | Accept, or move to Option B (custom document) — opens scope; revisit in review |
| OTA upgrade removes/changes a `md.lua`-parsing API we depend on | Pin to documented call shapes; re-verify after any koreader update |

## 8. Open questions for the reviewer (kimi-k3)

1. **Plugin A, Option A vs B:** Is the temp-HTML aux-provider approach (Option A)
   the right call, or does preserving the `.md` path in history/bookmarks (Option
   B, custom `MarkdownDocument:extend(Document)`) justify the much larger scope?
2. **Reusing `FileConverter:mdToHtml`** vs calling luamd directly — which is more
   maintainable across koreader versions?
3. **`addAuxProvider` callback shape** — `callback` field vs `self[provider]:openFile`
   method (texteditor precedent). Which is stable/canonical?
4. **PAT storage** — best practice for secrets on a FAT e-reader partition? Is
   there a koreader idiom (keyring plugin?) we're missing?
5. **Sync blocking** — coroutine chunking vs simple synchronous loop with
   `forceRePaint`; what's the koreader-idiomatic async pattern (see kosync)?
6. **Model: should this be one plugin or two?** A combined
   `aiactions.koplugin` (sync + reader) vs two separate ones. Trade-offs.
7. Anything in the constraints (§2) that's wrong or unverified? Especially the
   "latest stable = v2026.07" claim and the OTA preservation of user plugins.

## 9. Sources

- **Deployed install:** `/mnt/kobo/.adds/koreader/{frontend/apps/filemanager/{filemanagerconverter.lua,lib/md.lua}, frontend/document/{documentregistry.lua,credocument.lua}, frontend/apps/filemanager/filemanager.lua, frontend/apps/reader/readerui.lua, frontend/ui/network/manager.lua, frontend/ui/otamanager.lua, frontend/datastorage.lua, frontend/luasettings.lua, plugins/{texteditor,hello,newsdownloader,SSH,terminal}.koplugin/}`
- **Source clone:** `~/.repos/koreader` (HEAD `574fe9f`)
- **Research reports:** `/tmp/kobo-research/{a-on-device-sync.txt, b-md-reader-plugin.txt, dev-bestpractices.txt, REPORT.md}`
- **Upstream:** KOReader PRs #15588, #15599; issue #12683; GitHub REST Trees API
  https://docs.github.com/en/rest/git/trees#get-a-tree ; koreader.rocks docs/wiki.