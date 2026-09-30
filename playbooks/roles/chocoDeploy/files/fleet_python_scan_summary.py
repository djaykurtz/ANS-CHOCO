#!/usr/bin/env python3.12
"""
fleet_python_scan_summary.py

Aggregate per-host JSON output from scan_python_state.ps1 collected via:

    ansible <hosts> -m ansible.windows.win_shell \\
        -a '& "C:/Windows/Temp/scan_python_state.ps1"' > /tmp/fleet_python_scan.txt

Reads that captured output, parses the embedded JSON payloads, and produces
a fleet-wide summary:
    - hosts per track combination
    - total below-floor components per track
    - patch version distribution
    - per-host plan rows for remediation (which tracks to remove on which hosts)

Usage:
    python3.12 fleet_python_scan_summary.py /tmp/fleet_python_scan.txt
    python3.12 fleet_python_scan_summary.py /tmp/fleet_python_scan.txt --floor 3.12
    python3.12 fleet_python_scan_summary.py /tmp/fleet_python_scan.txt --json > plan.json
"""
import argparse, json, re, sys
from collections import Counter, defaultdict


def parse_ansible_output(text):
    records = []
    unreachable = []
    for line in text.splitlines():
        if line.startswith("{"):
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                pass
            continue
        m = re.match(r"^(\S+) \| UNREACHABLE", line)
        if m:
            unreachable.append(m.group(1))
            continue
        m = re.match(r"^(\S+) \| FAILED", line)
        if m:
            unreachable.append(m.group(1) + " (FAILED)")
    return records, unreachable


def track_lt(a, b):
    """3.10 < 3.12 numeric, not string."""
    try:
        am, an = (int(x) for x in a.split("."))
        bm, bn = (int(x) for x in b.split("."))
        return (am, an) < (bm, bn)
    except (ValueError, AttributeError):
        return False


def summarize(records, floor):
    tracks_per_host = Counter()
    choco_pkgs_per_host = Counter()
    hosts_with_track = defaultdict(set)
    component_counts_by_track = defaultdict(list)
    patches_by_track = defaultdict(Counter)
    publishers = Counter()
    hosts_pythonless = 0

    plan = []  # remediation plan rows

    for r in records:
        host = r.get("host", "(unknown)")
        tracks = sorted({t["track"] for t in r.get("by_track", [])})
        tracks_per_host[tuple(tracks)] += 1
        choco_pkgs = tuple(sorted(p["pkg"] for p in r.get("choco_pkgs", [])))
        choco_pkgs_per_host[choco_pkgs] += 1
        if not tracks and not choco_pkgs:
            hosts_pythonless += 1

        for tinfo in r.get("by_track", []):
            t = tinfo["track"]
            hosts_with_track[t].add(host)
            component_counts_by_track[t].append(tinfo["component_count"])
            publishers[tinfo.get("sample_publisher", "")] += tinfo["component_count"]
            for p in tinfo.get("patches_seen", []):
                patches_by_track[t][p] += 1

            if floor and track_lt(t, floor) and not tinfo["from_chocolatey"]:
                plan.append({
                    "host": host,
                    "track": t,
                    "component_count": tinfo["component_count"],
                    "patches_seen": list(tinfo.get("patches_seen", [])),
                })

    return {
        "tracks_per_host":           dict(tracks_per_host),
        "choco_pkgs_per_host":       dict(choco_pkgs_per_host),
        "hosts_with_track":          {k: sorted(v) for k, v in hosts_with_track.items()},
        "component_counts_by_track": dict(component_counts_by_track),
        "patches_by_track":          {k: dict(v) for k, v in patches_by_track.items()},
        "publishers":                dict(publishers),
        "hosts_pythonless":          hosts_pythonless,
        "remediation_plan":          plan,
    }


def render_text(summary, records, unreachable, floor):
    out = []
    out.append(f"Hosts reporting:    {len(records)}")
    out.append(f"Unreachable/failed: {len(unreachable)}  {unreachable if unreachable else ''}")
    out.append("")
    out.append("=== Choco-managed pythonX on each host ===")
    for k, v in sorted(summary["choco_pkgs_per_host"].items(), key=lambda kv: -kv[1]):
        label = list(k) if k else "(none)"
        out.append(f"  {v:3d} hosts have choco: {label}")
    out.append("")
    out.append("=== Unique vendor track combinations ===")
    for k, v in sorted(summary["tracks_per_host"].items(), key=lambda kv: -kv[1]):
        label = list(k) if k else "(none)"
        out.append(f"  {v:3d} hosts have vendor tracks: {label}")
    out.append("")
    out.append("=== Component counts per track (vendor + choco mixed) ===")
    for t in sorted(summary["component_counts_by_track"]):
        cs = summary["component_counts_by_track"][t]
        out.append(f"  {t:6s}: hosts={len(cs):3d}  components min={min(cs)} max={max(cs)} distinct={sorted(set(cs))}")
    out.append("")
    out.append("=== Patch versions seen per track ===")
    for t in sorted(summary["patches_by_track"]):
        out.append(f"  {t:6s}: {dict(summary['patches_by_track'][t])}")
    out.append("")
    if floor:
        out.append(f"=== REMEDIATION PLAN (floor={floor}, below-floor vendor tracks only) ===")
        plan = summary["remediation_plan"]
        if not plan:
            out.append("  (nothing below floor)")
        else:
            by_track = defaultdict(list)
            for row in plan:
                by_track[row["track"]].append(row)
            for t in sorted(by_track):
                rows = by_track[t]
                total_comp = sum(r["component_count"] for r in rows)
                out.append(f"  Track {t}: {len(rows)} host(s), {total_comp} components total")
                for r in rows:
                    out.append(f"    {r['host']:60s} components={r['component_count']}  patches={r['patches_seen']}")
        out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description="Aggregate fleet python scan output.")
    ap.add_argument("input", help="path to ansible scan output (mixed text + JSON)")
    ap.add_argument("--floor", help="track floor (e.g. 3.12); anything below is included in plan")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = ap.parse_args()

    with open(args.input, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    records, unreachable = parse_ansible_output(text)
    summary = summarize(records, args.floor)
    if args.json:
        print(json.dumps({
            "hosts_reporting": len(records),
            "unreachable":     unreachable,
            "floor":           args.floor,
            **summary,
        }, indent=2, default=str))
    else:
        print(render_text(summary, records, unreachable, args.floor))


if __name__ == "__main__":
    sys.exit(main())
