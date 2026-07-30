# kobo-notes

Sync and render Markdown notes from a private GitHub repo on a Kobo e-reader
running KOReader.

Two pure-Lua koplugins (no cross-compilation needed):

- **`markdownreader.koplugin`** — taps a `.md` file and renders it formatted
  (headings, bold, lists, links) via the bundled luamd parser + crengine HTML
  renderer. No conversion step needed.
- **`aiactions_sync.koplugin`** — from the Kobo itself, fetches `.md` files from
  a private GitHub repo over HTTPS using a PAT. One menu action, no PC in the
  loop.

## Quick start

```bash
# Clone plugin folders to the Kobo (USB mounted or SSH)
rsync -av --delete plugins/ /mnt/kobo/.adds/koreader/plugins/
# Restart KOReader → Tools → Plugin management → enable both
```

## Docs

See `docs/DESIGN_final.md` for the complete, verified design (46KB, post-review).
All research reports are in `docs/research-*.txt`.

## Dev setup

```bash
git clone https://github.com/koreader/koreader.git ~/.repos/koreader
cd ~/.repos/koreader
./kodev run -b  # run the emulator to test plugins
```

## Structure

```
kobo-notes/
├── docs/                       # Design docs, research, reports
├── plugins/
│   ├── markdownreader.koplugin/  # .md renderer
│   └── aiactions_sync.koplugin/  # GitHub sync
├── spec/                       # busted tests (TDD)
├── README.md
└── .gitignore
```
