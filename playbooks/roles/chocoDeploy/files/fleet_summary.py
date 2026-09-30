#!/usr/bin/env python3
"""
chocoDeploy Fleet Summary Report

Reads per-host JSON reports from the control node log directory and produces
a consolidated fleet summary for downtime review boards.

Input:  Per-host JSONs at <json_dir>/*_chocoDeploy.json
Output: Fleet summary HTML in <output_dir> (default <json_dir>/reports/); with
        --include-text / --include-json also .txt and .json under <output_dir>/detailed/

Features:
  - Groups hosts by site (derived from inventory_source in each JSON)
  - Last-run-wins dedup: when a host has multiple runs, only the latest
    event per software is counted so retries replace earlier failures
  - Retry annotation: hosts that required multiple runs show retry counts

Run on the control node after a downtime window, then pull the output to your workstation.

Usage:
  python fleet_summary.py --today --archive --short-names

  python fleet_summary.py --since 20260318T010000Z --until 20260318T070000Z --short-names

  python fleet_summary.py --today --output-dir /tmp/fleet --short-names

  python fleet_summary.py --today --archive --retain-days 60

Default input/output dir is $CHOCO_FLEET_DATA_ROOT/LOGS/chocoDeploy (data root defaults to /opt/ansible).

Then from your workstation (PowerShell):
  scp <you>@ansible-ctl-01.example.com:/opt/ansible/LOGS/chocoDeploy/*fleet_summary* C:\\tools\\chocolog\\
"""

import argparse
import html
import json
import os
import re
import sys
import zipfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone


DEFAULT_JSON_DIR = os.path.join(os.environ.get("CHOCO_FLEET_DATA_ROOT") or "/opt/ansible", "LOGS", "chocoDeploy")

FILENAME_RE = re.compile(
    r"^(\d{8}T\d{6}Z)_(.+)_chocoDeploy\.json$"
)
TARGET_FILENAME_RE = re.compile(
    r"^(\d{8}T\d{6}Z)_chocoDeploy\.json$"
)


def parse_timestamp(ts_str):
    """Parse a UTC timestamp like 20260318T015031Z."""
    return datetime.strptime(ts_str, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)


def discover_jsons(json_dir, since=None, until=None, today=False, last_hours=None):
    """Find and filter per-host JSON files."""
    if last_hours is not None:
        now = datetime.now(timezone.utc)
        since = now - timedelta(hours=last_hours)
        until = None
    elif today:
        now = datetime.now(timezone.utc)
        since = now.replace(hour=0, minute=0, second=0, microsecond=0)
        until = None

    # Only two layouts count, so evidence copies in other subfolders (collected,
    # compliance, reports, archive) are never mixed into a roll-up:
    #   <json_dir>/<ts>_<host>_chocoDeploy.json          normal control-node reports
    #   <json_dir>/<host>/<ts>_chocoDeploy.json          collect_chocoDeploy_reports.yml layout
    candidates = []
    if not os.path.isdir(json_dir):
        return []
    for entry in os.scandir(json_dir):
        if entry.is_file():
            candidates.append((json_dir, entry.name, FILENAME_RE.match(entry.name), None))
        elif entry.is_dir():
            for sub in os.scandir(entry.path):
                if sub.is_file():
                    candidates.append((entry.path, sub.name, None, TARGET_FILENAME_RE.match(sub.name)))

    found = []
    for root, fname, m, target_match in candidates:
        if not m and not target_match:
            continue
        timestamp = (m or target_match).group(1)
        ts = parse_timestamp(timestamp)
        if since and ts < since:
            continue
        if until and ts > until:
            continue
        hostname = m.group(2) if m else os.path.basename(root)
        found.append({
            "path": os.path.join(root, fname),
            "timestamp": timestamp,
            "ts": ts,
            "hostname": hostname,
        })
    return sorted(found, key=lambda x: (x["hostname"], x["ts"]))


def read_json_report(filepath):
    """Read a per-host JSON report and return the data dict."""
    with open(filepath, encoding="utf-8-sig") as f:
        return json.load(f)


def derive_site_label(inventory_source):
    """Derive a short site label from an inventory source path.

    Examples:
      inventory/LAB/lab-20260101-patch.yml     ->  LAB
      inventory/EXAMPLE/inv-example.yml       ->  EXAMPLE
      inventory/TEST/inv-TEST.yml              ->  TEST
      /full/path/to/inventory/FOO/bar.yml      ->  FOO
      (empty or missing)                       ->  unknown
    """
    if not inventory_source:
        return "unknown"
    # Normalize path separators
    path = inventory_source.replace("\\", "/")
    # Look for inventory/<SITE>/... pattern
    m = re.search(r"inventory/([^/]+)/", path)
    if m:
        return m.group(1)
    # Fallback: use the parent directory name
    parent = os.path.basename(os.path.dirname(path))
    return parent if parent else "unknown"


def resolve_host_final_state(all_runs):
    """Apply last-run-wins dedup across multiple runs for a single host.

    For each software, only the latest event (by run order) counts.
    Errors are only retained if no subsequent run produced a successful
    event for that same software.

    Returns (final_events, final_errors, resolved_error_count).
    resolved_error_count is how many errors from earlier runs were
    superseded by later successes (i.e. fixed by retries).
    """
    # Build per-software timeline: last event wins
    software_events = {}  # software -> latest event dict
    for data in all_runs:
        for event in data.get("events", []):
            sw = event.get("software", "")
            if sw:
                software_events[sw] = event

    # Build per-software error map: track which software had errors
    software_errors = {}  # software -> list of error dicts
    for data in all_runs:
        for err in data.get("errors", []):
            sw = err.get("software", "")
            if sw not in software_errors:
                software_errors[sw] = []
            software_errors[sw].append(err)

    # Determine which errors are still unresolved
    # An error is resolved if the software's final event is a success action
    success_actions = {"Converted", "Installed", "Upgraded", "NoChange", "Removed"}
    final_errors = []
    advisories = []
    resolved_count = 0

    # If any run for this host reports a pending reboot, vendor uninstalls
    # that "fail verification" are almost always the MSI being queued via
    # PendingFileRenameOperations. Treat those as cosmetic, not real errors.
    host_pending_reboot = any(
        bool(data.get("pending_reboot", False)) for data in all_runs
    )

    def _is_advisory(err):
        # System-state advisories (pending-reboot warnings) are informational,
        # not failures. They are tracked separately and never block exit/status.
        # NB: pending-reboot HARD reasons (CBS, ComputerName rename, SCM
        # UpdateExeVolatile) are real errors that can block MSI installs --
        # those have operation 'pending-reboot-hard' and stay in errors[].
        # Soft reasons (PFRO, WU) live in advisories.reboot[] in the role's
        # output but if any sneak into errors[] from older runs, classify
        # by explicit operation names instead of substring.
        op = (err.get("operation", "") or "").lower()
        sw = (err.get("software", "") or "").lower()
        if sw == "system-state":
            if op in ("pending-reboot-warning", "pending-reboot-soft"):
                return True
            if op.endswith("-warning"):
                return True
            # 'pending-reboot-hard' must NOT be classified as advisory.
        # Vendor uninstall verify miss + pending reboot on the host = cosmetic.
        if host_pending_reboot and op == "vendor_remove_verify":
            return True
        return False

    for sw, errors in software_errors.items():
        final_event = software_events.get(sw)
        if final_event and final_event.get("action", "") in success_actions:
            # This software was fixed by a retry - errors are resolved
            resolved_count += len(errors)
        else:
            # Split advisories (system-state warnings) from real errors
            for err in errors:
                if _is_advisory(err):
                    advisories.append(err)
                else:
                    final_errors.append(err)

    # Also keep system-level entries not tied to specific software (sw == "").
    # Note: system-state entries are already handled in the software_errors loop above.
    seen_keys = set()
    for data in all_runs:
        for err in data.get("errors", []):
            sw = err.get("software", "")
            if sw:
                continue
            key = (err.get("operation", ""), err.get("message", ""))
            if key in seen_keys:
                continue
            seen_keys.add(key)
            if _is_advisory(err):
                advisories.append(err)
            else:
                final_errors.append(err)

    final_events = list(software_events.values())
    return final_events, final_errors, resolved_count, advisories


def aggregate(json_files):
    """Aggregate per-host JSON data into fleet stats with site grouping."""
    by_host = defaultdict(list)
    for jf in json_files:
        by_host[jf["hostname"]].append(jf)

    hosts = {}
    all_timestamps = set()

    for hostname in sorted(by_host):
        host_files = sorted(by_host[hostname], key=lambda x: x["ts"])
        all_runs = []
        for hf in host_files:
            data = read_json_report(hf["path"])
            all_runs.append(data)
            all_timestamps.add(hf["timestamp"])

        # Derive site from inventory_source across all runs for this host.
        # Use the first run's inventory_source; retries on the same host
        # come from the same site.  Fall back to parsing the ansible_command.
        site = "unknown"
        for data in all_runs:
            inv_src = data.get("inventory_source", "")
            if inv_src:
                site = derive_site_label(inv_src)
                break
        if site == "unknown":
            # Legacy JSONs without inventory_source: parse from ansible_command
            for data in all_runs:
                cmd = data.get("diagnostics", {}).get("ansible_command", "")
                m = re.search(r"-i\s+(\S+)", cmd)
                if m:
                    site = derive_site_label(m.group(1))
                    break

        # Apply last-run-wins dedup
        final_events, final_errors, resolved_count, advisories = resolve_host_final_state(all_runs)

        retries = len(all_runs) - 1  # 0 = first-pass clean

        h = {
            "hostname": hostname,
            "site": site,
            "timestamp": host_files[-1]["timestamp"],
            "deployment": ", ".join(dict.fromkeys(r.get("deployment", "") for r in all_runs)),
            "status": "OK",
            "choco_conversions": 0,
            "installed": 0,
            "upgraded": 0,
            "compliant": 0,
            "policy_removed": 0,
            "errors": len(final_errors),
            "resolved_errors": resolved_count,
            "advisories": len(advisories),
            "reboot_pending": False,
            "reboot_actionable": False,
            "reboot_reasons": [],
            "error_details": [],
            "runs": len(all_runs),
            "retries": retries,
            "_final_events": final_events,
        }

        # Count from deduped final events
        for event in final_events:
            action = event.get("action", "")
            notes = event.get("notes", "")
            if action == "Converted":
                h["choco_conversions"] += 1
            elif action == "Installed":
                h["installed"] += 1
            elif action == "Upgraded":
                h["upgraded"] += 1
            elif action == "NoChange":
                h["compliant"] += 1
            elif action == "Removed":
                if "Converted to Chocolatey" not in notes:
                    h["policy_removed"] += 1

        # Pending reboot: use the last run's state
        last_run = all_runs[-1]
        if last_run.get("pending_reboot", False):
            h["reboot_pending"] = True
            h["reboot_actionable"] = last_run.get("pending_reboot_actionable", False)
            h["reboot_reasons"] = last_run.get("pending_reboot_reasons", [])

        # Pending reboot from advisories (any operation indicating pending reboot)
        for adv in advisories:
            op = (adv.get("operation", "") or "").lower()
            msg = (adv.get("message", "") or "").lower()
            if "pending" in op or "pending" in msg:
                h["reboot_pending"] = True
                break

        # Error details from final (unresolved) errors. Advisories are excluded.
        # IMPORTANT: pending-reboot-hard is NOT a software error if deployment succeeded.
        # Exclude it from error_details and don't count it in errors.
        for err in final_errors:
            sw = err.get("software", "")
            op = (err.get("operation", "") or "").lower()
            # Skip pending-reboot-hard entries; they're system state, not software errors
            if op == "pending-reboot-hard":
                h["reboot_pending"] = True
                continue
            label = sw if sw and sw != "system-state" else (op or "system-state")
            h["error_details"].append(label)

        # Recount errors excluding pending-reboot-hard
        h["errors"] = len([e for e in final_errors 
                          if (e.get("operation", "") or "").lower() != "pending-reboot-hard"])

        # Mark as failed only if unresolved fatal errors exist
        if h["errors"] > 0:
            for err in final_errors:
                if "fatal" in err.get("message", "").lower():
                    h["status"] = "Failed"
                    break

        hosts[hostname] = h

    # Build site-level aggregation
    sites = defaultdict(lambda: {
        "hosts": {},
        "totals": defaultdict(int),
        "software_actions": defaultdict(lambda: defaultdict(int)),
        "software_versions": {},
        "problem_hosts": [],
        "deployment_modes": set(),
    })

    fleet_totals = defaultdict(int)
    fleet_software = defaultdict(lambda: defaultdict(int))
    fleet_software_versions = {}

    for hostname, h in sorted(hosts.items()):
        site_key = h["site"]
        s = sites[site_key]
        s["hosts"][hostname] = h

        for mode in h["deployment"].split(","):
            mode = mode.strip()
            if mode:
                s["deployment_modes"].add(mode)

        for key in ("choco_conversions", "installed", "upgraded", "compliant", "policy_removed", "errors"):
            s["totals"][key] += h[key]
            fleet_totals[key] += h[key]
        s["totals"]["resolved_errors"] += h["resolved_errors"]
        fleet_totals["resolved_errors"] += h["resolved_errors"]
        if h["reboot_pending"]:
            s["totals"]["reboot_pending"] += 1
            fleet_totals["reboot_pending"] += 1
        if h["retries"] > 0:
            s["totals"]["retried_hosts"] += 1
            fleet_totals["retried_hosts"] += 1

        if h["errors"] > 0:
            detail = ", ".join(h["error_details"][:5])
            s["problem_hosts"].append(f"{hostname}: {h['errors']} error(s) ({detail})")

        # Per-software actions from cached final events
        for event in h["_final_events"]:
            action = event.get("action", "")
            software = event.get("software", "")
            notes = event.get("notes", "")
            # Track version: prefer new_version (target), fall back to previous_version (compliant)
            ver = event.get("new_version", "") or event.get("previous_version", "")
            if ver and software:
                s["software_versions"][software] = ver
                fleet_software_versions[software] = ver
            if action == "Converted":
                s["software_actions"][software]["Choco Conversion"] += 1
                fleet_software[software]["Choco Conversion"] += 1
            elif action == "Installed":
                s["software_actions"][software]["Installed"] += 1
                fleet_software[software]["Installed"] += 1
            elif action == "Upgraded":
                s["software_actions"][software]["Upgraded"] += 1
                fleet_software[software]["Upgraded"] += 1
            elif action == "NoChange":
                s["software_actions"][software]["Compliant"] += 1
                fleet_software[software]["Compliant"] += 1
            elif action == "Removed":
                if "Converted to Chocolatey" not in notes:
                    s["software_actions"][software]["Removed"] += 1
                    fleet_software[software]["Removed"] += 1

    total_hosts = len(hosts)
    failed = sum(1 for h in hosts.values() if h["status"] == "Failed")
    succeeded = total_hosts - failed
    pct = f"{(succeeded / total_hosts * 100):.1f}%" if total_hosts > 0 else "N/A"

    deployment_modes = sorted(set(
        mode.strip()
        for h in hosts.values()
        for mode in h["deployment"].split(",")
        if mode.strip()
    ))

    return {
        "hosts": hosts,
        "sites": dict(sites),
        "fleet_totals": fleet_totals,
        "fleet_software": dict(fleet_software),
        "fleet_software_versions": fleet_software_versions,
        "total_hosts": total_hosts,
        "succeeded": succeeded,
        "failed": failed,
        "success_pct": pct,
        "deployment_modes": deployment_modes,
        "timestamps": sorted(all_timestamps),
    }


def shorten_hostnames(agg):
    """Strip domain suffixes from hostnames for cleaner output."""
    new_hosts = {}
    for hostname, h in agg["hosts"].items():
        short = hostname.split(".")[0]
        h["hostname"] = short
        new_hosts[short] = h
    agg["hosts"] = new_hosts

    # Rebuild site host dicts and problem host lists with short names
    for site_key, s in agg["sites"].items():
        new_site_hosts = {}
        for hostname, h in s["hosts"].items():
            short = hostname.split(".")[0]
            h["hostname"] = short
            new_site_hosts[short] = h
        s["hosts"] = new_site_hosts
        s["problem_hosts"] = []
        for hostname, h in sorted(new_site_hosts.items()):
            if h["errors"] > 0:
                detail = ", ".join(h["error_details"][:5])
                s["problem_hosts"].append(f"{hostname}: {h['errors']} error(s) ({detail})")
    return agg


def _build_software_table(sw_actions, indent="  "):
    """Build a formatted software results table."""
    lines = []
    action_cols = ["Choco Conversion", "Installed", "Upgraded", "Removed", "Compliant"]
    change_cols = ["Choco Conversion", "Installed", "Upgraded", "Removed"]
    if sw_actions:
        max_name = max(len(s) for s in sw_actions)
        max_name = max(max_name, 10)
        header = f"{indent}{'Software':<{max_name}}  " + "  ".join(f"{c:>10}" for c in action_cols)
        lines.append(header)
        lines.append(indent + "-" * len(header.lstrip()))
        for software in sorted(sw_actions):
            counts = sw_actions[software]
            row_vals = [counts.get(c, 0) for c in action_cols]
            if sum(row_vals) == 0:
                continue
            row = f"{indent}{software:<{max_name}}  " + "  ".join(
                f"{v:>10}" if v > 0 else f"{'·':>10}" for v in row_vals
            )
            lines.append(row)
        lines.append(indent + "-" * len(header.lstrip()))
        total_row_vals = [sum(sw_actions[s].get(c, 0) for s in sw_actions) for c in action_cols]
        total_changes = sum(sw_actions[s].get(c, 0) for s in sw_actions for c in change_cols)
        total_label = f"SOFTWARE CHANGES ({total_changes})"
        lines.append(f"{indent}{total_label:<{max_name}}  " + "  ".join(f"{v:>10}" for v in total_row_vals))
    else:
        lines.append(f"{indent}- no software actions recorded")
    return lines


def build_text_report(agg):
    """Build the board-ready text summary with site grouping."""
    ts_range = agg["timestamps"][0] if len(agg["timestamps"]) == 1 else f"{agg['timestamps'][0]} .. {agg['timestamps'][-1]}"
    modes = ", ".join(agg["deployment_modes"]) or "unknown"
    ft = agg["fleet_totals"]

    lines = [
        "================================================================",
        "CHOCODEPLOY FLEET SUMMARY - PATCH EVENING",
        f"Report generated: {datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}",
        f"Run window:       {ts_range}",
        f"Deployment modes: {modes}",
        "================================================================",
        "",
        "FLEET STATUS",
        f"  Total hosts reported:     {agg['total_hosts']}",
        f"  Completed successfully:   {agg['succeeded']}",
        f"  Failed (fatal):           {agg['failed']}",
        f"  Retried (resolved):       {ft.get('retried_hosts', 0)}",
        "",
        f"SUCCESS RATE: {agg['success_pct']} ({agg['succeeded']}/{agg['total_hosts']})",
        "",
    ]

    # Per-site sections
    for site_key in sorted(agg["sites"]):
        s = agg["sites"][site_key]
        site_hosts = s["hosts"]
        st = s["totals"]
        site_modes = ", ".join(sorted(s["deployment_modes"])) or "unknown"
        site_total = len(site_hosts)
        site_failed = sum(1 for h in site_hosts.values() if h["status"] == "Failed")
        site_ok = site_total - site_failed
        site_retried = sum(1 for h in site_hosts.values() if h["retries"] > 0)

        lines.append(f"── {site_key} ({site_modes}) " + "─" * max(1, 60 - len(site_key) - len(site_modes) - 6))
        lines.append(f"  Hosts: {site_total}  |  Success: {site_ok}  |  Failed: {site_failed}  |  Retried: {site_retried}")
        lines.append("")

        lines.extend(_build_software_table(dict(s["software_actions"])))
        lines.append("")

        if st.get("resolved_errors", 0) > 0:
            lines.append(f"  Resolved by retry:        {st['resolved_errors']} error(s) cleared")
        # Count only fatal errors, not pending-reboot advisories
        fatal_errors = sum(1 for h in site_hosts.values() if h["status"] == "Failed")
        if fatal_errors > 0:
            lines.append(f"  Unresolved fatal errors:  {fatal_errors}")
        lines.append("")

    # Fleet-wide software roll-up (only when multiple sites)
    if len(agg["sites"]) > 1:
        lines.append("── FLEET TOTALS " + "─" * 44)
        lines.extend(_build_software_table(agg["fleet_software"]))
        lines.append("")

    # Pending reboots
    lines += [
        "PENDING REBOOTS",
        f"  Hosts with pending reboot: {ft.get('reboot_pending', 0)}",
    ]
    reboot_hosts = [h["hostname"] for h in sorted(agg["hosts"].values(), key=lambda x: x["hostname"]) if h["reboot_pending"]]
    if reboot_hosts:
        lines.append(f"  {', '.join(reboot_hosts)}")
    lines.append("")

    # Problematic systems (fleet-wide)
    lines.append("PROBLEMATIC SYSTEMS")
    all_problems = []
    for site_key in sorted(agg["sites"]):
        for p in agg["sites"][site_key]["problem_hosts"]:
            all_problems.append(f"  [{site_key}] {p}")
    if all_problems:
        lines.extend(all_problems)
    else:
        lines.append("  - none")
    lines.append("")

    # Retried systems
    retried = [(h["hostname"], h["retries"], h["site"]) for h in agg["hosts"].values() if h["retries"] > 0]
    if retried:
        lines.append("RETRIED SYSTEMS")
        for hostname, retries, site in sorted(retried):
            suffix = "retry" if retries == 1 else "retries"
            lines.append(f"  [{site}] {hostname}: {retries} {suffix}")
        lines.append("")

    lines.append("================================================================")

    return "\n".join(lines)


def build_json_report(agg):
    """Build structured JSON fleet report for Graylog ingestion and archival."""
    ft = agg["fleet_totals"]
    ts_range = (
        agg["timestamps"][0]
        if len(agg["timestamps"]) == 1
        else f"{agg['timestamps'][0]} .. {agg['timestamps'][-1]}"
    )

    report = {
        "report_type": "fleet_summary",
        "report_generated": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "run_window": ts_range,
        "deployment_modes": agg["deployment_modes"],
        "fleet_status": {
            "total_hosts": agg["total_hosts"],
            "succeeded": agg["succeeded"],
            "failed": agg["failed"],
            "retried": ft.get("retried_hosts", 0),
            "success_pct": agg["success_pct"],
            "pending_reboots": ft.get("reboot_pending", 0),
        },
        "fleet_software": {
            sw: dict(actions) for sw, actions in sorted(agg["fleet_software"].items())
        },
        "sites": {},
        "hosts": {},
    }

    for site_key in sorted(agg["sites"]):
        s = agg["sites"][site_key]
        site_hosts = s["hosts"]
        st = s["totals"]
        site_failed = sum(1 for h in site_hosts.values() if h["status"] == "Failed")
        report["sites"][site_key] = {
            "deployment_modes": sorted(s["deployment_modes"]),
            "total_hosts": len(site_hosts),
            "succeeded": len(site_hosts) - site_failed,
            "failed": site_failed,
            "retried": sum(1 for h in site_hosts.values() if h["retries"] > 0),
            "errors": st["errors"],
            "resolved_errors": st.get("resolved_errors", 0),
            "pending_reboots": st.get("reboot_pending", 0),
            "software": {
                sw: dict(actions) for sw, actions in sorted(s["software_actions"].items())
            },
            "problem_hosts": s["problem_hosts"],
        }

    for hostname in sorted(agg["hosts"]):
        h = agg["hosts"][hostname]
        report["hosts"][hostname] = {
            "site": h["site"],
            "status": h["status"],
            "deployment": h["deployment"],
            "last_run_time": h["timestamp"],
            "runs": h["runs"],
            "retries": h["retries"],
            "choco_conversions": h["choco_conversions"],
            "installed": h["installed"],
            "upgraded": h["upgraded"],
            "compliant": h["compliant"],
            "policy_removed": h["policy_removed"],
            "errors": h["errors"],
            "resolved_errors": h["resolved_errors"],
            "reboot_pending": h["reboot_pending"],
        }

    return report


def _e(text):
    """HTML-escape helper."""
    return html.escape(str(text))


def _sw_table_html(sw_actions, sw_versions=None, hosts_now_compliant=None):
    """Build an HTML software actions table body."""
    action_cols = ["Choco Conversion", "Installed", "Upgraded", "Removed", "Compliant"]
    change_cols = ["Choco Conversion", "Installed", "Upgraded", "Removed"]
    col_css = ["stat-converted", "stat-installed", "stat-upgraded", "stat-removed", "stat-compliant"]
    rows = []
    totals = [0] * len(action_cols)
    if sw_versions is None:
        sw_versions = {}
    for software in sorted(sw_actions):
        counts = sw_actions[software]
        vals = [counts.get(c, 0) for c in action_cols]
        if sum(vals) == 0:
            continue
        ver = sw_versions.get(software, "")
        sw_label = f'{_e(software)} <span class="sw-ver">{_e(ver)}</span>' if ver else _e(software)
        cells = f'<td>{sw_label}</td>'
        for i, v in enumerate(vals):
            css = col_css[i] if v > 0 else ""
            cells += f'<td class="{css}">{v if v > 0 else "&middot;"}</td>'
            totals[i] += v
        rows.append(f'<tr>{cells}</tr>')

    if not rows:
        return '<tr><td colspan="6" class="none">No software actions recorded</td></tr>'

    # Totals row - use hosts_now_compliant for the Compliant column if provided
    compliant_idx = action_cols.index("Compliant")
    total_changes = sum(sw_actions[s].get(c, 0) for s in sw_actions for c in change_cols)
    total_cells = f'<td><strong>Software Changes ({total_changes})</strong></td>'
    for i, v in enumerate(totals):
        if i == compliant_idx and hosts_now_compliant is not None:
            total_cells += f'<td><strong>{hosts_now_compliant}</strong></td>'
        else:
            total_cells += f'<td><strong>{v}</strong></td>'
    rows.append(f'<tr class="totals-row">{total_cells}</tr>')
    return "\n".join(rows)


def build_html_report(agg):
    """Build a standalone HTML fleet summary report matching the project's dark theme."""
    ft = agg["fleet_totals"]
    ts_range = (
        agg["timestamps"][0]
        if len(agg["timestamps"]) == 1
        else f'{agg["timestamps"][0]} &ndash; {agg["timestamps"][-1]}'
    )
    report_ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    modes = ", ".join(agg["deployment_modes"]) or "unknown"
    retried = ft.get("retried_hosts", 0)
    reboots = ft.get("reboot_pending", 0)

    # --- Site sections (summary only, no per-host detail) ---
    site_sections = []
    for site_key in sorted(agg["sites"]):
        s = agg["sites"][site_key]
        site_hosts = s["hosts"]
        st = s["totals"]
        site_modes = ", ".join(sorted(s["deployment_modes"])) or "unknown"
        site_total = len(site_hosts)
        site_failed = sum(1 for h in site_hosts.values() if h["status"] == "Failed")
        site_ok = site_total - site_failed
        site_retried = sum(1 for h in site_hosts.values() if h["retries"] > 0)

        notes = []
        if st.get("resolved_errors", 0) > 0:
            notes.append(f'<span class="resolved-note">{st["resolved_errors"]} error(s) resolved by retry</span>')
        if st["errors"] > 0:
            notes.append(f'<span class="unresolved-note">{st["errors"]} unresolved error(s)</span>')
        notes_html = " &middot; ".join(notes) if notes else ""

        site_sw_html = _sw_table_html(dict(s["software_actions"]), sw_versions=s.get("software_versions", {}), hosts_now_compliant=site_ok)

        site_sections.append(f'''
<section>
<h2>{_e(site_key)} <span class="site-modes">({_e(site_modes)})</span></h2>
<div class="site-stats">
<span>Hosts: <strong>{site_total}</strong></span>
<span>Success: <strong class="chk-pass">{site_ok}</strong></span>
<span>Failed: <strong class="{'chk-fail' if site_failed else 'chk-pass'}">{site_failed}</strong></span>
</div>
<table>
<thead><tr><th>Software</th><th>Converted</th><th>Installed</th><th>Upgraded</th><th>Removed</th><th>Compliant</th></tr></thead>
<tbody>
{site_sw_html}
</tbody>
</table>
{('<div class="section-notes">' + notes_html + '</div>') if notes_html else ''}
</section>''')

    # --- Fleet totals section (multi-site only) ---
    fleet_sw_section = ""
    if len(agg["sites"]) > 1:
        fleet_sw_html = _sw_table_html(agg["fleet_software"], sw_versions=agg.get("fleet_software_versions", {}), hosts_now_compliant=agg["succeeded"])
        fleet_sw_section = f'''
<section>
<h2>Fleet Totals</h2>
<table>
<thead><tr><th>Software</th><th>Converted</th><th>Installed</th><th>Upgraded</th><th>Removed</th><th>Compliant</th></tr></thead>
<tbody>
{fleet_sw_html}
</tbody>
</table>
</section>'''

    # --- Pending reboots section ---
    reboot_hosts = [h for h in sorted(agg["hosts"].values(), key=lambda x: x["hostname"]) if h["reboot_pending"]]
    reboot_hostnames = [h["hostname"] for h in reboot_hosts]
    actionable_reboots = [h for h in reboot_hosts if h["reboot_actionable"]]
    cosmetic_reboots = [h for h in reboot_hosts if not h["reboot_actionable"]]

    if reboot_hosts:
        reboot_parts = []
        if cosmetic_reboots:
            cosmetic_note = f'<span class="reboot-cosmetic-note">{len(cosmetic_reboots)} cosmetic (file rename operations &mdash; safe to defer to next patch window)</span>'
            reboot_parts.append(cosmetic_note)
        if actionable_reboots:
            actionable_names = ", ".join(_e(h["hostname"]) for h in actionable_reboots)
            actionable_note = f'<span class="reboot-actionable-note">{len(actionable_reboots)} actionable: {actionable_names}</span>'
            reboot_parts.append(actionable_note)
        reboot_list = "<br>".join(reboot_parts)
    else:
        reboot_list = '<span class="none">none</span>'

    # --- Problematic systems section ---
    all_problems = []
    for site_key in sorted(agg["sites"]):
        for p in agg["sites"][site_key]["problem_hosts"]:
            all_problems.append(f'<span class="site-tag">{_e(site_key)}</span> {_e(p)}')
    problems_html = "<br>".join(all_problems) if all_problems else '<span class="none">none</span>'

    # --- Reboot PowerShell script ---
    if reboot_hostnames:
        ps_hosts = ", ".join(f"'{h}'" for h in reboot_hostnames)
        reboot_script = (
            f"$hosts = @({ps_hosts})\n"
            f"Write-Host \"You are about to reboot $($hosts.Count) system(s):\" -ForegroundColor Yellow\n"
            f"$hosts | ForEach-Object {{ Write-Host \"  $_\" }}\n"
            f"$confirm = Read-Host \"Proceed? (yes/no)\"\n"
            f"if ($confirm -in @('yes','y','Yes','Y','YES')) {{\n"
            f"    Invoke-Command -ComputerName $hosts -ScriptBlock {{ Restart-Computer -Force }}\n"
            f"    Write-Host \"Reboot command sent to $($hosts.Count) host(s).\" -ForegroundColor Green\n"
            f"}} else {{\n"
            f"    Write-Host \"Reboot Cancelled.\" -ForegroundColor Red\n"
            f"}}\n"
        )
        reboot_script_section = f'''\n<details>\n<summary>PowerShell: Reboot these hosts</summary>\n<div class="detail-wrap">\n<div class="command">{_e(reboot_script)}</div>\n</div>\n</details>'''
    else:
        reboot_script_section = ""

    # --- Reboot indicator: use actionable state for color ---
    has_actionable = len(actionable_reboots) > 0 if reboot_hosts else False
    reboot_indicator_class = 'reboot-actionable' if has_actionable else ('reboot-cosmetic' if reboots > 0 else 'reboot-clear')

    # --- Collapsible per-host detail (at the very end) ---
    all_host_rows = []
    for hostname in sorted(agg["hosts"]):
        h = agg["hosts"][hostname]
        status_css = "status-ok" if h["status"] == "OK" else "status-fail"
        retry_cell = str(h["retries"]) if h["retries"] > 0 else "&middot;"
        retry_css = ' class="chk-warn"' if h["retries"] > 0 else ""
        reboot_cell = "Yes" if h["reboot_pending"] else "&middot;"
        reboot_css = ' class="chk-warn"' if h["reboot_pending"] else ""
        err_cell = str(h["errors"]) if h["errors"] > 0 else "&middot;"
        err_css = ' class="chk-fail"' if h["errors"] > 0 else ""
        all_host_rows.append(
            f'<tr>'
            f'<td><span class="site-tag">{_e(h["site"])}</span></td>'
            f'<td>{_e(hostname)}</td>'
            f'<td>{_e(h["deployment"])}</td>'
            f'<td>{h["choco_conversions"] if h["choco_conversions"] else "&middot;"}</td>'
            f'<td>{h["installed"] if h["installed"] else "&middot;"}</td>'
            f'<td>{h["upgraded"] if h["upgraded"] else "&middot;"}</td>'
            f'<td>{h["compliant"] if h["compliant"] else "&middot;"}</td>'
            f'<td>{h["policy_removed"] if h["policy_removed"] else "&middot;"}</td>'
            f'<td{err_css}>{err_cell}</td>'
            f'<td{retry_css}>{retry_cell}</td>'
            f'<td{reboot_css}>{reboot_cell}</td>'
            f'<td class="{status_css}">{_e(h["status"])}</td>'
            f'</tr>'
        )

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>chocoDeploy Fleet Summary - {_e(report_ts)}</title>
<style>
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
body {{
  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
  background: #1e1e1e;
  color: #d4d4d4;
  line-height: 1.6;
  font-size: 17px;
  padding: 1.5rem;
}}
.wrap {{ max-width: 1100px; margin: 0 auto; }}
header {{
  background: #0078d4;
  color: #fff;
  padding: 0.75rem 2rem;
  border-radius: 8px 8px 0 0;
}}
header h1 {{ font-size: 1.4rem; font-weight: 600; }}
.meta {{ margin-top: 0.3rem; font-size: 1rem; opacity: 0.9; }}
.meta span {{ display: inline-block; margin-right: 2rem; }}
.stats {{
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  padding: 1rem 2rem;
  background: #252526;
  border-bottom: 1px solid #3c3c3c;
  justify-content: center;
}}
.stat {{
  text-align: center;
  padding: 0.5rem 1.25rem;
  border-radius: 6px;
  min-width: 110px;
}}
.stat .count {{ font-size: 1.7rem; font-weight: 700; }}
.stat .label {{ font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; }}
.stat-total     {{ background: #1a2733; color: #569cd6; }}
.stat-ok        {{ background: #1a2e1a; color: #6a9955; }}
.stat-fail      {{ background: #3a1a1a; color: #f48771; }}
.reboot-indicator {{
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-width: 110px;
  padding: 0.5rem 1.25rem;
  border-radius: 6px;
}}
.reboot-indicator .power-icon {{
  width: 30px;
  height: 30px;
  border-radius: 50%;
  border: 2px solid;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1rem;
  font-weight: 700;
  margin: 0.15rem 0;
}}
.reboot-indicator .count {{ font-size: 1.7rem; font-weight: 700; }}
.reboot-indicator .label {{ font-size: 0.65rem; text-transform: uppercase; letter-spacing: 0.05em; text-align: center; line-height: 1.2; }}
.reboot-indicator.reboot-actionable .power-icon {{ border-color: #f44747; color: #f44747; background: #1e1e1e; }}
.reboot-indicator.reboot-actionable {{ background: #4a1a1a; color: #f44747; }}
.reboot-indicator.reboot-cosmetic .power-icon {{ border-color: #fff; color: #fff; background: #1e1e1e; }}
.reboot-indicator.reboot-cosmetic {{ background: #1e1e1e; color: #fff; }}
.reboot-indicator.reboot-clear .power-icon {{ border-color: #1e1e1e; color: #1e1e1e; background: #fff; }}
.reboot-indicator.reboot-clear {{ background: #fff; color: #1e1e1e; }}
.reboot-cosmetic-note {{ color: #9cdcfe; }}
.reboot-actionable-note {{ color: #f48771; font-weight: 600; }}
.stat-converted {{ color: #ce9178; }}
.stat-installed {{ color: #569cd6; }}
.stat-upgraded  {{ color: #c586c0; }}
.stat-compliant {{ color: #6a9955; }}
.stat-removed   {{ color: #f48771; }}
section {{
  background: #252526;
  padding: 0.75rem 2rem;
  border-bottom: 1px solid #3c3c3c;
}}
section:last-of-type {{
  border-radius: 0 0 8px 8px;
  border-bottom: none;
}}
h2 {{ font-size: 1.2rem; margin-bottom: 0.4rem; color: #e0e0e0; }}
h2 .site-modes {{ font-size: 0.9rem; color: #9cdcfe; font-weight: 400; }}
table {{ width: 100%; border-collapse: collapse; font-size: 1.05rem; margin-bottom: 0.5rem; }}
th {{
  text-align: left;
  padding: 0.4rem 0.6rem;
  background: #2d2d2d;
  border-bottom: 2px solid #3c3c3c;
  font-weight: 600;
  color: #569cd6;
  white-space: nowrap;
}}
th:not(:first-child) {{ text-align: center; }}
td {{
  padding: 0.35rem 0.6rem;
  border-bottom: 1px solid #333;
  color: #d4d4d4;
  white-space: nowrap;
}}
td:not(:first-child) {{ text-align: center; }}
tr:nth-child(even) td {{ background: #2a2a2a; }}
.totals-row td {{ border-top: 2px solid #3c3c3c; background: #2d2d2d; }}
.none {{ color: #6a6a6a; font-style: italic; }}
.chk-pass {{ color: #6a9955; font-weight: 600; }}
.chk-warn {{ color: #ce9178; font-weight: 600; }}
.chk-fail {{ color: #f48771; font-weight: 600; }}
.status-ok   {{ color: #6a9955; font-weight: 700; }}
.status-fail {{ color: #f48771; font-weight: 700; }}
.site-stats {{
  display: flex;
  gap: 1.5rem;
  font-size: 1.05rem;
  margin-bottom: 0.5rem;
  color: #d4d4d4;
}}
.site-tag {{
  background: #0e639c;
  color: #fff;
  padding: 0.1rem 0.5rem;
  border-radius: 3px;
  font-size: 0.8rem;
  font-weight: 600;
  margin-right: 0.3rem;
}}
.sw-ver {{
  color: #9cdcfe;
  font-weight: 400;
  font-size: 0.85em;
}}
.section-notes {{
  font-size: 1rem;
  margin: 0.2rem 0;
}}
.resolved-note {{ color: #6a9955; }}
.unresolved-note {{ color: #f48771; }}
.legend {{
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem 1.5rem;
  font-size: 0.95rem;
  padding: 0.5rem 2rem;
  background: #252526;
  border-bottom: 1px solid #3c3c3c;
  color: #9cdcfe;
}}
.legend span {{ white-space: nowrap; }}
.legend strong {{ margin-right: 0.2rem; }}
details {{
  background: #252526;
  border-bottom: 1px solid #3c3c3c;
  border-radius: 0 0 8px 8px;
}}
details summary {{
  padding: 0.6rem 2rem;
  cursor: pointer;
  color: #569cd6;
  font-weight: 600;
  font-size: 1.05rem;
  list-style: none;
  user-select: none;
}}
.command {{
  font-family: 'Cascadia Code', Consolas, 'Courier New', monospace;
  font-size: 0.9rem;
  background: #1e1e1e;
  color: #ce9178;
  padding: 0.75rem;
  border-radius: 4px;
  border: 1px solid #3c3c3c;
  overflow-x: auto;
  white-space: pre-wrap;
  word-break: break-all;
  margin-top: 0.5rem;
}}
details summary::-webkit-details-marker {{ display: none; }}
details summary::before {{
  content: '\\25B6\\FE0E';
  display: inline-block;
  margin-right: 0.5rem;
  transition: transform 0.15s;
  font-size: 0.75rem;
}}
details[open] summary::before {{
  transform: rotate(90deg);
}}
details .detail-wrap {{
  padding: 0 2rem 0.75rem;
}}
footer {{
  text-align: center;
  padding: 0.75rem;
  font-size: 0.7rem;
  color: #6a6a6a;
}}
</style>
</head>
<body>
<div class="wrap">

<header>
<h1>chocoDeploy Fleet Summary</h1>
<div class="meta">
<span><strong>Run window:</strong> {ts_range}</span>
<span><strong>Modes:</strong> {_e(modes)}</span>
<span><strong>Generated:</strong> {_e(report_ts)}</span>
</div>
</header>

<div class="stats">
<div class="stat stat-total"><div class="count">{len(agg['hosts'])}</div><div class="label">Total Hosts</div></div>
<div class="stat stat-ok"><div class="count">{agg["succeeded"]}</div><div class="label">Succeeded</div></div>
<div class="stat stat-fail"><div class="count">{agg["failed"]}</div><div class="label">Failed</div></div>
<div class="reboot-indicator {reboot_indicator_class}">
<div class="label">Pending Reboot</div>
<div class="power-icon">&#x23FB;</div>
<div class="label">{str(reboots) + ' host' + ('s' if reboots != 1 else '') if reboots > 0 else 'No'}</div>
</div>
</div>

<div class="legend">
<span><strong class="stat-converted">Converted</strong> &mdash; package replaced / converted to Choco management</span>
<span><strong class="stat-installed">Installed</strong> &mdash; new package installed from Chocolatey</span>
<span><strong class="stat-upgraded">Upgraded</strong> &mdash; existing package updated to approved version</span>
<span><strong class="stat-compliant">Compliant</strong> &mdash; package confirmed target version or newer</span>
<span><strong class="stat-removed">Removed</strong> &mdash; package removed via target or removal list</span>
</div>

{"".join(site_sections)}

{fleet_sw_section}

<section>
<h2>Pending Reboots</h2>
<p>{reboot_list}</p>
{reboot_script_section}
</section>

<details>
<summary>Problematic Systems</summary>
<div class="detail-wrap">
<p>{problems_html}</p>
</div>
</details>

<details>
<summary>Per-Host Detail ({agg["total_hosts"]} hosts)</summary>
<div class="detail-wrap">
<table>
<thead><tr><th>Site</th><th>Host</th><th>Mode</th><th>Conv</th><th>Inst</th><th>Upgr</th><th>OK</th><th>Rem</th><th>Err</th><th>Retries</th><th>Reboot</th><th>Status</th></tr></thead>
<tbody>
{"".join(all_host_rows)}
</tbody>
</table>
</div>
</details>

<footer>Generated by chocoDeploy fleet_summary &middot; {_e(report_ts)}</footer>

</div>

<script type="application/json" id="chocoDeploy-fleet-data">
{json.dumps(_agg_to_json_for_embed(agg), indent=2)}
</script>
</body>
</html>'''


def _agg_to_json_for_embed(agg):
    """Build the embedded JSON data block for the HTML report."""
    ft = agg.get("fleet_totals", {})
    ts_range = (
        agg["timestamps"][0]
        if len(agg["timestamps"]) == 1
        else f'{agg["timestamps"][0]} .. {agg["timestamps"][-1]}'
    )
    report = {
        "report_type": "fleet_summary",
        "report_generated": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "run_window": ts_range,
        "deployment_modes": agg.get("deployment_modes", []),
        "fleet_status": {
            "total_hosts": agg["total_hosts"],
            "succeeded": agg["succeeded"],
            "failed": agg["failed"],
            "retried": ft.get("retried_hosts", 0),
            "success_pct": agg["success_pct"],
            "pending_reboots": ft.get("reboot_pending", 0),
        },
    }
    # Hosts summary (without _final_events internal field)
    report["hosts"] = {}
    for hostname in sorted(agg.get("hosts", {})):
        h = agg["hosts"][hostname]
        report["hosts"][hostname] = {
            "site": h["site"], "status": h["status"], "deployment": h["deployment"],
            "runs": h["runs"], "retries": h["retries"], "errors": h["errors"],
            "reboot_pending": h["reboot_pending"],
        }
    return report


def main():
    parser = argparse.ArgumentParser(description="chocoDeploy Fleet Summary Report")
    parser.add_argument("--json-dir", default=DEFAULT_JSON_DIR,
                        help="Directory containing per-host JSONs")
    parser.add_argument("--output-dir", default=os.path.join(DEFAULT_JSON_DIR, "reports"),
                        help="Directory to write fleet summary files (default: <json-dir>/reports/)")
    parser.add_argument("--today", action="store_true",
                        help="Include only JSONs from today (UTC). Use --last-hours for local-time-friendly rolling windows.")
    parser.add_argument("--last-hours", type=int, default=None,
                        help="Include JSONs from the last N hours (rolling). Recommended for daily summaries to avoid UTC/local-time edge cases (e.g. --last-hours 24).")
    parser.add_argument("--since",
                        help="Include JSONs from this UTC timestamp onward (e.g. 20260318T010000Z)")
    parser.add_argument("--until",
                        help="Include JSONs up to this UTC timestamp (e.g. 20260318T070000Z)")
    parser.add_argument("--short-names", action="store_true",
                        help="Strip domain suffix from hostnames in output")
    parser.add_argument("--archive", action="store_true",
                        help="Move consumed per-host JSONs to an archive subdirectory after summary")
    parser.add_argument("--retain-days", type=int, default=90,
                        help="With --archive, delete archived JSONs older than N days (default: 90)")
    parser.add_argument("--include-json", action="store_true",
                        help="Also generate structured JSON report (placed in detailed/ subdirectory)")
    parser.add_argument("--include-text", action="store_true",
                        help="Also generate human-readable text report (placed in detailed/ subdirectory)")
    args = parser.parse_args()

    since = parse_timestamp(args.since) if args.since else None
    until = parse_timestamp(args.until) if args.until else None

    json_files = discover_jsons(args.json_dir, since=since, until=until, today=args.today, last_hours=args.last_hours)
    if not json_files:
        print("No matching JSON files found.", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(json_files)} JSON files across {len(set(j['hostname'] for j in json_files))} hosts")

    agg = aggregate(json_files)
    if args.short_names:
        agg = shorten_hostnames(agg)
    text_report = build_text_report(agg)
    json_report = build_json_report(agg)
    html_report = build_html_report(agg)

    os.makedirs(args.output_dir, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    html_path = os.path.join(args.output_dir, f"{ts}_chocoDeploy_fleet_summary.html")

    # Write HTML (main report, always generated)
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html_report)

    # Optionally write JSON and TXT to detailed/ subdirectory
    report_outputs = [f"HTML report: {html_path}"]
    
    if args.include_json or args.include_text:
        detailed_dir = os.path.join(args.output_dir, "detailed")
        os.makedirs(detailed_dir, exist_ok=True)
    
    if args.include_json:
        json_path = os.path.join(args.output_dir, "detailed", f"{ts}_chocoDeploy_fleet_summary.json")
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(json_report, f, indent=2)
        report_outputs.append(f"JSON report: {json_path}")
    
    if args.include_text:
        txt_path = os.path.join(args.output_dir, "detailed", f"{ts}_chocoDeploy_fleet_summary.txt")
        with open(txt_path, "w", encoding="utf-8") as f:
            f.write(text_report + "\n")
        report_outputs.append(f"Text report: {txt_path}")

    print("\n" + "\n".join(report_outputs))

    if args.archive:
        archive_dir = os.path.join(args.json_dir, "archive")
        os.makedirs(archive_dir, exist_ok=True)
        zip_name = f"{ts}_chocoDeploy_run.zip"
        zip_path = os.path.join(archive_dir, zip_name)
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for jf in json_files:
                zf.write(jf["path"], os.path.basename(jf["path"]))
        for jf in json_files:
            os.remove(jf["path"])
        print(f"Archived {len(json_files)} per-host JSONs to {zip_path}")

        cutoff = datetime.now(timezone.utc) - timedelta(days=args.retain_days)
        pruned = 0
        zip_re = re.compile(r"^(\d{8}T\d{6}Z)_chocoDeploy_run\.zip$")
        for fname in os.listdir(archive_dir):
            m = zip_re.match(fname)
            if not m:
                continue
            try:
                file_ts = parse_timestamp(m.group(1))
                if file_ts < cutoff:
                    os.remove(os.path.join(archive_dir, fname))
                    pruned += 1
            except ValueError:
                continue
        if pruned > 0:
            print(f"Pruned {pruned} archive zips older than {args.retain_days} days")


if __name__ == "__main__":
    main()
