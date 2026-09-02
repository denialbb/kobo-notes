# Project Context & Agent Guidelines: kobo-notes

This repository contains custom KOReader plugins and deployment toolchains for the **Kobo Libra 2** e-reader.

See [CONTEXT-MAP.md](file:///home/denial/Projects/kobo-notes/CONTEXT-MAP.md) for the high-level domain model and inter-plugin relationships.

---

## 1. Target Hardware & Platform Constraints

- **Device**: Kobo Libra 2 (32-bit ARMv7-A, Cortex-A9, NEON SIMD, hard-float `arm-linux-gnueabihf`).
- **Operating System & C Library**: Embedded Linux kernel 4.1.15 with **glibc 2.19** (`/lib/ld-linux-armhf.so.3`, `/lib/libc.so.6`, `/lib/libm.so.6`).
- **Host Application**: [KOReader](https://github.com/koreader/koreader) running LuaJIT 2.1.
- **Rendering Engines**:
  - Document layout: **Crengine** (CoolReader engine in C++). Note: Crengine CSS support is limited (e.g., avoid `display: block` inside inline-block containers; use `<br/>` for line breaks).
  - Vector math rendering: Crengine embedded **NanoSVG** engine.

---

## 2. Plugins Architecture

All plugins reside under `plugins/` as KOReader `.koplugin` packages:

1. **`markdownreader.koplugin`** ([CONTEXT.md](file:///home/denial/Projects/kobo-notes/plugins/markdownreader.koplugin/CONTEXT.md)):
   - Intercepts opening of Markdown notes and renders them into HTML + SVG.
   - Typesets LaTeX math through two swappable backends:
     - **MicroTeX** (`libmicrotex.so`): Native C++17 library cross-compiled for Kobo. Renders math to SVG. Post-processed by `math_svg_pathify.lua` to rewrite `<text>` elements to font-independent `<path>` outlines using baked FreeSerif glyphs ([ADR 0002](file:///home/denial/Projects/kobo-notes/docs/adr/0002-math-svg-glyph-outlines-instead-of-fonts.md)).
     - **Pure-Lua** (`math_backend_lua.lua`): Fallback pure-Lua parser converting LaTeX to unicode HTML.
2. **`syncnotes.koplugin`** ([CONTEXT.md](file:///home/denial/Projects/kobo-notes/plugins/syncnotes.koplugin/CONTEXT.md)):
   - Incremental note sync from remote GitHub repositories to local storage via git tree digests and JSON manifests.
3. **`flashcards.koplugin`** ([CONTEXT.md](file:///home/denial/Projects/kobo-notes/plugins/flashcards.koplugin/CONTEXT.md)):
   - Interactive recall quiz engine parsing Q&A cards from notes.

---

## 3. Toolchain & Cross-Compilation

Toolchains are managed with `mise` ([mise.toml](file:///home/denial/Projects/kobo-notes/mise.toml)).

- **Cross-Compiler**: `zig c++ -target arm-linux-gnueabihf.2.19`
- **Build Command**:
  ```bash
  cd plugins/markdownreader.koplugin
  make KOBO_CXX="zig c++ -target arm-linux-gnueabihf.2.19" kobo
  mv kobo-libmicrotex.so libmicrotex.so
  ```
- **Crucial ABI / Linker Constraints** (see [docs/REPORT.md](file:///home/denial/Projects/kobo-notes/docs/REPORT.md)):
  - `-fPIC`: Enforces position-independent code (prevents `R_ARM_REL32` / `0x03` relocations).
  - `-fno-use-cxa-atexit`: Emits static destructors into `.fini_array` to prevent glibc 2.19 memory faults during Lua teardown (`os.exit(86, true)`).
  - `-Wl,-z,nodelete`: Prevents DSO unmapping during `dlclose()` / `lua_close()`.
  - `-Wl,--hash-style=sysv`: Generates legacy SysV hash tables (`.hash`) required by glibc 2.19.
  - `fix_relro.py`: Neutralizes `PT_GNU_RELRO` program headers to `PT_NULL` to prevent loader crashes.

---

## 4. Verification Procedures

Before deployment, verify `libmicrotex.so` satisfies all target bounds:
```bash
# 1. Zero unsupported relocations
readelf -r libmicrotex.so | grep -E 'R_ARM_REL32|0x03|0x6c|0x54'

# 2. glibc symbols version <= 2.19
readelf -V libmicrotex.so | grep GLIBC_

# 3. Dynamic flags (NODELETE and SysV HASH)
readelf -d libmicrotex.so | grep -E 'FLAGS|NODELETE|HASH'

# 4. GNU_RELRO neutralized
readelf -l libmicrotex.so | grep GNU_RELRO
```

---

## 5. Testing Guidelines

Run the dependency-free test suite:
```bash
lua run_busted_tests.lua
```
- All test specs are placed in `tests/*_spec.lua`.
- The test runner stubs KOReader environment dependencies (`ffi`, `logger`, `UIManager`).
- Tests must pass with zero failures before committing changes.

---

## 6. Math Glyphs & Outlines (ADR 0002)

When MicroTeX encounters LaTeX formulas with new mathematical symbols that render as tofu:
1. Ensure FreeSerif font is accessible (`FreeSerif.ttf`).
2. Run the glyph generator to re-bake `math_glyph_paths.lua`:
   ```bash
   python3 tools/gen_glyph_paths.py \
     --out plugins/markdownreader.koplugin/math_glyph_paths.lua \
     --font /path/to/FreeSerif.ttf \
     --svg-dir /path/to/rendered/math_svg \
     --codepoints <optional_comma_separated_unicode_decimals>
   ```

---

## 7. Deployment

Deploy to a USB-connected Kobo:
```bash
./deploy.sh
```
This script handles cross-compilation (if toolchains exist), mounting `KOBOeReader`, cache invalidation (`.rendered/`, HTML cache), plugin synchronization, and secret copying.
