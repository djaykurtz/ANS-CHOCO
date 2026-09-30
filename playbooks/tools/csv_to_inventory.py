#!/usr/bin/env python3.12
"""Build campaign inventories from a CSV host list, with a protected-OU process check.

This is the one place the protected-OU rule is applied: when a received host list
becomes an inventory. Hosts found under a protected OU (playbooks/policies/
target_exclusions.yml) are left out of every generated inventory and reported.
Playbook runs are never checked or blocked.

Per host it also records:
  - AD location, when the AD export contains the host (see
    export_protected_ad_objects.ps1 -HostListPath)
  - DNS resolution and WinRM (TCP 5985) reachability from this control node

Writes to $CHOCO_FLEET_DATA_ROOT/incoming/<campaign-id>/ (root defaults to /opt/ansible):
  inv-<name>.yml           every host not in a protected OU
  inv-<name>-ready.yml     the same, limited to hosts answering on WinRM 5985
  <name>-check.json        per-host results and the evidence used
  <name>-excluded.txt      protected hosts left out (only when there are any)
  group_vars/basic_hosts.yml  WinRM connection vars, if not already present

Example:
  python3.12 playbooks/tools/csv_to_inventory.py /opt/ansible/incoming/campaign-001/campaign_001.csv \\
    --campaign-id campaign-001 --name all \\
    --ad-export /opt/ansible/incoming/campaign-001/ad-protected-objects.json
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import socket
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_target_scope import (DEFAULT_DOMAIN, DEFAULT_POLICY, ROOT, ScopeError,  # noqa: E402
                               host_aliases, load_ad_objects, load_policy, normalize_dn,
                               normalize_host)

HOST_COLUMNS = ("devicename", "hostname", "host", "computername", "computer", "name",
                "target", "cn", "fqdn")
CONNECTION_VARS = ROOT / "inventory" / "TEST" / "group_vars" / "basic_hosts.yml"


def read_hosts(path: Path, column: str | None) -> list[str]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        fields = {name.lower().strip(): name for name in (reader.fieldnames or [])}
        key = fields.get(column.lower()) if column else next(
            (fields[c] for c in HOST_COLUMNS if c in fields), None)
        if not key:
            raise ScopeError(f"no host column in {path}; columns: {', '.join(fields.values())}"
                             " (use --column)")
        hosts, seen = [], set()
        for row in reader:
            host = normalize_host(row.get(key) or "")
            if host and host not in seen:
                seen.add(host)
                hosts.append(host)
    if not hosts:
        raise ScopeError(f"no hosts found in column {key!r} of {path}")
    return hosts


def fqdn(host: str, domain: str) -> str:
    return host if "." in host else f"{host}.{domain}"


def ad_lookup(hosts: list[str], ad_export: Path, policy_path: Path, domain: str) -> dict:
    policy = load_policy(policy_path)
    objects = load_ad_objects(ad_export)
    protected = [(e["id"], normalize_dn(e["distinguished_name"])) for e in policy["protected_ous"]]
    by_alias: dict[str, str] = {}
    for obj in objects:
        for alias in host_aliases(obj["cn"], domain):
            by_alias.setdefault(alias, obj["distinguishedName"])
    result = {}
    for host in hosts:
        dn = next((by_alias[a] for a in host_aliases(host, domain) if a in by_alias), None)
        ou = next((pid for pid, pdn in protected
                   if dn and (normalize_dn(dn) == pdn or normalize_dn(dn).endswith("," + pdn))), None)
        result[host] = {"distinguishedName": dn, "protected_ou": ou}
    return result


def probe(host: str, timeout: float) -> dict:
    try:
        addrs = sorted({info[4][0] for info in socket.getaddrinfo(host, 5985, type=socket.SOCK_STREAM)})
    except OSError:
        return {"dns": False, "winrm_5985": False, "addresses": []}
    try:
        socket.create_connection((host, 5985), timeout=timeout).close()
        winrm = True
    except OSError:
        winrm = False
    return {"dns": True, "winrm_5985": winrm, "addresses": addrs}


def write_inventory(path: Path, hosts: list[str], title: str, source: Path, force: bool) -> None:
    if path.exists() and not force:
        raise FileExistsError(f"{path} exists; use --force to overwrite")
    lines = ["---", f"# {title}", f"# Generated {datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ} "
             f"by playbooks/tools/csv_to_inventory.py from {source}",
             "# Operational artifact. Keep outside the repository.",
             "all:", "  children:", "    basic_hosts:", "      hosts:"]
    lines += [f"        {h}:" for h in hosts] or ["        {}"]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv", type=Path, help="received host list (CSV with a host column)")
    parser.add_argument("--campaign-id", required=True)
    parser.add_argument("--name", default="all", help="inventory name stem (default: all)")
    parser.add_argument("--ad-export", type=Path, required=True,
                        help="JSON from export_protected_ad_objects.ps1")
    parser.add_argument("--column", help="host column name (default: auto-detect)")
    parser.add_argument("--outdir", type=Path,
                        help="default: $CHOCO_FLEET_DATA_ROOT/incoming/<campaign-id>")
    parser.add_argument("--target-policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--no-probe", action="store_true", help="skip DNS/WinRM reachability checks")
    parser.add_argument("--timeout", type=float, default=3.0, help="WinRM connect timeout (s)")
    parser.add_argument("--workers", type=int, default=64)
    parser.add_argument("--force", action="store_true", help="overwrite existing inventories")
    args = parser.parse_args()

    domain = DEFAULT_DOMAIN
    outdir = args.outdir or Path(os.environ.get("CHOCO_FLEET_DATA_ROOT") or "/opt/ansible") / "incoming" / args.campaign_id
    try:
        hosts = [fqdn(h, domain) for h in read_hosts(args.csv, args.column)]
        ad = ad_lookup(hosts, args.ad_export, args.target_policy, domain)
    except ScopeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    excluded = [h for h in hosts if ad[h]["protected_ou"]]
    eligible = [h for h in hosts if not ad[h]["protected_ou"]]

    # Protected hosts are never contacted, not even for a port probe.
    reach = {}
    if not args.no_probe:
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            reach = dict(zip(eligible, pool.map(lambda h: probe(h, args.timeout), eligible)))
    ready = [h for h in eligible if reach.get(h, {}).get("winrm_5985")]

    outdir.mkdir(parents=True, exist_ok=True)
    stem = f"inv-{args.campaign_id}-{args.name}"
    try:
        write_inventory(outdir / f"{stem}.yml", eligible,
                        f"{args.campaign_id} {args.name}: hosts outside protected OUs", args.csv, args.force)
        if not args.no_probe:
            write_inventory(outdir / f"{stem}-ready.yml", ready,
                            f"{args.campaign_id} {args.name}: outside protected OUs and answering WinRM 5985",
                            args.csv, args.force)
    except FileExistsError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    gv = outdir / "group_vars" / "basic_hosts.yml"
    if not gv.exists():
        gv.parent.mkdir(exist_ok=True)
        shutil.copyfile(CONNECTION_VARS, gv)

    report = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_csv": str(args.csv),
        "ad_export": str(args.ad_export),
        "ad_export_modified": datetime.fromtimestamp(args.ad_export.stat().st_mtime, timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "counts": {"hosts": len(hosts), "excluded_protected": len(excluded), "inventory": len(eligible),
                   "ready": len(ready) if not args.no_probe else None,
                   "not_in_ad_export": sum(1 for h in hosts if not ad[h]["distinguishedName"])},
        "hosts": {h: {**ad[h], **reach.get(h, {})} for h in hosts},
    }
    (outdir / f"{args.campaign_id}-{args.name}-check.json").write_text(json.dumps(report, indent=2) + "\n")
    if excluded:
        (outdir / f"{args.campaign_id}-{args.name}-excluded.txt").write_text(
            "".join(f"{h}\t{ad[h]['protected_ou']}\t{ad[h]['distinguishedName']}\n" for h in excluded))

    c = report["counts"]
    print(f"{c['hosts']} hosts read from {args.csv}")
    for h in excluded:
        print(f"  WARN excluded {h}: protected OU {ad[h]['protected_ou']} ({ad[h]['distinguishedName']})")
    if not args.no_probe:
        for h in eligible:
            if not reach[h]["dns"]:
                print(f"  WARN {h}: DNS does not resolve")
            elif not reach[h]["winrm_5985"]:
                print(f"  WARN {h}: WinRM 5985 not reachable")
    print(f"{c['inventory']} hosts -> {outdir / (stem + '.yml')}")
    if not args.no_probe:
        print(f"{c['ready']} hosts -> {outdir / (stem + '-ready.yml')}")
    print(f"{c['excluded_protected']} protected hosts excluded; "
          f"{c['not_in_ad_export']} hosts had no entry in the AD export")
    print(f"report: {outdir / (args.campaign_id + '-' + args.name + '-check.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
