---
name: glyph-generator
description: >-
  Extract and bake font-independent SVG glyph outlines for MicroTeX LaTeX formulas using FreeSerif. Use when mathematical symbols render as tofu, when new LaTeX formulas are introduced, or when updating math_glyph_paths.lua.
---

# MicroTeX SVG Glyph Outline Generator

This skill guides the process of baking FreeSerif vector outlines into `math_glyph_paths.lua` to ensure LaTeX math symbols render crisply on KOReader without depending on installed fonts (per [ADR 0002](file:///home/denial/Projects/kobo-notes/docs/adr/0002-math-svg-glyph-outlines-instead-of-fonts.md)).

---

## 1. When to Use

- Mathematical operators (e.g. `\sum`, `\prod`, greek letters, arrows) appear as empty boxes or tofu on the Kobo device.
- New lecture notes or math formulas introduce mathematical symbols not yet covered by the baked glyph table.
- Modifying or regenerating `plugins/markdownreader.koplugin/math_glyph_paths.lua`.

---

## 2. Prerequisites

- Python 3 with `fontTools`:
  ```bash
  python3 -c "import fontTools"
  ```
- FreeSerif font file (available on Kobo or local system):
  ```bash
  # Check Kobo font mount
  ls -la "/home/denial/Mount/KOBO/.adds/koreader/fonts/freefont/FreeSerif.ttf"
  ```

---

## 3. Execution

### Option A: Automatic Extraction from Rendered SVGs

Scan existing rendered SVGs from notes on the device to collect all codepoints in use:

```bash
python3 tools/gen_glyph_paths.py \
  --out plugins/markdownreader.koplugin/math_glyph_paths.lua \
  --font "/home/denial/Mount/KOBO/.adds/koreader/fonts/freefont/FreeSerif.ttf" \
  --svg-dir "/home/denial/Mount/KOBO/.adds/koreader/notes/AI-2526/eliva/.rendered/math_svg"
```

### Option B: Adding Specific Missing Codepoints

If a specific symbol (e.g. `\approx` U+2248 -> decimal `8776`) needs to be included:

```bash
python3 tools/gen_glyph_paths.py \
  --out plugins/markdownreader.koplugin/math_glyph_paths.lua \
  --font "/home/denial/Mount/KOBO/.adds/koreader/fonts/freefont/FreeSerif.ttf" \
  --svg-dir "/home/denial/Mount/KOBO/.adds/koreader/notes/AI-2526/eliva/.rendered/math_svg" \
  --codepoints 8776
```

---

## 4. Verification

1. Verify that `math_glyph_paths.lua` contains valid Lua table syntax and non-empty paths:
   ```bash
   head -n 15 plugins/markdownreader.koplugin/math_glyph_paths.lua
   ```

2. Run the spec suite to ensure the post-processor converts glyphs accurately:
   ```bash
   lua run_busted_tests.lua
   ```

3. Commit the updated `math_glyph_paths.lua` in both the submodule and the parent repository.
