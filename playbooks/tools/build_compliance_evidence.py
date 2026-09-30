#!/usr/bin/env python3.12
"""Build chocoDeploy-compatible compliance evidence from read-only host state."""

import argparse
import csv
import json
import re
from datetime import datetime, timezone
from pathlib import Path

import yaml

APP_MAP = {
    "greenshot": ("greenshot", "greenshot"),
    "pycharm": ("pycharm", "pycharm"),
    "putty": ("putty.install", "putty"),
    "visual_studio_code": ("vscode.install", "visual studio code|vs code"),
    "vim": ("vim", r"^vim(?:\s|$)"),
    "powershell": ("powershell-core", r"powershell\s+7"),
}
OUT_OF_SCOPE = {"jre", "powertoys"}


def version_tuple(value):
    nums = re.findall(r"\d+", str(value or ""))
    return tuple(int(x) for x in nums) if nums else ()


def at_least(actual, required):
    a, r = version_tuple(actual), version_tuple(required)
    return bool(a and r and a >= r)


def short(host):
    return host.lower().split(".", 1)[0]


def inventory_hosts(path):
    hosts = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\s{8}([A-Za-z0-9][A-Za-z0-9_.-]*):", line)
        if match:
            hosts.append(match.group(1))
    if not hosts:
        raise ValueError("inventory has no hosts in the supported all/children/group/hosts layout")
    return hosts


def load_requirements(csv_paths):
    requirements = {}
    for csv_path in csv_paths:
        with open(csv_path, newline="", encoding="utf-8-sig") as handle:
            for row in csv.DictReader(handle):
                host = short(row["DeviceName"].strip())
                software = row["SoftwareName"].strip().lower()
                version = row.get("CurrentSoftwareVersion", "").strip()
                key = (host, software, version)
                requirements[key] = {"host": host, "software": software, "source_version": version}
    return list(requirements.values())


def load_floors(defaults_path):
    data = yaml.safe_load(Path(defaults_path).read_text())
    acceptable = data["acceptable_versions"]
    apps = acceptable["applications"]
    runtimes = acceptable["runtimes"]
    floors = {
        "greenshot": apps["greenshot"]["min_version"],
        "pycharm": apps["pycharm"]["min_version"],
        "putty.install": apps["putty_install"]["min_version"],
        "vscode.install": apps["vscode_install"]["min_version"],
        "vim": apps["vim"]["min_version"],
        "powershell-core": runtimes["powershell_core"]["min_version"],
        "netfx-4.8.1": runtimes["dotnet_framework"]["min_version"],
    }
    dotnet = {}
    for track, item in runtimes["dotnet_runtime"].get("channels", {}).items():
        dotnet[track] = {
            "runtime": item["min_version"],
            "aspnetruntime": item["min_version"],
        }
    return floors, dotnet, runtimes["dotnet_framework"]["min_release_dword"]


def registry_version(programs, pattern):
    rx = re.compile(pattern, re.IGNORECASE)
    matches = [p.get("display_version", "") for p in programs if rx.search(p.get("display_name", ""))]
    return max(matches, key=version_tuple) if matches else ""


def dotnet_version(runtimes, family, track):
    prefix = {"runtime": "Microsoft.NETCore.App", "aspnetruntime": "Microsoft.AspNetCore.App"}[family]
    versions = []
    rx = re.compile(r"^" + re.escape(prefix) + r"\s+([0-9]+\.[0-9]+\.[0-9]+)", re.IGNORECASE)
    for line in runtimes:
        match = rx.search(line)
        if match and match.group(1).startswith(track + "."):
            versions.append(match.group(1))
    return max(versions, key=version_tuple) if versions else ""


def add_result(data, software, required, actual, source, note=""):
    if actual and at_least(actual, required):
        data["events"].append({"action": "NoChange", "software": software, "previous_version": actual, "new_version": actual, "source": source, "notes": note or "Live compliance check passed"})
    else:
        data["errors"].append({"software": software, "operation": "compliance_check", "message": "FATAL compliance failure: expected >= {}; observed {}".format(required, actual or "not detected")})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--csv", action="append", required=True)
    parser.add_argument("--defaults", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    floors, dotnet_floors, fx_release = load_floors(args.defaults)
    requirements = load_requirements(args.csv)
    by_host = {}
    for requirement in requirements:
        by_host.setdefault(requirement["host"], []).append(requirement)

    try:
        hosts = inventory_hosts(args.inventory)
    except ValueError as exc:
        parser.error(str(exc))

    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    written = 0

    for fqdn in hosts:
        host = short(fqdn)
        state_path = Path(args.state_dir) / (fqdn + ".json")
        run = {
            "report_time": timestamp,
            "system": fqdn,
            "deployment": "campaign_compliance_audit",
            "inventory_source": args.inventory,
            "pending_reboot": False,
            "pending_reboot_actionable": False,
            "pending_reboot_reasons": [],
            "summary": {"converted": 0, "installed": 0, "upgraded": 0, "compliant": 0, "removed": 0, "errors": 0},
            "events": [],
            "errors": [],
            "advisories": {},
            "diagnostics": {"target_software": "campaign-derived", "detected_software": "live-state", "processing_software": "live-state", "target_runtimes": "campaign-derived", "ansible_command": "read-only compliance evidence collection"},
        }
        if not state_path.exists():
            run["errors"].append({"software": "system", "operation": "winrm", "message": "FATAL evidence failure: no target-side state collected; host unavailable during evidence collection"})
        else:
            envelope = json.loads(state_path.read_text())
            state = envelope.get("state", {})
            if not envelope.get("reachable", False):
                run["errors"].append({"software": "system", "operation": "winrm", "message": "FATAL evidence failure: target state collection failed"})
            raw_packages = state.get("packages", {})
            if isinstance(raw_packages, list):
                packages = {
                    str(item.get("package", "")).lower(): str(item.get("version", ""))
                    for item in raw_packages if item.get("package")
                }
            else:
                packages = {str(k).lower(): str(v) for k, v in raw_packages.items()}
            programs = state.get("programs", [])
            runtimes = state.get("dotnet_runtimes", [])
            run["pending_reboot_reasons"] = state.get("pending_reboot_reasons", [])
            run["pending_reboot"] = bool(run["pending_reboot_reasons"])
            for req in by_host.get(host, []):
                sw = req["software"]
                if sw in OUT_OF_SCOPE:
                    continue
                if sw in APP_MAP:
                    package, pattern = APP_MAP[sw]
                    actual = packages.get(package, "") or registry_version(programs, pattern)
                    add_result(run, package, floors[package], actual, "chocolatey" if package in packages else "registry", "Campaign target {} live-state check".format(sw))
                elif sw == ".net_framework":
                    release = state.get("netfx_release", 0)
                    if int(release or 0) >= int(fx_release):
                        run["events"].append({"action": "NoChange", "software": "netfx-4.8.1", "previous_version": state.get("netfx_version", ""), "new_version": state.get("netfx_version", ""), "source": "registry", "notes": "Framework release DWORD meets campaign floor"})
                    else:
                        run["errors"].append({"software": "netfx-4.8.1", "operation": "compliance_check", "message": "FATAL compliance failure: expected release >= {}; observed {}".format(fx_release, release or 0)})
                elif sw in (".net", "asp.net_core"):
                    parsed = version_tuple(req["source_version"])
                    track = "{}.{}".format(parsed[0], parsed[1]) if len(parsed) >= 2 else ""
                    family = "aspnetruntime" if sw == "asp.net_core" else "runtime"
                    package = "dotnet-{}-{}".format(track, family)
                    required = dotnet_floors.get(track, {}).get(family, "")
                    actual = dotnet_version(runtimes, family, track)
                    if required:
                        add_result(run, package, required, actual, "dotnet-list-runtimes", "Campaign target {} track {} live-state check".format(sw, track))
        run["summary"]["compliant"] = sum(1 for e in run["events"] if e.get("action") == "NoChange")
        run["summary"]["errors"] = len(run["errors"])
        if run["pending_reboot_reasons"]:
            run["advisories"]["reboot"] = run["pending_reboot_reasons"]
        (output / (timestamp + "_" + fqdn + "_chocoDeploy.json")).write_text(json.dumps(run, indent=2) + "\n")
        written += 1
    print("wrote {} compliance evidence JSON files".format(written))


if __name__ == "__main__":
    main()
