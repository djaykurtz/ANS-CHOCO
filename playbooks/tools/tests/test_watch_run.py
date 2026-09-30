#!/usr/bin/env python3
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import watch_run

LOG = """\
PLAY [Chocolatey deployment] ***
TASK [Gathering Facts] ***
\x1b[0;31mfatal: [h1.example]: UNREACHABLE! => changed=false\x1b[0m
  msg: 'ntlm: connection refused'
  unreachable: true
ok: [h2.example]
ok: [h3.example]
TASK [role : Install thing] ***
fatal: [h2.example]: FAILED! => changed=false
  msg: 'Bad HTTP response returned from server. Code 400'
...ignoring
fatal: [h3.example]: FAILED! => changed=false
  msg: |-
    install failed: exit code 1603
  rc: 1603
changed: [h2.example]
TASK [role : Re-raise fatal error after report] ***
fatal: [h3.example]: FAILED! => changed=false
  msg: install failed again
PLAY RECAP ***
h1.example : ok=0    changed=0    unreachable=1    failed=0    skipped=0    rescued=0    ignored=0
h2.example : ok=2    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=1
h3.example : ok=1    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0

"""


class WatchRunTests(unittest.TestCase):
    def run_log(self):
        out = io.StringIO()
        w = watch_run.Watcher(out=out)
        for line in LOG.splitlines(keepends=True):
            w.feed(line)
        return w, out.getvalue()

    def test_reports_unreachable_and_first_failure_only(self):
        w, text = self.run_log()
        self.assertIn("UNREACHABLE h1.example @ Gathering Facts: ntlm: connection refused", text)
        self.assertIn("FAILED h3.example @ role : Install thing rc=1603: install failed: exit code 1603", text)
        self.assertNotIn("install failed again", text)
        self.assertEqual(text.count("FAILED h3.example"), 1)

    def test_ignored_failures_are_counted_not_reported(self):
        w, text = self.run_log()
        self.assertNotIn("FAILED h2.example", text)
        self.assertEqual(w.ignored["role : Install thing"], 1)

    def test_recap_summary_and_done(self):
        w, text = self.run_log()
        self.assertTrue(w.done)
        self.assertIn("RECAP: 3 hosts | 1 without failures (1 with changes) | 1 failed | 1 unreachable", text)


if __name__ == "__main__":
    unittest.main()
