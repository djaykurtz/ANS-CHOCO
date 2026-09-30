#!/usr/bin/env python3.12
"""Follow a playbook side log and report problems as they happen.

The run's terminal belongs to the operator (see chocoDeploy_QuickRef.md,
"Running with an assistant"). This reads only the side log that the run tees to,
so it never touches the live run. It prints:
  - UNREACHABLE and FAILED hosts immediately, with the task and the error message
  - a progress line every --interval seconds while output keeps arriving
  - a stall notice when the log goes quiet for --stall seconds
  - a summary from PLAY RECAP (failed/unreachable hosts, top error messages), then exits
Ignored failures (tasks marked "...ignoring") are counted, not reported as failures.

Examples:
  python3.12 playbooks/tools/watch_run.py /opt/ansible/LOGS/run-<ts>.log          # follow live
  python3.12 playbooks/tools/watch_run.py /opt/ansible/LOGS/run-<ts>.log --once   # summarize a finished log
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
RESULT = re.compile(r"^(ok|changed|failed|fatal): \[([^\]]+)\](.*)$")
RECAP = re.compile(r"^(\S+)\s+:\s+ok=(\d+)\s+changed=(\d+)\s+unreachable=(\d+)\s+failed=(\d+)"
                   r"(?:\s+skipped=(\d+))?(?:\s+rescued=(\d+))?(?:\s+ignored=(\d+))?")


def now() -> str:
    return datetime.now().strftime("%H:%M:%S")


class Watcher:
    def __init__(self, out=sys.stdout):
        self.out = out
        self.play = ""
        self.task = ""
        self.task_no = 0
        self.hosts: set[str] = set()
        self.counts = Counter()
        self.failed: dict[str, tuple[str, str]] = {}
        self.unreachable: dict[str, tuple[str, str]] = {}
        self.ignored = Counter()
        self.reasons = Counter()
        self.pending: dict | None = None
        self.in_recap = False
        self.recap: dict[str, dict[str, int]] = {}
        self.done = False

    def emit(self, text: str) -> None:
        print(f"[{now()}] {text}", file=self.out, flush=True)

    def feed(self, raw: str) -> None:
        line = ANSI.sub("", raw).rstrip("\r\n")
        if self.pending is not None:
            if line.startswith((" ", "\t")) and line.strip():
                self.pending["details"].append(line.strip())
                return
            ignored = line.strip() == "...ignoring"
            self.finish_pending(ignored)
            if ignored:
                return
        if self.in_recap:
            m = RECAP.match(line)
            if m:
                self.recap[m.group(1)] = {k: int(v or 0) for k, v in zip(
                    ("ok", "changed", "unreachable", "failed", "skipped", "rescued", "ignored"), m.groups()[1:])}
                return
            if not line.strip() and self.recap:
                self.in_recap = False
                self.summary()
                self.done = True
            return
        if line.startswith("PLAY RECAP"):
            self.in_recap = True
        elif line.startswith("PLAY ["):
            self.play = line[6:line.find("]")]
        elif line.startswith("TASK ["):
            self.task = line[6:line.rfind("]")]
            self.task_no += 1
        else:
            m = RESULT.match(line)
            if m:
                status, host, rest = m.groups()
                host = host.split(" -> ")[0]
                self.hosts.add(host)
                if status in ("ok", "changed"):
                    self.counts[status] += 1
                else:
                    kind = "UNREACHABLE" if "UNREACHABLE!" in rest else "FAILED"
                    item = re.search(r"\(item=(.*?)\)", rest)
                    self.pending = {"host": host, "kind": kind, "task": self.task,
                                    "item": item.group(1) if item else None, "details": []}

    def finish_pending(self, ignored: bool) -> None:
        p, self.pending = self.pending, None
        details = p["details"]
        idx = next((i for i, d in enumerate(details) if d.startswith("msg:")), None)
        msg = details[idx].split(":", 1)[1].strip().strip("'\"") if idx is not None else ""
        if msg in ("|", "|-", ">", ">-") and idx + 1 < len(details):
            msg = details[idx + 1]
        rc = next((d.split(":", 1)[1].strip() for d in p["details"] if d.startswith("rc:")), None)
        reason = (msg or "(no msg)")[:160]
        where = p["task"] + (f" [item={p['item']}]" if p["item"] else "")
        if ignored:
            self.ignored[p["task"]] += 1
            return
        rc_txt = f" rc={rc}" if rc and rc != "0" else ""
        # Only the first problem per host: later ones (e.g. chocoDeploy's re-raise
        # after writing its report) repeat the same root cause.
        if p["host"] in self.unreachable or p["host"] in self.failed:
            return
        self.reasons[reason[:90]] += 1
        if p["kind"] == "UNREACHABLE":
            self.unreachable[p["host"]] = (where, reason)
            self.emit(f"UNREACHABLE {p['host']} @ {where}: {reason}")
        else:
            self.failed[p["host"]] = (where, reason)
            self.emit(f"FAILED {p['host']} @ {where}{rc_txt}: {reason}")

    def progress(self) -> None:
        ign = sum(self.ignored.values())
        self.emit(f"progress: task {self.task_no} \"{self.task}\" | hosts seen {len(self.hosts)} | "
                  f"ok {self.counts['ok']} changed {self.counts['changed']} | failed hosts {len(self.failed)} | "
                  f"unreachable {len(self.unreachable)} | ignored failures {ign}")

    def summary(self) -> None:
        total = len(self.recap)
        failed = sorted(h for h, r in self.recap.items() if r["failed"])
        unreach = sorted(h for h, r in self.recap.items() if r["unreachable"])
        changed = sum(1 for r in self.recap.values() if r["changed"])
        clean = total - len(set(failed) | set(unreach))
        self.emit(f"RECAP: {total} hosts | {clean} without failures ({changed} with changes) | "
                  f"{len(failed)} failed | {len(unreach)} unreachable")
        for h in failed:
            where, reason = self.failed.get(h, ("?", "?"))
            self.emit(f"  failed      {h} @ {where}: {reason}")
        for h in unreach:
            where, reason = self.unreachable.get(h, ("?", "?"))
            self.emit(f"  unreachable {h} @ {where}: {reason}")
        if self.reasons:
            self.emit("  top errors: " + "; ".join(f"{n}x {r}" for r, n in self.reasons.most_common(5)))
        if self.ignored:
            self.emit("  ignored failures: " + "; ".join(f"{n}x {t}" for t, n in self.ignored.most_common(5)))


def follow(path: Path, w: Watcher, interval: float, stall: float, once: bool) -> int:
    while not path.exists():
        if once:
            print(f"not found: {path}", file=sys.stderr)
            return 2
        time.sleep(1)
    with path.open(encoding="utf-8", errors="replace") as handle:
        buf, last_data, last_progress, stalled = "", time.time(), time.time(), False
        while not w.done:
            chunk = handle.readline()
            if chunk:
                buf += chunk
                if buf.endswith("\n"):
                    w.feed(buf)
                    buf = ""
                last_data, stalled = time.time(), False
                continue
            if once:
                if buf:
                    w.feed(buf)
                if w.pending is not None:
                    w.finish_pending(False)
                if not w.done:
                    w.progress()
                    w.emit("log ended without PLAY RECAP (run interrupted or still going)")
                return 0
            t = time.time()
            if t - last_progress >= interval and t - last_data < interval and w.task_no:
                w.progress()
                last_progress = t
            if not stalled and t - last_data >= stall:
                w.emit(f"no new output for {int(t - last_data)}s; last task \"{w.task}\" "
                       f"(a host may be hanging, or the run is waiting)")
                stalled = True
            time.sleep(1)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", type=Path, help="side log the run tees to")
    parser.add_argument("--interval", type=float, default=60, help="seconds between progress lines")
    parser.add_argument("--stall", type=float, default=300, help="seconds of silence before a stall notice")
    parser.add_argument("--once", action="store_true", help="read the file once and summarize, do not follow")
    args = parser.parse_args()
    try:
        return follow(args.log, Watcher(), args.interval, args.stall, args.once)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
