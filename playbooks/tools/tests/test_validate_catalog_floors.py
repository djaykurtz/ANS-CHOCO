#!/usr/bin/env python3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import validate_catalog


class FloorAlignmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        tasks = Path(self.temp.name)
        (tasks / "apps").mkdir()
        (tasks / "apps" / "7zip.install.yml").write_text(
            "version: \"{{ acceptable_versions.applications.sevenzip_install.min_version }}\"\n")
        self._saved = validate_catalog.DEPLOY_TASKS
        validate_catalog.DEPLOY_TASKS = tasks
        self.deploy = {"acceptable_versions": {
            "applications": {"sevenzip_install": {"min_version": "26.2.0"}},
            "runtimes": {"python": {"channels": {"3.12": {"min_version": "3.12.10"}}},
                         "powershell_core": {"min_version": "7.6.6"}}}}
        self.apps = {"7zip.install": {"key": "7zip.install", "task_file": "apps/7zip.install.yml"}}

    def tearDown(self):
        validate_catalog.DEPLOY_TASKS = self._saved
        self.temp.cleanup()

    def check(self, **approved):
        catalog = {"packages": {
            "7zip.install": {"kind": "application", "approved_version": approved.get("app", "26.2.0")},
            "python-3.12": {"kind": "runtime", "runtime_id": "python", "track": "3.12",
                            "approved_version": approved.get("py", "3.12.10")},
            "powershell-core": {"kind": "runtime", "runtime_id": "powershell_core",
                                "approved_version": approved.get("pwsh", "7.6.6")},
        }}
        v = validate_catalog.Validator()
        validate_catalog.check_floor_alignment(v, catalog, self.deploy, self.apps)
        return v.errors

    def test_aligned_catalog_passes(self):
        self.assertEqual(self.check(), [])

    def test_app_floor_drift_is_an_error(self):
        errors = self.check(app="26.3.0")
        self.assertEqual(len(errors), 1)
        self.assertIn("applications.sevenzip_install = 26.2.0", errors[0])

    def test_runtime_channel_and_single_track_drift_are_errors(self):
        self.assertEqual(len(self.check(py="3.12.11", pwsh="7.6.7")), 2)


if __name__ == "__main__":
    unittest.main()
