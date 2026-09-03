#!/usr/bin/env python3
"""Automated rasterisation and SVG storage pipeline for MicroTeX math SVGs.

Converts SVGs produced from LaTeX math formulas into high-resolution PNGs
(2x-4x intended display scale) using rsvg-convert, cairosvg, or chromium.
Optionally produces a debug PNG with a colored background or border for clipping inspection.
Stores the original SVG, rendered PNG(s), and source LaTeX snippet with metadata.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


def rasterize_rsvg(
    svg_path: Path,
    png_path: Path,
    zoom: float = 2.0,
    background_color: str | None = None,
) -> bool:
    """Rasterize SVG to PNG using rsvg-convert."""
    cmd = ["rsvg-convert", "-z", str(zoom), "-f", "png", "-o", str(png_path)]
    if background_color:
        cmd.extend(["-b", background_color])
    cmd.append(str(svg_path))

    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return res.returncode == 0


def rasterize_cairosvg(
    svg_path: Path,
    png_path: Path,
    zoom: float = 2.0,
    background_color: str | None = None,
) -> bool:
    """Rasterize SVG to PNG using cairosvg."""
    try:
        import cairosvg  # type: ignore

        cairosvg.svg2png(
            url=str(svg_path),
            write_to=str(png_path),
            scale=zoom,
            background_color=background_color,
        )
        return True
    except (ImportError, OSError, ValueError) as exc:
        logger.debug("cairosvg failed: %s", exc)
        return False


def rasterize_chromium(
    svg_path: Path,
    png_path: Path,
    zoom: float = 2.0,
    background_color: str | None = None,
) -> bool:
    """Rasterize SVG to PNG using headless chromium."""
    chromium = shutil.which("chromium") or shutil.which("google-chrome")
    if not chromium:
        return False
    bg_style = f"background: {background_color};" if background_color else ""
    html_content = f"""<!DOCTYPE html>
<html>
<body style="margin:0; padding:0; {bg_style}">
<img src="{svg_path.resolve().as_uri()}" style="transform: scale({zoom}); transform-origin: top left; display: block;"/>
</body>
</html>"""
    temp_html = png_path.with_suffix(".temp.html")
    try:
        temp_html.write_text(html_content, encoding="utf-8")
        bg_opt = (
            "--default-background-color=00000000"
            if not background_color
            else f"--default-background-color={background_color.lstrip('#')}"
        )
        cmd = [
            chromium,
            "--headless",
            "--disable-gpu",
            bg_opt,
            f"--screenshot={png_path}",
            str(temp_html.resolve().as_uri()),
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        return res.returncode == 0
    finally:
        if temp_html.exists():
            temp_html.unlink()


def rasterize_svg(
    svg_path: Path,
    png_path: Path,
    zoom: float = 2.0,
    background_color: str | None = None,
) -> bool:
    """Try available rasterizers in order: rsvg-convert, cairosvg, chromium."""
    if shutil.which("rsvg-convert") and rasterize_rsvg(svg_path, png_path, zoom, background_color):
        return True
    if rasterize_cairosvg(svg_path, png_path, zoom, background_color):
        return True
    return rasterize_chromium(svg_path, png_path, zoom, background_color)


def process_math_entry(
    svg_source: str | Path,
    output_dir: str | Path,
    latex: str = "",
    name: str = "formula",
    zoom: float = 2.0,
    clipping_bg: str = "#ff007f",
    generate_clipping_png: bool = True,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Process a single formula SVG:
    - Store the SVG file
    - Generate high-res PNG (at zoom scale, default 2x)
    - Generate clipping detection PNG (with colored background)
    - Store latex source and metadata manifest
    """
    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    dest_svg = out_dir / f"{name}.svg"
    if isinstance(svg_source, Path) or (isinstance(svg_source, str) and os.path.exists(svg_source)):
        shutil.copyfile(str(svg_source), str(dest_svg))
        dest_svg.read_text(encoding="utf-8")
    else:
        svg_content = str(svg_source)
        dest_svg.write_text(svg_content, encoding="utf-8")

    dest_latex = out_dir / f"{name}.tex"
    if latex:
        dest_latex.write_text(latex, encoding="utf-8")

    # Rasterize 1: standard high-res PNG (2x-4x)
    dest_png = out_dir / f"{name}.png"
    ok_png = rasterize_svg(dest_svg, dest_png, zoom=zoom)

    # Rasterize 2: clipping inspection PNG with colored background
    dest_clipping_png = out_dir / f"{name}_clipping.png"
    ok_clip = False
    if generate_clipping_png:
        ok_clip = rasterize_svg(dest_svg, dest_clipping_png, zoom=zoom, background_color=clipping_bg)

    manifest_data = {
        "name": name,
        "latex": latex,
        "zoom": zoom,
        "svg": dest_svg.name,
        "png": dest_png.name if ok_png else None,
        "clipping_png": dest_clipping_png.name if ok_clip else None,
        "extra": metadata or {},
    }

    manifest_path = out_dir / f"{name}_meta.json"
    manifest_path.write_text(json.dumps(manifest_data, indent=2), encoding="utf-8")

    return {
        "svg_path": str(dest_svg),
        "png_path": str(dest_png) if ok_png else None,
        "clipping_png_path": str(dest_clipping_png) if ok_clip else None,
        "latex_path": str(dest_latex) if latex else None,
        "manifest_path": str(manifest_path),
        "manifest": manifest_data,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Rasterize Math SVGs and store with LaTeX snippets")
    ap.add_argument("svg", help="Input SVG file or directory of SVGs")
    ap.add_argument("--out-dir", "-o", default="build/rasterized", help="Output directory")
    ap.add_argument("--latex", "-l", default="", help="LaTeX math expression source")
    ap.add_argument("--name", "-n", default=None, help="Base name for output files")
    ap.add_argument("--zoom", "-z", type=float, default=2.0, help="Zoom factor for high-resolution PNG (default 2.0)")
    ap.add_argument("--clipping-bg", default="#ff007f", help="Background color for clipping visualization PNG")
    ap.add_argument("--no-clipping-png", action="store_true", help="Skip generating clipping inspection PNG")

    args = ap.parse_args()

    svg_target = Path(args.svg)
    if svg_target.is_file():
        name = args.name or svg_target.stem
        res = process_math_entry(
            svg_source=svg_target,
            output_dir=args.out_dir,
            latex=args.latex,
            name=name,
            zoom=args.zoom,
            clipping_bg=args.clipping_bg,
            generate_clipping_png=not args.no_clipping_png,
        )
        print(f"Saved: {res['svg_path']}")
        if res["png_path"]:
            print(f"Rasterized: {res['png_path']}")
        if res["clipping_png_path"]:
            print(f"Clipping view: {res['clipping_png_path']}")
        return 0

    if svg_target.is_dir():
        svg_files = sorted(svg_target.glob("*.svg"))
        if not svg_files:
            print(f"No SVG files found in {svg_target}", file=sys.stderr)
            return 1
        print(f"Processing {len(svg_files)} SVGs in {svg_target}...")
        for sf in svg_files:
            process_math_entry(
                svg_source=sf,
                output_dir=args.out_dir,
                name=sf.stem,
                zoom=args.zoom,
                clipping_bg=args.clipping_bg,
                generate_clipping_png=not args.no_clipping_png,
            )
        print(f"Done. Outputs stored in {args.out_dir}")
        return 0

    print(f"Error: path {args.svg} does not exist", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
