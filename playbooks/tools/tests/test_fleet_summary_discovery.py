#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[2] / "roles" / "chocoDeploy" / "files" / "fleet_summary.py"
spec = importlib.util.spec_from_file_location("fleet_summary", SCRIPT)
fleet_summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet_summary)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for rel in (
            "20260101T000000Z_h1.example_chocoDeploy.json",            # top-level report
            "copies/20260101T000000Z_h1.example_chocoDeploy.json",     # evidence copy
            "campaign/h2.example/20260101T000000Z_chocoDeploy.json",   # nested too deep
            "h3.example/20260101T000000Z_chocoDeploy.json",            # collector layout
            "reports/20260101T000000Z_chocoDeploy_fleet_summary.json",  # summary output
        ):
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}")

    def tearDown(self):
        self.temp.cleanup()

    def test_only_top_level_reports_and_collector_host_dirs(self):
        found = fleet_summary.discover_jsons(str(self.root))
        self.assertEqual(sorted(f["hostname"] for f in found), ["h1.example", "h3.example"])

    def test_missing_directory_finds_nothing(self):
        self.assertEqual(fleet_summary.discover_jsons(str(self.root / "missing")), [])


if __name__ == "__main__":
    unittest.main()
