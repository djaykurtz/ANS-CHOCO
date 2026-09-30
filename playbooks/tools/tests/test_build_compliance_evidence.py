import csv
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import build_compliance_evidence


class ComplianceInventoryTests(unittest.TestCase):
    def test_generic_inventory_accepts_fqdns_and_short_hosts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inventory.yml"
            path.write_text(
                "all:\n  children:\n    basic_hosts:\n      hosts:\n"
                "        lab-01.corp.example.com:\n"
                "        LAB-02.other.example:\n"
                "        lab-03: {}\n", encoding="utf-8")
            self.assertEqual(build_compliance_evidence.inventory_hosts(path), [
                "lab-01.corp.example.com", "LAB-02.other.example", "lab-03",
            ])

    def test_empty_inventory_is_explicit_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inventory.yml"
            path.write_text("all:\n  children: {}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "inventory has no hosts"):
                build_compliance_evidence.inventory_hosts(path)

    def test_host_key_is_case_insensitive_and_domain_independent(self):
        self.assertEqual(build_compliance_evidence.short("LAB-01.corp.example.com"), "lab-01")
        self.assertEqual(build_compliance_evidence.short("LAB-01"), "lab-01")

    def test_csv_fqdn_and_short_name_deduplicate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "requirements.csv"
            with path.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=[
                    "DeviceName", "SoftwareName", "CurrentSoftwareVersion",
                ])
                writer.writeheader()
                for host in ("LAB-01.corp.example.com", "lab-01"):
                    writer.writerow({
                        "DeviceName": host, "SoftwareName": "vim",
                        "CurrentSoftwareVersion": "9.2.0",
                    })
            self.assertEqual(len(build_compliance_evidence.load_requirements([path])), 1)
