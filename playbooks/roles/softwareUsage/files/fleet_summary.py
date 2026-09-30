#!/usr/bin/env python3.12
"""
softwareUsage fleet summary.

Reads per-host JSON files written by playbooks/roles/softwareUsage and
produces a single fleet HTML report plus a structured JSON. Mirrors the
shape of chocoDeploy's fleet_summary.py but answers a different question:

  "Across the fleet, which catalog apps are actually being USED, and on
   which hosts?"

The answer is per-app:
  - hosts_used         : hosts where verdict == used_recently
  - hosts_unused       : hosts where verdict == unused_in_window
  - hosts_audit_off    : hosts where 4688 auditing is disabled
  - total_executions   : summed executions across all hosts
  - distinct_users     : (per-host, summed -- not deduplicated across the fleet)

Usage
-----
    python3.12 playbooks/roles/softwareUsage/files/fleet_summary.py --last-hours 24
    python3.12 playbooks/roles/softwareUsage/files/fleet_summary.py --today
    python3.12 playbooks/roles/softwareUsage/files/fleet_summary.py \\
        --since 20260601T010000Z --until 20260601T230000Z
    python3.12 playbooks/roles/softwareUsage/files/fleet_summary.py --archive

Flags
-----
    --log-dir DIR         (default $CHOCO_FLEET_DATA_ROOT/LOGS/softwareUsage; root defaults to /opt/ansible)
    --today | --last-hours N | --since TS --until TS
    --short-names         strip domain suffix from hostnames in output
    --archive             zip consumed per-host JSONs into archive/ subdir
    --retain-days N       prune archive zips older than N (default 90)
    --no-html             skip HTML rendering
    --no-json             skip JSON rendering
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import zipfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

DEFAULT_LOG_DIR = Path(os.environ.get("CHOCO_FLEET_DATA_ROOT") or "/opt/ansible") / "LOGS" / "softwareUsage"

FILE_RE = re.compile(
    r"^(?P<ts>\d{8}T\d{6}Z)_(?P<host>[^/]+)_softwareUsage\.json$"
)


def parse_ts(ts: str) -> datetime:
    return datetime.strptime(ts, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)


def short(host: str) -> str:
    return host.split(".", 1)[0]


def collect(log_dir: Path, since: datetime, until: datetime) -> list[dict[str, Any]]:
    out = []
    if not log_dir.is_dir():
        return out
    for p in sorted(log_dir.glob("*_softwareUsage.json")):
        m = FILE_RE.match(p.name)
        if not m:
            continue
        ts = parse_ts(m.group("ts"))
        if ts < since or ts > until:
            continue
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"[!] skip {p.name}: {e}", file=sys.stderr)
            continue
        data["_file"] = str(p)
        data["_file_ts"] = ts.isoformat()
        out.append(data)
    return out


def last_run_wins(records: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """When a host appears multiple times in the window, keep only the most
    recent record. Same dedup model as chocoDeploy fleet_summary."""
    best: dict[str, dict[str, Any]] = {}
    for r in records:
        h = r.get("host") or "(unknown)"
        cur = best.get(h)
        if cur is None or r["_file_ts"] > cur["_file_ts"]:
            best[h] = r
    return best


def aggregate(records_by_host: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Build the fleet-wide per-app rollup."""
    apps: dict[str, dict[str, Any]] = {}
    audit_off_hosts: list[str] = []
    cmdline_off_hosts: list[str] = []

    for host, rec in records_by_host.items():
        if not rec.get("audit_on", False):
            audit_off_hosts.append(host)
        if rec.get("audit_on") and not rec.get("cmdline_capture"):
            cmdline_off_hosts.append(host)

        for key, app in (rec.get("apps") or {}).items():
            a = apps.setdefault(key, {
                "label":             app.get("label", key),
                "hosts_used":        [],
                "hosts_unused":      [],
                "hosts_audit_off":   [],
                "total_executions":  0,
                "total_users":       0,
                "last_seen":         None,
            })
            v = app.get("verdict")
            if v == "used_recently":
                a["hosts_used"].append(host)
            elif v == "unused_in_window":
                a["hosts_unused"].append(host)
            elif v == "audit_off":
                a["hosts_audit_off"].append(host)

            a["total_executions"] += int(app.get("executions") or 0)
            a["total_users"]      += int(app.get("distinct_users") or 0)
            last = app.get("last")
            if last and (a["last_seen"] is None or last > a["last_seen"]):
                a["last_seen"] = last

    # sort host lists for stable output
    for a in apps.values():
        a["hosts_used"].sort()
        a["hosts_unused"].sort()
        a["hosts_audit_off"].sort()

    return {
        "apps":              apps,
        "audit_off_hosts":   sorted(audit_off_hosts),
        "cmdline_off_hosts": sorted(cmdline_off_hosts),
        "host_count":        len(records_by_host),
    }


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

HTML_HEAD = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>softwareUsage -- fleet summary</title>
<style>
* { margin:0; padding:0; box-sizing:border-box; }
body { font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif; background:#1e1e1e; color:#d4d4d4; line-height:1.55; font-size:15px; padding:1.5rem; }
.wrap { max-width:1400px; margin:0 auto; }
header { background:#0078d4; color:#fff; padding:0.85rem 1.5rem; border-radius:8px 8px 0 0; }
header h1 { font-size:1.3rem; font-weight:600; }
.meta { margin-top:0.3rem; font-size:0.9rem; opacity:0.9; }
.meta span { display:inline-block; margin-right:1.6rem; }
.stats { display:flex; flex-wrap:wrap; gap:0.6rem; padding:1rem 1.5rem; background:#252526; border-bottom:1px solid #3c3c3c; justify-content:center; }
.stat { text-align:center; padding:0.55rem 1.1rem; border-radius:6px; min-width:150px; }
.stat .count { font-size:1.7rem; font-weight:700; }
.stat .label { font-size:0.74rem; text-transform:uppercase; letter-spacing:0.05em; }
.stat-hosts    { background:#1a2733; color:#569cd6; }
.stat-used     { background:#1a2e1a; color:#6a9955; }
.stat-unused   { background:#332b1a; color:#ce9178; }
.stat-auditoff { background:#3a1a1a; color:#f48771; }
section { background:#252526; padding:0.85rem 1.5rem; border-bottom:1px solid #3c3c3c; }
section:last-of-type { border-radius:0 0 8px 8px; border-bottom:none; }
h2 { font-size:1.1rem; margin-bottom:0.5rem; color:#e0e0e0; }
table { width:100%; border-collapse:collapse; font-size:0.95rem; margin-top:0.25rem; }
th { text-align:left; padding:0.45rem 0.65rem; background:#2d2d2d; border-bottom:2px solid #3c3c3c; font-weight:600; color:#569cd6; }
td { padding:0.4rem 0.65rem; border-bottom:1px solid #333; color:#d4d4d4; vertical-align:top; }
tr:nth-child(even) td { background:#2a2a2a; }
.mono { font-family:'Cascadia Code',Consolas,'Courier New',monospace; font-size:0.86rem; color:#ce9178; }
.host-pill { display:inline-block; background:#1e1e1e; border:1px solid #3c3c3c; border-radius:3px; padding:0.05rem 0.4rem; margin:0.1rem 0.15rem 0.1rem 0; font-family:'Cascadia Code',Consolas,monospace; font-size:0.78rem; color:#9cdcfe; }
.warn-banner { background:#4a3b1a; color:#ffd700; padding:0.55rem 0.75rem; border-left:3px solid #ffd700; border-radius:4px; margin:0.4rem 0; font-size:0.92rem; }
.error-banner { background:#4a1a1a; color:#f48771; padding:0.55rem 0.75rem; border-left:3px solid #f48771; border-radius:4px; margin:0.4rem 0; font-size:0.92rem; }
.none { color:#6a6a6a; font-style:italic; }
.bar-cell { min-width:120px; }
.bar { display:inline-block; background:#1a2e1a; height:0.7rem; vertical-align:middle; margin-right:0.4rem; border-radius:2px; }
.bar-unused { background:#332b1a; }
.bar-audit { background:#3a1a1a; }
footer { text-align:center; padding:0.8rem; font-size:0.74rem; color:#6a6a6a; }
</style></head><body><div class="wrap">
"""

def render_html(agg: dict[str, Any], window_label: str, short_names: bool) -> str:
    apps = agg["apps"]
    host_count = agg["host_count"]
    audit_off = agg["audit_off_hosts"]
    cmdline_off = agg["cmdline_off_hosts"]
    sortable = sorted(apps.items(), key=lambda kv: (-len(kv[1]["hosts_used"]), kv[0]))
    show_host = (lambda h: short(h)) if short_names else (lambda h: h)

    used_total    = sum(1 for a in apps.values() if a["hosts_used"])
    unused_total  = sum(1 for a in apps.values() if not a["hosts_used"] and a["hosts_unused"])

    parts = [HTML_HEAD]
    parts.append(f"""
<header>
  <h1>softwareUsage -- fleet summary</h1>
  <div class="meta">
    <span>{window_label}</span>
    <span>{host_count} host{'s' if host_count != 1 else ''}</span>
    <span>generated {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}</span>
  </div>
</header>
<div class="stats">
  <div class="stat stat-hosts"><div class="count">{host_count}</div><div class="label">Hosts reporting</div></div>
  <div class="stat stat-used"><div class="count">{used_total}</div><div class="label">Apps used somewhere</div></div>
  <div class="stat stat-unused"><div class="count">{unused_total}</div><div class="label">Apps unused fleetwide</div></div>
  <div class="stat stat-auditoff"><div class="count">{len(audit_off)}</div><div class="label">Hosts with audit OFF</div></div>
</div>
""")

    if audit_off:
        host_pills = ' '.join(f'<span class="host-pill">{show_host(h)}</span>' for h in audit_off)
        parts.append(f'<section><div class="error-banner"><strong>Process Creation auditing is OFF on {len(audit_off)} host(s):</strong><br>{host_pills}</div></section>')
    if cmdline_off:
        host_pills = ' '.join(f'<span class="host-pill">{show_host(h)}</span>' for h in cmdline_off)
        parts.append(f'<section><div class="warn-banner"><strong>Command-line capture is OFF on {len(cmdline_off)} host(s)</strong> (executions are counted, but per-script details are blank):<br>{host_pills}</div></section>')

    parts.append('<section><h2>Per-app fleet rollup</h2><table><thead><tr>'
                 '<th>App</th><th style="text-align:right">Hosts used</th>'
                 '<th style="text-align:right">Hosts unused</th>'
                 '<th style="text-align:right">Hosts audit-off</th>'
                 '<th style="text-align:right">Total executions</th>'
                 '<th>Last seen</th></tr></thead><tbody>')
    for key, a in sortable:
        used_n = len(a["hosts_used"])
        unused_n = len(a["hosts_unused"])
        audit_n = len(a["hosts_audit_off"])
        parts.append(
            f'<tr><td><strong>{a["label"]}</strong> <span class="mono" style="color:#6a6a6a">({key})</span></td>'
            f'<td style="text-align:right">{used_n}</td>'
            f'<td style="text-align:right">{unused_n}</td>'
            f'<td style="text-align:right">{audit_n}</td>'
            f'<td style="text-align:right">{a["total_executions"]}</td>'
            f'<td>{a.get("last_seen") or "-"}</td></tr>'
        )
    parts.append('</tbody></table></section>')

    # Per-app: list hosts that USED it (most actionable view)
    parts.append('<section><h2>Hosts where each app was used</h2>')
    any_used = False
    for key, a in sortable:
        if not a["hosts_used"]:
            continue
        any_used = True
        host_pills = ' '.join(f'<span class="host-pill">{show_host(h)}</span>' for h in a["hosts_used"])
        parts.append(f'<h3 style="margin-top:0.8rem; font-size:0.95rem; color:#d4d4d4;">{a["label"]} <span class="mono" style="color:#6a6a6a">({key})</span> -- {len(a["hosts_used"])} host(s)</h3><div>{host_pills}</div>')
    if not any_used:
        parts.append('<p class="none">No apps in the catalog were used by any host in this window.</p>')
    parts.append('</section>')

    # Per-app: list hosts that DID NOT use it (rationalization view)
    parts.append('<section><h2>Hosts where each app was unused</h2>')
    any_unused = False
    for key, a in sortable:
        if not a["hosts_unused"]:
            continue
        any_unused = True
        host_pills = ' '.join(f'<span class="host-pill">{show_host(h)}</span>' for h in a["hosts_unused"])
        parts.append(f'<h3 style="margin-top:0.8rem; font-size:0.95rem; color:#d4d4d4;">{a["label"]} <span class="mono" style="color:#6a6a6a">({key})</span> -- {len(a["hosts_unused"])} host(s)</h3><div>{host_pills}</div>')
    if not any_unused:
        parts.append('<p class="none">Every app in the catalog had at least one usage on every reporting host.</p>')
    parts.append('</section>')

    parts.append(f'<footer>softwareUsage fleet summary &middot; generated {datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}</footer>')
    parts.append('<script type="application/json" id="softwareUsage-fleet-data">')
    parts.append(json.dumps(agg, default=str))
    parts.append('</script></div></body></html>')
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Archival
# ---------------------------------------------------------------------------

def archive_records(log_dir: Path, records: list[dict[str, Any]], retain_days: int) -> Path | None:
    if not records:
        return None
    arc_dir = log_dir / "archive"
    arc_dir.mkdir(exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    zip_path = arc_dir / f"{ts}_softwareUsage_run.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for r in records:
            p = Path(r["_file"])
            if p.is_file():
                zf.write(p, arcname=p.name)
                try:
                    p.unlink()
                except OSError:
                    pass
    # prune
    cutoff = datetime.now(timezone.utc) - timedelta(days=retain_days)
    for old in arc_dir.glob("*_softwareUsage_run.zip"):
        try:
            ots = datetime.strptime(old.stem.split("_")[0], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        except Exception:
            continue
        if ots < cutoff:
            try: old.unlink()
            except OSError: pass
    return zip_path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="softwareUsage fleet summary")
    ap.add_argument("--log-dir", default=str(DEFAULT_LOG_DIR))
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--today",       action="store_true", help="UTC calendar day")
    g.add_argument("--last-hours",  type=int,            help="last N hours")
    ap.add_argument("--since",      help="UTC start, e.g. 20260601T010000Z")
    ap.add_argument("--until",      help="UTC end,   e.g. 20260601T230000Z")
    ap.add_argument("--short-names", action="store_true")
    ap.add_argument("--archive",   action="store_true", help="zip consumed JSONs into archive/")
    ap.add_argument("--retain-days", type=int, default=90)
    ap.add_argument("--no-html",   action="store_true")
    ap.add_argument("--no-json",   action="store_true")
    args = ap.parse_args()

    log_dir = Path(args.log_dir).expanduser()
    now = datetime.now(timezone.utc)
    if args.today:
        since = now.replace(hour=0, minute=0, second=0, microsecond=0)
        until = since + timedelta(days=1) - timedelta(seconds=1)
        window_label = f"UTC day {since.strftime('%Y-%m-%d')}"
    elif args.last_hours:
        until = now
        since = now - timedelta(hours=args.last_hours)
        window_label = f"last {args.last_hours}h"
    elif args.since and args.until:
        since = parse_ts(args.since)
        until = parse_ts(args.until)
        window_label = f"{args.since} .. {args.until}"
    else:
        # default: last 24h
        until = now
        since = now - timedelta(hours=24)
        window_label = "last 24h (default)"

    records = collect(log_dir, since, until)
    if not records:
        print(f"[!] no softwareUsage JSON found in {log_dir} between {since.isoformat()} and {until.isoformat()}", file=sys.stderr)
        return 2

    print(f"[+] {len(records)} per-host record(s) in window: {window_label}")
    by_host = last_run_wins(records)
    print(f"[+] {len(by_host)} unique host(s) after last-run-wins dedup")
    agg = aggregate(by_host)

    out_ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = log_dir / "reports"
    out_dir.mkdir(exist_ok=True)

    if not args.no_json:
        json_path = out_dir / f"{out_ts}_softwareUsage_fleet_summary.json"
        json_path.write_text(json.dumps(agg, indent=2, default=str), encoding="utf-8")
        print(f"[+] wrote {json_path}")

    if not args.no_html:
        html_path = out_dir / f"{out_ts}_softwareUsage_fleet_summary.html"
        html_path.write_text(render_html(agg, window_label, args.short_names), encoding="utf-8")
        print(f"[+] wrote {html_path}")

    if args.archive:
        zip_path = archive_records(log_dir, records, args.retain_days)
        if zip_path:
            print(f"[+] archived {len(records)} JSON(s) into {zip_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
