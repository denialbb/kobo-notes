# Handoff — kobo-notes plugins

## Project state

Two KOReader plugins in `/home/denial/Projects/kobo-notes/`:

### `plugins/markdownreader.koplugin/` — Markdown renderer

**Status: Complete (Slices 1-3)**

- `_meta.lua` + `main.lua`
- Registers as aux provider (order 25) for `.md` files
- Sets global file-type association on first run
- `openMarkdown()` reads `.md` → `FileConverter:mdToHtml` with e-ink CSS → `cache/md/` → `ReaderUI:showReader`
- `cleanCache()` on init
- Menu: "Preview current file as HTML"

### `plugins/syncnotes.koplugin/` — GitHub notes sync

**Status: Mostly complete (Slices 4-7), needs on-device debugging**

- `_meta.lua` + `main.lua` + `manifest.lua`
- Config in `settings/syncnotes.lua`: owner/repo/branch/notes_root/PAT
- Menu: Sync Now, Configure Repo, Set Download Path, Set/Change Token, Clear Token
- PAT auto-detected from `{DataStorage:getDataDir()}/secrets/` on startup
- Full sync pipeline: Tree API → manifest diff → download → delete removed → save manifest → WiFi cleanup
- Progress bar using `[####------]` notation

## Tests

### `tests/test_manifest.lua` — 12 tests, 31/31 passing

Pure logic: `Manifest.filterMdFiles`, `buildManifest`, `computeChanges`, `encodeManifest`, `decodeManifest`. Run with:

```bash
lua5.1 tests/test_manifest.lua
```

### `tests/test_sync_integration.lua` — Integration tests (needs lua-filesystem)

Tests progressBar, getNotesDir logic, URL construction, download loop, error paths, manifest round-trip. Not runnable yet — needs `sudo apt install lua-filesystem` (blocked by agent permissions).

## Known issues (from on-device testing)

1. **`util.encodeURIComponent` was nil** → Fixed, changed to `util.urlEncode` (confirmed at `frontend/util.lua:1460`)
2. **"attempt to use a closed file" at main.lua ~line 447** → Suspected: `ltn12.sink.file(out_file)` closing the file handle before `out_file:close()`. Fixed by switching to `ltn12.sink.table(dl_chunks)` + explicit `io.open/close`. **Not yet verified on device.**
3. **Progress dialog disappears silently** → Rewrote `executeSync` with `pcall` wrapper, always shows result/error message with 8-15 sec timeout.

## Deploy

```bash
./deploy.sh
```

Copies plugins/ to `/mnt/kobo/.adds/koreader/plugins/` and secrets/ to `/mnt/kobo/.adds/koreader/secrets/`. Handles mount/unmount. Needs sudo (fingerprint).

## Current task for next agent

1. Install lua-filesystem: `sudo apt install lua-filesystem` (may need user approval)
2. Run `tests/test_sync_integration.lua` with `lua5.1`
3. Deploy to Kobo and verify:
   - Sync Now shows visible progress
   - Notes download to `{DataStorage:getDataDir()}/notes/AI-2526/`
   - Directory structure preserved (nested paths)
   - Error messages visible for bad token / no WiFi
4. After on-device verification, run `tests/test_manifest.lua` to confirm nothing regressed

## Files

```
plugins/
├── markdownreader.koplugin/
│   ├── _meta.lua
│   └── main.lua         # 120 lines
└── syncnotes.koplugin/
    ├── _meta.lua
    ├── main.lua          # ~480 lines
    └── manifest.lua      # pure logic module
tests/
├── test_manifest.lua     # 12 tests, 31 assertions, all passing
└── test_sync_integration.lua  # integration tests (needs lfs)
specs/
├── slice-01-*.md
├── slice-02-*.md
├── ...
└── slice-07-*.md
secrets/                  # PAT file (gitignored)
deploy.sh                 # deploy to Kobo
```
