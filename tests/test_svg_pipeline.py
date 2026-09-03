#!/usr/bin/env python3
"""Unit tests for SVG rasterisation (Task 3) and Static SVG Analysis (Task 4)."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from tools.analyze_svg import SvgAnalyzer
from tools.rasterize_math_svg import process_math_entry, rasterize_svg


class TestSvgRasterization(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp(prefix="kobo_test_raster_")
        self.sample_svg = Path(self.temp_dir) / "test.svg"
        self.sample_svg.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">'
            '<rect x="10" y="10" width="80" height="30" fill="#000"/>'
            '</svg>',
            encoding="utf-8",
        )

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_rasterize_svg_creates_png(self):
        png_out = Path(self.temp_dir) / "test.png"
        ok = rasterize_svg(self.sample_svg, png_out, zoom=2.0)
        self.assertTrue(ok)
        self.assertTrue(png_out.exists())
        self.assertGreater(png_out.stat().st_size, 0)

    def test_process_math_entry_pipeline(self):
        latex = r"\sum_{i=1}^n x_i"
        res = process_math_entry(
            svg_source=self.sample_svg,
            output_dir=self.temp_dir,
            latex=latex,
            name="test_formula",
            zoom=2.0,
            generate_clipping_png=True,
        )
        self.assertTrue(Path(res["svg_path"]).exists())
        self.assertTrue(Path(res["png_path"]).exists())
        self.assertTrue(Path(res["clipping_png_path"]).exists())
        self.assertTrue(Path(res["latex_path"]).exists())
        self.assertEqual(Path(res["latex_path"]).read_text(encoding="utf-8"), latex)

        manifest = json.loads(Path(res["manifest_path"]).read_text(encoding="utf-8"))
        self.assertEqual(manifest["name"], "test_formula")
        self.assertEqual(manifest["latex"], latex)
        self.assertEqual(manifest["zoom"], 2.0)
        self.assertEqual(manifest["svg"], "test_formula.svg")
        self.assertEqual(manifest["png"], "test_formula.png")
        self.assertEqual(manifest["clipping_png"], "test_formula_clipping.png")


class TestStaticSvgAnalysis(unittest.TestCase):
    def setUp(self):
        self.analyzer = SvgAnalyzer()

    def test_valid_svg_within_bounds_passes(self):
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50" width="100" height="50">'
            '<rect x="10" y="5" width="80" height="35" fill="black"/>'
            '</svg>'
        )
        res = self.analyzer.analyze(svg)
        self.assertTrue(res["valid_xml"])
        self.assertTrue(res["passed"])
        self.assertEqual(len(res["issues"]), 0)
        self.assertEqual(res["overflow"], {})
        self.assertEqual(res["viewBox"], (0.0, 0.0, 100.0, 50.0))

    def test_overflow_detection(self):
        # Path extends to x=120, y=60 when viewBox max is (100, 50)
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50">'
            '<path d="M10 10 L120 60"/>'
            '</svg>'
        )
        res = self.analyzer.analyze(svg)
        self.assertFalse(res["passed"])
        issue_types = [i["type"] for i in res["issues"]]
        self.assertIn("viewbox_overflow", issue_types)
        self.assertGreater(res["overflow"].get("right", 0), 15.0)
        self.assertGreater(res["overflow"].get("bottom", 0), 5.0)

    def test_empty_text_element_detection(self):
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50">'
            '<text x="10" y="20"></text>'
            '</svg>'
        )
        res = self.analyzer.analyze(svg)
        self.assertFalse(res["passed"])
        issue_types = [i["type"] for i in res["issues"]]
        self.assertIn("empty_text_element", issue_types)

    def test_missing_operator_glyph_detection(self):
        # cmr10 does not have unicode summation \u2211
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50">'
            '<text font-family="cmr10">&#8721;</text>'
            '</svg>'
        )
        res = self.analyzer.analyze(svg)
        issue_types = [i["type"] for i in res["issues"]]
        self.assertIn("missing_operator_glyph", issue_types)

    def test_unresolved_use_reference(self):
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 50">'
            '<use xlink:href="#missing_glyph" x="10" y="10"/>'
            '</svg>'
        )
        res = self.analyzer.analyze(svg)
        self.assertFalse(res["passed"])
        issue_types = [i["type"] for i in res["issues"]]
        self.assertIn("unresolved_use_ref", issue_types)

    def test_pathified_svg_sample_passes(self):
        sample_path = Path("plugins/markdownreader.koplugin/microtex/readme/samples/sample_0.svg")
        if sample_path.exists():
            res = self.analyzer.analyze(sample_path)
            self.assertTrue(res["valid_xml"])
            self.assertTrue(res["passed"])


if __name__ == "__main__":
    unittest.main()

class TestAgentDebuggingLoop(unittest.TestCase):
    def test_corpus_pipeline_and_packet_generation(self):
        from tools.math_debug_loop import run_corpus_pipeline, build_agent_debugging_packet
        temp_dir = tempfile.mkdtemp(prefix="kobo_test_debug_loop_")
        try:
            corpus_path = Path("tests/fixtures/math_regression_corpus.json")
            reports = run_corpus_pipeline(str(corpus_path), temp_dir)
            self.assertEqual(len(reports), 6)
            report_file = Path(temp_dir) / "debug_report.json"
            self.assertTrue(report_file.exists())
            first = reports[0]
            self.assertIn("snippet_id", first)
            self.assertIn("agent_prompt", first)
            self.assertIn("Visual Math Debugging Request", first["agent_prompt"])
            self.assertIn("analysis", first)
            self.assertIn("automated_remediations", first)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)
