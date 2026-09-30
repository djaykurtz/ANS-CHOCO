#!/usr/bin/env python3
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import lint_target_scope


POLICY = Path(__file__).parents[2] / "policies" / "target_exclusions.yml"
CLOUDSYNC = "OU=Restricted,OU=Services,OU=Lab,OU=CloudSync,OU=Managed,DC=corp,DC=example,DC=com"
LOCALONLY = "OU=Restricted,OU=Services,OU=Lab,OU=LocalOnly,OU=Managed,DC=corp,DC=example,DC=com"


class TargetScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.export = root / "ad-objects.json"
        self.export.write_text(json.dumps([
            {"cn": "cloudsync-host", "distinguishedName": f"CN=cloudsync-host,{CLOUDSYNC}"},
            {"cn": "localonly-host", "distinguishedName": f"CN=localonly-host,OU=Child,{LOCALONLY}"},
        ]), encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def lint(self, *hosts):
        return lint_target_scope.lint_hosts([("test", list(hosts))], self.export, POLICY)

    def test_both_protected_ous_are_blocked(self):
        result = self.lint("cloudsync-host.corp.example.com", "localonly-host")
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual({item["matching_ou"] for item in result["protected_hosts"]}, {
            "restricted-cloudsync", "restricted-localonly"
        })

    def test_outside_host_is_allowed(self):
        result = self.lint("ordinary-host")
        self.assertEqual(result["status"], "PASS")

    def test_missing_evidence_fails_closed(self):
        with self.assertRaises(lint_target_scope.ScopeError):
            lint_target_scope.lint_hosts([("test", ["ordinary-host"])],
                                         Path(self.temp.name) / "missing.json", POLICY)


if __name__ == "__main__":
    unittest.main()