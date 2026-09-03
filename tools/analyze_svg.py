#!/usr/bin/env python3
"""Static SVG Analysis tool for MicroTeX and KOReader math SVGs.

Performs static quality & defect analysis on SVG math output:
1. Parses SVG root and extracts declared viewBox, width, and height.
2. Computes the tight bounding box of graphical content (paths, rects, lines, circles,
   polygons, and <use> references) accounting for transform matrices, scale, translate.
3. Flags any content overflow / clipping relative to the declared viewBox or dimensions.
4. Detects empty text elements, unresolved font references, or missing operator glyphs
   (e.g., untranslated <text> elements where font outline was missing, or unknown glyphs).
5. Returns machine-readable JSON reports or human-readable CLI summaries, with clear exit codes.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from fontTools.misc.transform import Transform
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import SVGPath

logger = logging.getLogger(__name__)

DEFAULT_FONTS_DIR = "/home/denial/Projects/kobo-notes/plugins/markdownreader.koplugin/res/fonts"

KNOWN_MATH_FONTS = {
    "cmex10", "cmmi10", "cmmib10", "cmr10", "cmbsy10", "cmsy10",
    "msam10", "msbm10", "eufm10", "eufb10", "rsfs10", "stmary10",
    "special", "dsrom10", "bi10", "bx10", "i10", "r10", "sb10",
    "sbi10", "si10", "ss10", "tt10", "cmbx10", "cmbxti10", "cmss10",
    "cmssbx10", "cmssi10", "cmti10", "cmtt10", "FreeSerif", "XITS Math",
    "Latin Modern Math", "STIX Two Math",
}

CRITICAL_OPERATOR_CODEPOINTS = {
    # Large operators & integrals
    0x2211: "∑ (summation)",
    0x220F: "∏ (product)",
    0x2210: "∐ (coproduct)",
    0x222B: "∫ (integral)",
    0x222C: "∬ (double integral)",
    0x222D: "∭ (triple integral)",
    0x2A0C: "⨌ (quadruple integral)",
    0x222E: "∮ (contour integral)",
    # Key greek symbols
    0x03B5: "ε (greek small letter epsilon)",
    0x03F5: "ϵ (greek lunate epsilon symbol)",
    0x03B4: "δ (delta)",
    0x03BB: "λ (lambda)",
    0x03BC: "μ (mu)",
    0x03C0: "π (pi)",
    0x03C3: "σ (sigma)",
    0x03C9: "ω (omega)",
    0x221E: "∞ (infinity)",
    0x2202: "∂ (partial differential)",
    0x2207: "∇ (nabla)",
    # TeX CM internal / private font positions often used for sum/integral
    80: "cmex10 P (display summation)",
    82: "cmex10 R (inline summation)",
    88: "cmex10 X (display integral)",
    8211: "summation",
}


def parse_length(val: str | None) -> float | None:
    """Parse length string with optional pt/px units to float."""
    if not val:
        return None
    val = val.strip()
    # Remove unit suffixes
    for unit in ("px", "pt", "em", "ex", "%", "in", "cm", "mm"):
        if val.endswith(unit):
            val = val[:-len(unit)].strip()
            break
    try:
        return float(val)
    except ValueError:
        return None


def parse_viewbox(vb_str: str | None) -> tuple[float, float, float, float] | None:
    """Parse viewBox='min-x min-y width height'."""
    if not vb_str:
        return None
    parts = [float(p) for p in re.split(r'[\s,]+', vb_str.strip()) if p]
    if len(parts) == 4:
        return (parts[0], parts[1], parts[2], parts[3])
    return None


def parse_transform(attr: str | None) -> Transform:
    """Parse SVG transform attribute into fontTools Transform."""
    t = Transform()
    if not attr:
        return t
    for match in re.finditer(r'([a-zA-Z]+)\s*\(([^)]*)\)', attr):
        cmd, args_str = match.groups()
        args = [float(x) for x in re.split(r'[\s,]+', args_str.strip()) if x]
        if cmd == "matrix" and len(args) == 6:
            t = t.transform(args)
        elif cmd == "translate":
            tx = args[0]
            ty = args[1] if len(args) > 1 else 0.0
            t = t.translate(tx, ty)
        elif cmd == "scale":
            sx = args[0]
            sy = args[1] if len(args) > 1 else sx
            t = t.scale(sx, sy)
    return t


def load_font_codepoint_maps(fonts_dir: str) -> dict[str, set[int]]:
    """Index available fonts and their supported glyph codepoints."""
    fonts_map: dict[str, set[int]] = {}
    fonts_path = Path(fonts_dir)
    if not fonts_path.exists():
        return fonts_map

    try:
        from fontTools.ttLib import TTFont
        for ttf in fonts_path.glob("**/*.ttf"):
            name = ttf.stem
            try:
                font = TTFont(str(ttf))
                cps: set[int] = set()
                for table in font["cmap"].tables:
                    if table.isUnicode() or table.platformID in (0, 3):
                        cps.update(table.cmap.keys())
                fonts_map[name] = cps
            except (OSError, KeyError, ValueError) as err:
                logger.debug("Could not read font %s: %s", ttf, err)
    except ImportError:
        logger.debug("fontTools not installed, skipping font codepoint indexing")

    return fonts_map


class SvgAnalyzer:
    """Performs static analysis on an SVG file or XML string."""

    def __init__(self, fonts_dir: str = DEFAULT_FONTS_DIR) -> None:
        self.fonts_dir = fonts_dir
        self._font_cmap = load_font_codepoint_maps(fonts_dir)

    def analyze(self, svg_source: str | Path, source_name: str | None = None) -> dict[str, Any]:
        """Analyze an SVG file path or raw XML string."""
        if isinstance(svg_source, Path) or (isinstance(svg_source, str) and os.path.exists(svg_source)):
            path = Path(svg_source)
            raw_svg = path.read_text(encoding="utf-8")
            file_name = source_name or path.name
        else:
            raw_svg = str(svg_source)
            file_name = source_name or "inline.svg"

        issues: list[dict[str, Any]] = []
        warnings: list[dict[str, Any]] = []

        try:
            root = ET.fromstring(raw_svg)
        except ET.ParseError as e:
            return {
                "file": file_name,
                "valid_xml": False,
                "error": f"Malformed XML: {e}",
                "issues": [{"type": "malformed_xml", "message": str(e)}],
                "warnings": [],
                "passed": False,
            }

        # 1. Parse viewBox, width, height
        vb_raw = root.attrib.get("viewBox")
        viewbox = parse_viewbox(vb_raw)
        width_val = parse_length(root.attrib.get("width"))
        height_val = parse_length(root.attrib.get("height"))

        # Effective canvas bounds [x_min, y_min, x_max, y_max]
        if viewbox:
            vb_min_x, vb_min_y, vb_w, vb_h = viewbox
            canvas_box = (vb_min_x, vb_min_y, vb_min_x + vb_w, vb_min_y + vb_h)
        elif width_val is not None and height_val is not None:
            canvas_box = (0.0, 0.0, width_val, height_val)
        else:
            canvas_box = None
            warnings.append({
                "type": "missing_dimensions",
                "message": "SVG specifies neither viewBox nor numeric width/height.",
            })

        # 2. Extract symbol definitions for <use> element resolution
        symbols: dict[str, str] = {}
        for sym in root.iter():
            tag = sym.tag.split("}")[-1]
            if tag == "symbol":
                sid = sym.attrib.get("id")
                for p in sym.iter():
                    ptag = p.tag.split("}")[-1]
                    if ptag == "path" and "d" in p.attrib:
                        symbols[sid] = p.attrib["d"]
                        break

        # 3. Traverse geometry to calculate tight bounding box
        bp = BoundsPen(None)
        elements_count = 0

        def traverse(elem: ET.Element, current_t: Transform) -> None:
            nonlocal elements_count
            tag = elem.tag.split("}")[-1]

            t = current_t
            if "transform" in elem.attrib:
                t = t.transform(parse_transform(elem.attrib["transform"]))

            # Skip background canvas rects (e.g. fill="#fff" with 100% dimensions matching root)
            if tag == "rect":
                w = parse_length(elem.attrib.get("width")) or 0.0
                h = parse_length(elem.attrib.get("height")) or 0.0
                x = parse_length(elem.attrib.get("x")) or 0.0
                y = parse_length(elem.attrib.get("y")) or 0.0
                fill = elem.attrib.get("fill", "").lower()
                stroke = elem.attrib.get("stroke", "none").lower()
                is_bg = (
                    stroke in ("none", "")
                    and fill in ("#fff", "#ffffff", "white", "#000", "#000000", "black")
                    and canvas_box
                    and abs(w - (canvas_box[2] - canvas_box[0])) < 1.0
                    and abs(h - (canvas_box[3] - canvas_box[1])) < 1.0
                )
                if not is_bg and (w > 0 or h > 0):
                    elements_count += 1
                    for pt in [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]:
                        bp.moveTo(t.transformPoint(pt))

            elif tag == "path" and "d" in elem.attrib:
                d_str = elem.attrib["d"].strip()
                if d_str:
                    elements_count += 1
                    try:
                        p = SVGPath.fromstring(f'<path d="{d_str}"/>')
                        p.draw(TransformPen(bp, t))
                    except (ValueError, KeyError, IndexError) as err:
                        logger.debug("Failed parsing path d attribute: %s", err)

            elif tag == "use":
                x = parse_length(elem.attrib.get("x")) or 0.0
                y = parse_length(elem.attrib.get("y")) or 0.0
                href = (
                    elem.attrib.get("{http://www.w3.org/1999/xlink}href")
                    or elem.attrib.get("href")
                    or ""
                )
                if href.startswith("#"):
                    sid = href[1:]
                    if sid in symbols:
                        elements_count += 1
                        use_t = t.translate(x, y)
                        try:
                            p = SVGPath.fromstring(f'<path d="{symbols[sid]}"/>')
                            p.draw(TransformPen(bp, use_t))
                        except (ValueError, KeyError, IndexError) as err:
                            logger.debug("Failed drawing symbol path: %s", err)
                    else:
                        issues.append({
                            "type": "unresolved_use_ref",
                            "message": f"<use> element references unknown symbol '{href}'",
                        })

            elif tag == "line":
                x1 = parse_length(elem.attrib.get("x1")) or 0.0
                y1 = parse_length(elem.attrib.get("y1")) or 0.0
                x2 = parse_length(elem.attrib.get("x2")) or 0.0
                y2 = parse_length(elem.attrib.get("y2")) or 0.0
                elements_count += 1
                bp.moveTo(t.transformPoint((x1, y1)))
                bp.lineTo(t.transformPoint((x2, y2)))

            elif tag == "circle":
                cx = parse_length(elem.attrib.get("cx")) or 0.0
                cy = parse_length(elem.attrib.get("cy")) or 0.0
                r = parse_length(elem.attrib.get("r")) or 0.0
                elements_count += 1
                for pt in [(cx - r, cy - r), (cx + r, cy + r)]:
                    bp.moveTo(t.transformPoint(pt))

            # Don't recurse into defs or symbol templates
            if tag in ("defs", "symbol"):
                return

            for child in elem:
                traverse(child, t)

        traverse(root, Transform())

        tight_bbox = bp.bounds  # (min_x, min_y, max_x, max_y) or None

        # 4. Check for bounding box overflow relative to viewBox / canvas
        overflow: dict[str, float] = {}
        tolerance = 0.5  # px margin of tolerance for antialiasing/rounding
        if canvas_box and tight_bbox:
            c_min_x, c_min_y, c_max_x, c_max_y = canvas_box
            b_min_x, b_min_y, b_max_x, b_max_y = tight_bbox

            if b_min_x < (c_min_x - tolerance):
                overflow["left"] = round(c_min_x - b_min_x, 3)
            if b_min_y < (c_min_y - tolerance):
                overflow["top"] = round(c_min_y - b_min_y, 3)
            if b_max_x > (c_max_x + tolerance):
                overflow["right"] = round(b_max_x - c_max_x, 3)
            if b_max_y > (c_max_y + tolerance):
                overflow["bottom"] = round(b_max_y - c_max_y, 3)

            if overflow:
                issues.append({
                    "type": "viewbox_overflow",
                    "message": f"Graphical content overflows viewBox/canvas: {overflow}",
                    "overflow": overflow,
                    "tight_bbox": [round(x, 2) for x in tight_bbox],
                    "canvas_box": [round(x, 2) for x in canvas_box],
                })

        # 5. Check text elements (empty text, unresolved font, un-pathified text)
        for elem in root.iter():
            tag = elem.tag.split("}")[-1]
            if tag == "text":
                text_content = (elem.text or "").strip()
                # Empty text check
                if not text_content and len(elem) == 0:
                    issues.append({
                        "type": "empty_text_element",
                        "message": "Empty <text></text> element detected.",
                        "element": ET.tostring(elem, encoding="unicode").strip(),
                    })
                    continue

                font_family = elem.attrib.get("font-family")
                if font_family:
                    clean_font = font_family.replace('"', '').replace("'", "")
                    if clean_font not in KNOWN_MATH_FONTS and clean_font not in self._font_cmap:
                        warnings.append({
                            "type": "unresolved_font_family",
                            "message": f"<text> element references unbundled font '{clean_font}'",
                            "font_family": clean_font,
                        })

                # In KOReader / MicroTeX pipeline, unpathified <text> on Kobo Libra 2 causes tofu
                warnings.append({
                    "type": "unpathified_text_element",
                    "message": "<text> element remaining in SVG (not rewritten to <path> outlines).",
                    "font_family": font_family,
                    "text": text_content,
                })

        # 6. Raw regex checks on original SVG text for numeric character references & operator codes
        for m in re.finditer(r'<text([^>]*)>(.*?)</text>', raw_svg, re.DOTALL):
            attrs, inner = m.groups()
            font_m = re.search(r'font-family="([^"]+)"', attrs)
            font_name = font_m.group(1) if font_m else ""
            cps = [int(c) for c in re.findall(r'&#(\d+);', inner)]
            for cp in cps:
                if cp in CRITICAL_OPERATOR_CODEPOINTS:
                    op_name = CRITICAL_OPERATOR_CODEPOINTS[cp]
                    if font_name and font_name in self._font_cmap and cp not in self._font_cmap[font_name]:
                        issues.append({
                            "type": "missing_operator_glyph",
                            "message": f"Critical operator {op_name} (cp {cp}) missing in font '{font_name}'",
                            "font": font_name,
                            "codepoint": cp,
                        })

        passed = len(issues) == 0

        return {
            "file": file_name,
            "valid_xml": True,
            "viewBox": viewbox,
            "width": width_val,
            "height": height_val,
            "canvas_box": [round(x, 2) for x in canvas_box] if canvas_box else None,
            "tight_bbox": [round(x, 2) for x in tight_bbox] if tight_bbox else None,
            "elements_count": elements_count,
            "overflow": overflow,
            "issues": issues,
            "warnings": warnings,
            "passed": passed,
        }


def main() -> int:
    ap = argparse.ArgumentParser(description="Static SVG analysis for bounding boxes and math glyph defects")
    ap.add_argument("svg", help="Path to SVG file or directory of SVGs to analyze")
    ap.add_argument("--json", "-j", action="store_true", help="Output results as JSON")
    ap.add_argument("--fonts-dir", default=DEFAULT_FONTS_DIR, help="Path to bundled fonts directory")
    ap.add_argument("--fail-on-warning", action="store_true", help="Exit with non-zero code on warnings")

    args = ap.parse_args()
    analyzer = SvgAnalyzer(fonts_dir=args.fonts_dir)

    target = Path(args.svg)
    results = []

    if target.is_file():
        results.append(analyzer.analyze(target))
    elif target.is_dir():
        svg_files = sorted(target.glob("**/*.svg"))
        if not svg_files:
            print(f"No SVG files found in {target}", file=sys.stderr)
            return 1
        for sf in svg_files:
            results.append(analyzer.analyze(sf))
    else:
        print(f"Error: {args.svg} not found", file=sys.stderr)
        return 1

    has_errors = any(not r.get("passed", False) for r in results)
    has_warnings = any(len(r.get("warnings", [])) > 0 for r in results)

    if args.json:
        print(json.dumps(results if len(results) > 1 else results[0], indent=2))
    else:
        for r in results:
            status = "\033[92mPASS\033[0m" if r["passed"] else "\033[91mFAIL\033[0m"
            print(f"[{status}] {r['file']}")
            if r.get("viewBox"):
                print(f"  viewBox: {r['viewBox']}")
            if r.get("tight_bbox"):
                print(f"  content bbox: {r['tight_bbox']}")
            if r.get("overflow"):
                print(f"  \033[91mOVERFLOW: {r['overflow']}\033[0m")
            for issue in r.get("issues", []):
                print(f"  - Issue [{issue['type']}]: {issue['message']}")
            for warn in r.get("warnings", []):
                print(f"  - Warning [{warn['type']}]: {warn['message']}")

    if has_errors:
        return 1
    if args.fail_on_warning and has_warnings:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
