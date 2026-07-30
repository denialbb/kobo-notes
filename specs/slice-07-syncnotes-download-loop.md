# Slice 7: syncnotes — download loop + WiFi management + full sync

> **Status: IMPLEMENTED — historical record (verified 2026-07-30).**
> Shipped in `plugins/syncnotes.koplugin/main.lua` (`httpGet`, `startSync`,
> `executeSync`); integration test in `tests/test_sync_integration.lua`.
> This is a record of how the work was sliced, not pending work.
> Divergences: progress is a custom `SyncProgressDialog` (progress bar, repaints
> throttled to 150ms to avoid e-ink flicker) rather than repeated InfoMessages;
> downloads are buffered with `ltn12.sink.table` and then written, not streamed
> with `ltn12.sink.file`; paths are escaped with `util.urlEncode`; and
> `getNotesDir()` uses the configurable `notes_root` setting.

Depends on: Slices 4, 5, 6 (skeleton + PAT/config + manifest logic)

## Goal

Wire everything together into `executeSync()`:

1. Check PAT exists (re-prompt if missing)
2. `NetworkMgr:runWhenOnline()` for WiFi
3. Fetch GitHub Trees API (recursive)
4. Compare with local manifest (using Manifest module)
5. Download changed/new files from raw.githubusercontent.com
6. Delete removed files
7. Save updated manifest
8. `NetworkMgr:afterWifiAction()` to restore WiFi state

## Files to modify

### `plugins/syncnotes.koplugin/main.lua`

Add the `httpGet` helper, `executeSync` method, and wire `onSyncNow()` to trigger the full flow.

New requires:

```lua
local NetworkMgr    = require("ui/network/manager")
local JSON          = require("json")
local https         = require("ssl.https")
local ltn12         = require("ltn12")
local logger        = require("logger")
local util          = require("util")
local Manifest      = require("manifest")
```

### Key method stubs

**`httpGet(url, pat, extra_headers)`** — synchronous HTTPS GET returning body string.

**`executeSync(pat)`** — the full sync pipeline:

1. Show progress InfoMessage
2. Fetch tree via GitHub API
3. Manifest comparison
4. Download loop with progress updates
5. Delete removed files
6. Save manifest
7. Report results

## Important details

- `raw.githubusercontent.com` URLs need `util.encodeURIComponent(entry.path)` for spaces/special chars
- Create parent directories with `lfs.mkdir()` for nested paths
- Stream downloads directly to file using `ltn12.sink.file(out_file)`
- Each `https.request` has a 30-second timeout
- `UIManager:forceRePaint()` after each progress update
- Error messages: 401→bad token, 403→rate limit, 404→repo/path wrong, generic→HTTP code

## Notes directory

Derived from configured repo name:

```lua
function SyncNotes:getNotesDir()
    return DataStorage:getDataDir() .. "/notes/" .. self.settings:readSetting("repo") .. "/"
end
```

Manifest file location: `notes/{repo}/.sync_manifest.json`

## Acceptance (on-device only — requires network + GitHub)

- "Sync Now" with valid PAT: downloads notes from repo, shows progress, reports counts
- Incremental sync: second run with no changes shows 0 downloaded
- New file on GitHub → gets downloaded
- Deleted file on GitHub → gets removed locally
- Bad token → 401 error message
- No WiFi → NetworkMgr prompts to turn on WiFi
