#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

TOOL = Path(__file__).parents[1] / "csv_to_inventory.py"
CLOUDSYNC = "OU=Restricted,OU=Services,OU=Lab,OU=CloudSync,OU=Managed,DC=corp,DC=example,DC=com"
LOCALONLY = "OU=Restricted,OU=Services,OU=Lab,OU=LocalOnly,OU=Managed,DC=corp,DC=example,DC=com"
OTHER = "OU=Servers,OU=Managed,DC=corp,DC=example,DC=com"


class CsvToInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.export = self.root / "ad.json"
        self.export.write_text(json.dumps([
            {"cn": "cloudsync-host", "distinguishedName": f"CN=cloudsync-host,{CLOUDSYNC}"},
            {"cn": "localonly-host", "distinguishedName": f"CN=localonly-host,OU=Child,{LOCALONLY}"},
            {"cn": "plain-host", "distinguishedName": f"CN=plain-host,{OTHER}"},
        ]), encoding="utf-8")
        self.csv = self.root / "hosts.csv"
        self.csv.write_text(
            "DeviceName,SoftwareName\n"
            "plain-host,git\nplain-host,vim\ncloudsync-host,git\n"
            "LOCALONLY-HOST.corp.example.com,git\nunknown-host,git\n",
            encoding="utf-8")
        self.out = self.root / "out"

    def tearDown(self):
        self.temp.cleanup()

    def run_tool(self, *extra, export=None):
        return subprocess.run(
            [sys.executable, str(TOOL), str(self.csv), "--campaign-id", "t1", "--no-probe",
             "--ad-export", str(export or self.export), "--outdir", str(self.out), *extra],
            capture_output=True, text=True)

    def inventory_hosts(self):
        data = yaml.safe_load((self.out / "inv-t1-all.yml").read_text())
        return set(data["all"]["children"]["basic_hosts"]["hosts"] or {})

    def test_protected_hosts_are_excluded_and_reported(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.inventory_hosts(), {
            "plain-host.corp.example.com",
            "unknown-host.corp.example.com",
        })
        self.assertIn("WARN excluded cloudsync-host", result.stdout)
        excluded = (self.out / "t1-all-excluded.txt").read_text()
        self.assertIn("restricted-cloudsync", excluded)
        self.assertIn("restricted-localonly", excluded)

    def test_report_records_ad_location_and_group_vars(self):
        self.run_tool()
        report = json.loads((self.out / "t1-all-check.json").read_text())
        self.assertEqual(report["counts"]["hosts"], 4)
        self.assertEqual(report["counts"]["not_in_ad_export"], 1)
        self.assertEqual(report["hosts"]["plain-host.corp.example.com"]["distinguishedName"],
                         f"CN=plain-host,{OTHER}")
        self.assertTrue((self.out / "group_vars" / "basic_hosts.yml").is_file())

    def test_missing_evidence_creates_nothing(self):
        result = self.run_tool(export=self.root / "missing.json")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.out.exists())

    def test_existing_inventory_is_not_overwritten(self):
        self.assertEqual(self.run_tool().returncode, 0)
        self.assertEqual(self.run_tool().returncode, 2)
        self.assertEqual(self.run_tool("--force").returncode, 0)


if __name__ == "__main__":
    unittest.main()
