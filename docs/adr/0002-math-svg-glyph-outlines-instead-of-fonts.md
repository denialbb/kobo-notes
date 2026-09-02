# Render MicroTeX math as SVG glyph outlines instead of `<text>` font references

Replace the font-dependent `<text>` glyphs that the native MicroTeX backend emits
with font-independent `<path>` outlines, so math symbols render correctly on the
Kobo regardless of which fonts are installed or whether the SVG engine resolves
`font-family`.

## Context

`markdownreader.koplugin` typesets LaTeX math through `libmicrotex.so`. The custom
`SvgGraphics2D.cpp` backend renders each glyph as an SVG `<text>` element carrying
`font-family="XITS Math"` plus a numeric character reference and a `matrix(...)`
transform, e.g.

```svg
<text x="0" y="0" font-family="XITS Math" font-size="1px"
      transform="matrix(32,0,0,32,296.98,53.16)" fill="rgb(0,0,0)" fill-opacity="1">&#8721;</text>
```

Users reported garbled/malformed math in `risposte_esame.md` — the biggest offender
being the sum (`\sum`, U+2211) and epsilon symbols.

The generated SVGs are structurally valid; rendering them with a fontconfig-backed
rasterizer (e.g. `rsvg-convert`) produces correct output. The failure is specific to
KOReader's rendering engine (crengine):

- crengine does not resolve `font-family="XITS Math"` inside SVG `<text>` to a
  bundled font, and XITS Math is not installed on the device anyway.
- It falls back to the document/reading font, which covers ASCII/greek but not the
  math operator block (U+2192, U+2202, U+2208, U+2211, U+2212, U+2264, …), so those
  codepoints render as boxes/tofu.

So "install XITS Math" is not a fix: the SVG text glyphs depend on a font the
renderer is not guaranteed to look up, and even bundling a math font would not help
if crengine ignores the SVG `font-family`.

## Decision

Post-process the SVG string in Lua (in `math_svg_pathify.lua`) and rewrite every
`<text ...>&#cp;</text>` glyph into a `<path>` whose contour data is baked in from a
real math-capable font:

1. `tools/gen_glyph_paths.py` converts the ~116 codepoints MicroTeX actually emits
   into SVG path `d` strings and writes `math_glyph_paths.lua`. FreeSerif is used
   because it covers **all** of those codepoints (verified) and its serif style is
   closest to XITS/Computer Modern.
2. `math_svg_pathify.convert(svg)` replaces each `<text>` glyph with a `<path>` using
   the baked outline. The composed transform is
   `matrix(a·fs/upm, b·fs/upm, −c·fs/upm, −d·fs/upm, e, f)`, which maps the font-unit
   outline (em = fs px, y-up) into device SVG coordinates (y-down).
3. `math_backend_microtex.lua` runs the converter on the SVG before writing it to the
   cached `math_svg/*.svg` file.

This makes math rendering independent of installed fonts and of the SVG engine's
`font-family` handling. It also requires no rebuild of `libmicrotex.so`, so the fix is
deployable without the cross-compiler.

## Consequences

- Math renders as vector outlines with no font dependency; the sum/epsilon symbols
  display correctly.
- No change to `SvgGraphics2D.cpp` / `libmicrotex.so` is required; the native backend
  keeps its current text-based output and Lua converts it.
- Payload cost: `math_glyph_paths.lua` is ~28 KB of outline data.
- Glyphs for a codepoint absent from the baked table are left as `<text>`, degrading
  gracefully (they render as before rather than disappearing).
- `math_glyph_paths.lua` must be regenerated (`tools/gen_glyph_paths.py`) if MicroTeX
  starts emitting codepoints not already covered.
- The baked outlines are derived from FreeSerif (GPL); this is acceptable for the
  personal plugin deployment, but note the license if distributed.
- `deploy.sh` now tolerates a missing cross-compiler (keeps the device's existing
  `libmicrotex.so`) because the change is Lua-only and no rebuild is needed.
