# kobo-notes

![Lua](https://img.shields.io/badge/Lua-5.1%20%7C%205.5%20%7C%20LuaJIT-blue?logo=lua)
![KOReader](https://img.shields.io/badge/KOReader-v2026.07-green)
![Status](https://img.shields.io/badge/Status-Stable-brightgreen)

Synchronize and render Markdown notes with embedded LaTeX math from a private GitHub repository on a Kobo e-reader running KOReader.

The system consists of three KOReader plugins:

- **`markdownreader.koplugin`** — Intercepts `.md` note opens and renders formatted documents (headings, formatting, lists, links, code blocks, tables) using KOReader's bundled `luamd` parser and Crengine. Typesets inline and display LaTeX math via pure-Lua Unicode/HTML or native MicroTeX vector SVG.
- **`syncnotes.koplugin`** — Fetches and synchronizes `.md` files and directory trees from a private GitHub repository over HTTPS using the GitHub REST API (Git Trees) and a personal access token.
- **`flashcards.koplugin`** — Discovers and parses `flashcards.md` files across the synced note tree to run interactive recall quiz sessions directly on the e-ink display.

> [!NOTE]
> **Status:** Implemented and validated against KOReader **v2026.07** on Kobo Libra 2 hardware.

## Repository Setup

The three plugins are maintained as Git submodules:

```bash
git clone git@github.com:denialbb/kobo-notes.git
cd kobo-notes
git submodule update --init --recursive
```

## Deployment

Deploy plugins and configuration to a connected Kobo over USB:

```bash
./deploy.sh
```

`deploy.sh` detects the device mount via filesystem label (`KOBOeReader`), validates the destination `.adds/koreader/` directory, copies plugin directories to `.adds/koreader/plugins/`, and synchronizes credentials from `secrets/`.

Optional environment overrides:

```bash
KOBO_DEV=/dev/sdX ./deploy.sh     # Override block device detection
KOBO_MOUNT=/mnt/foo ./deploy.sh   # Override mount point path
KOBO_LABEL=MYKOBO ./deploy.sh     # Override target filesystem label
```

After deployment, restart KOReader and enable the plugins under **Tools → Plugin management**.

## Diagnostics Collection

Collect on-device logs, rendered HTML artifacts, and configuration state without modifying device storage:

```bash
./collect-diagnostics.sh          # Pass --keep-mounted to retain filesystem mount
```

Output is stored in `diagnostics/<timestamp>/` and linked to `diagnostics/latest/`:

| File / Directory | Description |
| --- | --- |
| `SUMMARY.md` | Device environment summary, triage notes, and recent error log extracts |
| `crash-last-session.log` | KOReader log output for the latest session |
| `crash-errors.log` | Filtered ERROR/WARN messages with line references into `crash.log` |
| `markdownreader-debug/` | Intermediate HTML passed to Crengine and rendering diagnostics |
| `cache-md/` | Cached HTML documents on device |
| `plugins-on-device/` | Current plugin source files from the device filesystem |
| `device-vs-repo.diff` | Line diff between device plugin code and local repository |

> [!WARNING]
> Access tokens are redacted from collected logs. Credentials stored in `secrets/` are never copied.

## Test Suite

Execute the test suite across unit and integration specs:

```bash
lua run_busted_tests.lua
```

| Test File | Target Subsystem |
| --- | --- |
| `tests/markdown_interceptor_spec.lua` | LaTeX extraction, code fence preservation, token replacement |
| `tests/math_backend_lua_spec.lua` | Pure-Lua LaTeX formula conversion, Unicode mapping, environment support |
| `tests/math_renderer_spec.lua` | Backend dispatch, hashing, fallback mechanisms, cache management |
| `tests/flashcards_parser_spec.lua` | Flashcard format parsing, multi-line blocks, CRLF handling |
| `tests/flashcards_quiz_spec.lua` | Quiz session state machine, scoring, missed deck generation |
| `tests/flashcards_cli_spec.lua` | CLI harness execution against note fixture corpus |
| `tests/test_manifest.lua` | Sync manifest diffing and state reconciliation |
| `tests/test_sync_integration.lua` | GitHub API synchronization pipeline (requires `luafilesystem`) |

## Math Rendering Pipeline

Mathematical formulas are extracted into placeholder tokens prior to Markdown conversion to prevent Markdown syntax parsers from corrupting formula characters (`_`, `*`, `\`):

```text
.md → Token Extraction → luamd (HTML conversion) → Formula Substitution → Crengine
```

The rendering architecture isolates typesetting behind `math_renderer.lua`:
- **Pure-Lua Backend (`math_backend_lua.lua`)**: Converts LaTeX subsets directly into Unicode and HTML structures. Unsupported complex constructs fall back to monospace source rendering without interrupting document display.
- **Native MicroTeX Backend (`math_backend_microtex.lua`)**: Cross-compiled C++17 shared library (`libmicrotex.so`) utilizing `zig c++` for glibc 2.19 compatibility, emitting vector SVG markup rendered via Crengine's NanoSVG engine.

## Output and Cache Storage

- **Rendered Document Output**: Generated HTML files are stored in a hidden `.rendered/` directory adjacent to the source `.md` file (e.g. `notes.md` → `.rendered/notes.md.html`).
- **Math SVG Vectors**: Formula images are stored under `<datadir>/markdownreader/math/` indexed by formula content hash.
- **File Management**: Generated files are tracked in a persistent registry. Clean removal is available via **Tools → Markdown Reader → Delete generated files**.

## Documentation Index

| Document | Description |
| --- | --- |
| [CONTEXT-MAP.md](./CONTEXT-MAP.md) | Bounded contexts and system domain map |
| [docs/DESIGN_final.md](./docs/DESIGN_final.md) | Authoritative design specification for KOReader integrations |
| [docs/REPORT.md](./docs/REPORT.md) | MicroTeX dynamic linking, glibc 2.19 ABI, and exit crash resolution report |
| [docs/adr/0001-zig-cross-compilation-for-kobo-glibc.md](./docs/adr/0001-zig-cross-compilation-for-kobo-glibc.md) | Architecture Decision Record: Zig cross-compilation for Kobo glibc 2.19 |
| [docs/math-rendering-strategy.md](./docs/math-rendering-strategy.md) | Math rendering strategy analysis and corpus measurements |

## Directory Structure

```text
kobo-notes/
├── docs/                          # Architecture specs, ADRs, technical reports
├── tests/                         # Test suites and fixture corpora (tests/fixtures/)
├── tools/                         # Development utilities (flashcards-cli.lua)
├── plugins/
│   ├── markdownreader.koplugin/   # Markdown parser, math rendering pipeline, MicroTeX DSO
│   ├── syncnotes.koplugin/        # GitHub REST synchronization plugin
│   └── flashcards.koplugin/       # Flashcard discovery and quiz plugin
├── secrets/                       # API credentials (gitignored)
├── deploy.sh                      # USB deployment script
└── run_busted_tests.lua           # Test runner
```

