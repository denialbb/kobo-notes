# Math rendering strategy — decision record

**Status:** Decided · **Date:** 2026-07-30
**Applies to:** `plugins/markdownreader.koplugin` (`math_renderer.lua`,
`math_backend_lua.lua`, `markdown_interceptor.lua`)
**Related:** [`microtex_implementation_spec.html`](microtex_implementation_spec.html)
(pipeline design + deferred native backend), [`DESIGN_final.md`](DESIGN_final.md) §6.6

## The question

Now that LaTeX renders on-device via a pure-Lua backend, two follow-up questions
were asked and answered with measurements rather than argument:

1. Is there any reason *not* to stay with pure-Lua inline rendering?
2. Is a mixed approach viable — cheap inline text for most formulas, a real
   typesetting engine for the hard ones?

**Decision: stay pure Lua. Improve `\frac` and `\sqrt` with CSS before
considering anything else. A mixed native backend is viable but deferred.**

## Where things stand

Measured against the author's real corpus (`notes/AI-2526`, 75 files):

| metric | value |
| --- | --- |
| formulas | 4,952 |
| degraded to source | **0** |
| unrendered commands leaking into output | **0** |
| errors | **0** |
| math overhead, heaviest note (72 KB, 795 formulas) | ~120 ms |

Coverage is not the problem. Everything renders; the open question is only how
*well* some of it renders.

## What pure Lua does badly

Inline HTML cannot express two-dimensional layout. Today that shows up as
ambiguity, not merely as ugliness — which is a stronger objection than
"doesn't look like LaTeX":

| LaTeX | renders as | problem |
| --- | --- | --- |
| `\frac{a+b}{c+d}` | `a+b⁄c+d` | parses to the eye as `a + (b/c) + d` |
| `\frac{\frac{1}{2}}{x}` | `1⁄2⁄x` | effectively unreadable |
| `\sqrt{x^2+y^2}` | `√x²+y²` | no vinculum, so the scope is unclear |

Also imperfect but *not* meaning-changing: `\Bigl(` and friends do not scale,
matrix brackets do not stretch, and `\underbrace` draws no brace (crengine
cannot stretch one).

Superscripts, subscripts, symbols, greek, accents and the multi-row
environments all render correctly and are not at issue.

## How much of the corpus is affected

| | count | share |
| --- | --- | --- |
| all formulas | 4,952 | |
| block (`$$…$$`) | 500 | 10.1% |
| inline (`$…$`) | 4,452 | 89.9% |
| **would benefit from a better renderer** | **241** | **4.9%** |
| └ of those, block | 194 | 80% of them |
| └ of those, inline | 47 | 0.9% of all formulas |

Breakdown of the 241: `\frac` 126, `\begin` 84, `\big`/`\Big` 35, `\sqrt` 9,
`\underbrace` 6, `\binom` 2.

The shape of this matters more than the total. The formulas pure Lua handles
worst are **overwhelmingly display math** (194 of 241).

## Why not go native

The reasons to abandon pure Lua are weaker than they look:

- **Cost does not scale with benefit.** A native MicroTeX backend needs the
  ARMhf cross-toolchain, `.clm` font bundling and a custom `Graphics2D`
  regardless of how rarely it is invoked. Using it for 4% of formulas pays
  100% of the cost for 4% of the benefit.
- **Inline text has real advantages images lack.** It reflows at the reader's
  chosen font size, stays searchable and selectable, and costs no disk. A
  rendered image is a fixed-size bitmap that does none of that — a regression
  on e-ink, not an improvement.
- **Two engines means two failure modes**, and the image path can fail
  *silently* (blank glyphs) in a way text cannot.
- It contradicts `DESIGN_final.md` objective 3 ("without cross-compiling
  anything"), which pure Lua preserves.

## Is a mixed approach viable

**Yes, and the architecture already supports it.** `math_renderer.lua` returns
`{kind = "html"}` or `{kind = "image"}`, so routing per formula is a predicate,
not a redesign. A backend that produces images can be registered without
touching `markdown_interceptor.lua` or `main.lua`.

The viable rule is narrow: **images only for block math that needs them; inline
math always stays text.** The usual objection to mixing — baseline alignment of
inline images against surrounding text, and bitmaps not reflowing when font size
changes — does not apply to display math, which sits on its own line. With this
corpus that would mean ~194 formulas (4%), all on their own lines, with only 47
inline formulas accepting approximation.

It is viable. It is just not yet worth it, because of what follows.

## Why CSS first

crengine's own CSS support closes most of the gap with no second engine:
stacked fractions with a real bar, and a `\sqrt` vinculum, are expressible.

That covers **135 of the 241** affected formulas (`\frac` 126 + `\sqrt` 9) —
56% of the problem set — and specifically the meaning-changing ones. What
remains is ~106 formulas, mostly `\begin` environments that already render
acceptably as multi-row, plus stretchy delimiters that are cosmetic rather than
ambiguous.

Expected effect: the "genuinely wrong" set drops from 4.9% to roughly 1–2%, all
legibility-neutral.

There is a cheaper reading of "mixed" here, and it is what this step actually
is: mixing *rendering strategies within Lua* — plain inline text for simple
math, CSS box layout for structural math — rather than mixing engines.

### Caveat on the CSS evidence

Support was checked by running `strings` over `libs/libcrengine.so` on the
device and grepping for property names. `inline-block`, `border-top`,
`border-bottom`, `vertical-align`, `overline`, `inline-table`, `table-cell` and
`table-row` all appear. **This is a crude heuristic, not proof**: a string in
the binary shows the property is known to the parser, not that it is honoured in
the layout path, and an exact-match grep for `text-decoration` found nothing
even though the backend already relies on it. Treat this as encouraging, and
confirm by rendering on device before building anything substantial on it.

## Decision and ordering

1. **Implement CSS stacking for `\frac` and `\sqrt`.** Pure Lua, one file plus
   tests, removes the ambiguity, covers 56% of the problem set.
2. **Re-measure on device.** Establish what still genuinely reads wrong, rather
   than assuming.
3. **Only then** decide whether the ~100 remaining formulas justify a native
   backend behind the existing seam.

Step 1 is not yet done as of this record.

## Correction on the record

An earlier revision of the MicroTeX spec claimed crengine rasterises SVG via
**nanosvg** (paths only, no text rendering) and called it the highest-risk item
in any native plan, predicting formulas would silently rasterise blank.

**That was wrong for the deployed device and has been retracted.** Inspecting
`libs/libcrengine.so` on v2026.07 shows no nanosvg symbols at all; the
rasteriser is **lunasvg**, with `LunaSVGGlyphsCollector::addGlyph` and an
`external_context_t` passed into `loadFromData`, indicating crengine supplies
its own font context. SVG `<text>` most likely renders.

This makes a native backend *more* viable than previously recorded. It is
deferred here on cost/benefit grounds, not because it is blocked.
