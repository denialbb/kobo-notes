# kobo-notes

Sync and render Markdown notes from a private GitHub repo on a Kobo e-reader
running KOReader — including LaTeX math, on-device, with no PC in the loop.

Two pure-Lua koplugins. **Nothing is cross-compiled**; both are dropped into
KOReader's `plugins/` directory and hot-loaded.

- **`markdownreader.koplugin`** — tap a `.md` file and it opens formatted
  (headings, bold, lists, links, code, tables) via KOReader's bundled luamd
  parser and the crengine HTML renderer. Also renders inline and block LaTeX
  (`$…$`, `$$…$$`) to unicode/HTML.
- **`syncnotes.koplugin`** — from the Kobo itself, fetches `.md` files from a
  private GitHub repo over HTTPS using a personal access token. One menu action,
  add/update/delete mirrored against the remote branch.

**Status:** both implemented and deployed. Verified against KOReader
**v2026.07** on-device (2026-07-30).

## Clone

The two plugins live in **separate submodule repos**, so a plain `git clone`
leaves `plugins/` empty:

```bash
git clone git@github.com:denialbb/kobo-notes.git
cd kobo-notes
git submodule update --init --recursive
```

Both submodules use SSH remotes and require access to the `denialbb` repos.

## Deploy

With the Kobo connected over USB:

```bash
./deploy.sh
```

It builds nothing by default, clears the generated HTML and math caches, copies
both plugins to `<mount>/.adds/koreader/plugins/`, and copies `secrets/` (your
PAT) to the device.

The Kobo is **found automatically by filesystem label** (`KOBOeReader`) — the
device node moves around depending on how many USB disks are attached, so it is
never guessed. If the device is already mounted anywhere (including by a desktop
auto-mounter under `/run/media/...`), that mount is used and left alone;
otherwise it is mounted at `/mnt/kobo` and unmounted afterwards. It refuses to
proceed if the mount point has no `.adds/koreader`, so it cannot deploy into the
wrong disk.

Overrides, all optional:

```bash
KOBO_DEV=/dev/sdX ./deploy.sh     # skip autodetection
KOBO_MOUNT=/mnt/foo ./deploy.sh   # different fallback mount point
KOBO_LABEL=MYKOBO ./deploy.sh     # non-standard label
```

Then on the Kobo: restart KOReader → Tools → Plugin management → enable both.

## Collecting diagnostics

When something fails on-device, plug the Kobo in and run:

```bash
./collect-diagnostics.sh          # add --keep-mounted to leave it mounted
```

This copies everything needed to debug into `diagnostics/<timestamp>/` (and
points `diagnostics/latest` at it) without modifying the device:

| File | What it is |
| --- | --- |
| `SUMMARY.md` | **read this first** — environment, triage, most recent errors |
| `crash-last-session.log` | KOReader's log for the most recent boot only |
| `crash-errors.log` | every ERROR/WARN/traceback, with line numbers into `crash.log` |
| `markdownreader-debug/` | the exact HTML handed to crengine, plus the plugin's report |
| `cache-md/` | generated HTML still in the cache |
| `plugins-on-device/` | plugin sources as they exist on the Kobo |
| `device-vs-repo.diff` | device vs repo — non-empty means drift |

GitHub tokens are stripped from everything collected, and `secrets/` is never
copied. The script warns if a credential-shaped string survives redaction.

`device-vs-repo.diff` matters more than it looks: working fixes have twice
existed *only* on the device and been destroyed by the next deploy.

## Tests

```bash
lua run_busted_tests.lua      # 71 tests
```

Despite the filename this is a **hand-rolled, dependency-free runner**, not the
`busted` framework — there is nothing to install. It auto-discovers
`tests/*_spec.lua` and passes on Lua 5.1, LuaJIT, and 5.5.

| File | Covers |
| --- | --- |
| `tests/markdown_interceptor_spec.lua` | math extraction, code-fence exclusion, substitution |
| `tests/math_renderer_spec.lua` | backend selection, fallback, caching, hashing |
| `tests/test_manifest.lua` | sync manifest diffing (standalone: `lua tests/test_manifest.lua`) |
| `tests/test_sync_integration.lua` | sync pipeline (needs `lua-filesystem`) |

## Math rendering

Math is extracted into placeholder tokens *before* markdown conversion (luamd
would otherwise mangle `_`, `*` and `\` inside formulas) and substituted back
*after*, which lets a backend return either inline HTML or an image:

```
.md → extract math to tokens → mdToHtml (luamd) → substitute → crengine
```

The renderer sits behind a backend seam (`math_renderer.lua`). The shipping
backend is pure Lua and maps a LaTeX subset to unicode and HTML. Anything it
cannot typeset — `\begin{cases}`, matrices, `align` — degrades to the LaTeX
source in monospace rather than vanishing, and math failure can never prevent a
document from opening.

Measured on a real 75-file corpus: 4,952 formulas, 0 errors, 1.7% degraded to
source.

A native MicroTeX backend is **deferred** — see
`docs/microtex_implementation_spec.html` for the design and the recorded risks.

Known gap: math inside 4-space-indented code blocks is still extracted. Fenced
blocks and inline code spans are correctly skipped.

## Where generated files go

Rendered HTML is written to a hidden `.rendered/` folder **beside the source
`.md`**, and regenerated every time the `.md` is opened:

```
oc/rilassamenti/
  notes.md
  .rendered/notes.md.html
```

It used to go in a single shared cache, which was wrong twice over. This notes
tree has 18 files called `notes.md` and 18 called `flashcards.md` — 47 of 75
filenames are not unique — so renders overwrote each other. And a cache is
wiped, so every render was lost on reboot.

Math images, if a future image-producing backend is enabled, go in
`<datadir>/markdownreader/math/`. Shared rather than per-document, because the
cache key is a content hash and identical formulas recur across many notes; and
outside `cache/` so they survive a reboot. The pure-Lua backend that ships emits
inline HTML and writes no image files at all.

**Tools → Markdown Reader → Delete generated files** removes every `.rendered/`
folder, the math images, and any leftovers in the old cache location. It asks
first, and it only deletes files carrying the plugin's marker comment — a file
you wrote yourself that happens to sit in `.rendered/` is reported and kept.
Your `.md` files are never touched.

Generated files are tracked in an index under `<datadir>/markdownreader/`, so
cleanup is exact rather than a filesystem sweep. Syncing is unaffected:
syncnotes works from its own manifest of `.md` files and ignores everything
else.

## Docs

| Document | What it is |
| --- | --- |
| `docs/DESIGN_final.md` | **Authoritative design.** Citations re-verified against v2026.07. |
| `docs/microtex_implementation_spec.html` | Math pipeline design + deferred native backend |
| `docs/math-rendering-strategy.md` | Why rendering stays pure Lua, with corpus measurements |
| `specs/slice-*.md` | Historical TDD slices — a record of how the work was split |
| `docs/PROJECT_OVERVIEW.md` | ⚠️ Superseded early draft, kept for history |
| `docs/research-*.txt` | Background research reports |

## Structure

```
kobo-notes/
├── docs/                          # design docs, research
├── specs/                         # TDD slice specs (historical)
├── tests/                         # test suites
├── plugins/
│   ├── markdownreader.koplugin/   # submodule — .md + math renderer
│   └── syncnotes.koplugin/        # submodule — GitHub sync
├── secrets/                       # PAT (gitignored)
├── deploy.sh
└── run_busted_tests.lua
```

## Dev notes

There is no local KOReader checkout in this repo. The full KOReader Lua frontend
ships on the device itself under `/mnt/kobo/.adds/koreader/frontend/`, which is
what the design doc's citations are verified against.

To test plugins against the emulator instead, clone KOReader separately:

```bash
git clone https://github.com/koreader/koreader.git
cd koreader && ./kodev run
```
