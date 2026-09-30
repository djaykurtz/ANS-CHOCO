#!/usr/bin/env python3
"""Fail-closed validation for hosts beneath protected Active Directory OUs."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_POLICY = ROOT / "playbooks/policies/target_exclusions.yml"
DEFAULT_DOMAIN = "corp.example.com"
HOST_KEYS = {"host", "hostname", "computer", "computername", "devicename", "target", "cn"}


class ScopeError(ValueError):
    """The scope check could not establish safe evidence."""


def load_yaml(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return yaml.safe_load(handle)
    except OSError as exc:
        raise ScopeError(f"cannot read {path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise ScopeError(f"invalid YAML in {path}: {exc}") from exc


def normalize_dn(value: str) -> str:
    return ",".join(part.strip().lower() for part in value.strip().split(","))


def normalize_host(value: str) -> str:
    value = str(value).strip().strip('"\'').rstrip(".").lower()
    if "\\" in value:
        value = value.rsplit("\\", 1)[-1]
    return value


def host_aliases(value: str, domain: str = DEFAULT_DOMAIN) -> set[str]:
    host = normalize_host(value)
    if not host:
        return set()
    short = host.split(".", 1)[0]
    aliases = {host, short}
    if "." not in host:
        aliases.add(f"{host}.{domain.lower()}")
    return aliases


def load_policy(path: Path) -> dict[str, Any]:
    policy = load_yaml(path)
    if not isinstance(policy, dict) or policy.get("schema_version") != 1:
        raise ScopeError(f"{path} must contain target exclusion schema_version 1")
    ous = policy.get("protected_ous")
    if policy.get("ad_export_mode") != "protected_only" or not isinstance(ous, list) or not ous:
        raise ScopeError(f"{path} must define protected_only and protected_ous")
    for entry in ous:
        if not isinstance(entry, dict) or not entry.get("id") or not entry.get("distinguished_name"):
            raise ScopeError(f"{path} contains an invalid protected OU entry")
    return policy


def _records_from_data(data: Any) -> list[dict[str, Any]]:
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    if isinstance(data, dict):
        if any(key in data for key in ("cn", "CN", "distinguishedName", "DistinguishedName")):
            return [data]
        for key in ("objects", "value", "results"):
            if key in data:
                return _records_from_data(data[key])
    raise ScopeError("AD export must be a JSON/YAML object or list of objects")


def load_ad_objects(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        raise ScopeError(f"AD export is required and was not found: {path}")
    try:
        if path.suffix.lower() == ".csv":
            with path.open(newline="", encoding="utf-8-sig") as handle:
                raw = list(csv.DictReader(handle))
        else:
            raw = _records_from_data(load_yaml(path) if path.suffix.lower() in {".yml", ".yaml"}
                                     else json.loads(path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, csv.Error) as exc:
        raise ScopeError(f"cannot read AD export {path}: {exc}") from exc

    objects = []
    for index, item in enumerate(raw):
        lowered = {str(key).lower(): value for key, value in item.items()}
        cn = lowered.get("cn")
        dn = lowered.get("distinguishedname") or lowered.get("distinguished_name") or lowered.get("dn")
        if not cn or not dn:
            raise ScopeError(f"AD export record {index + 1} must contain cn and distinguishedName")
        objects.append({"cn": str(cn), "distinguishedName": str(dn)})
    if not objects:
        raise ScopeError(f"AD export contains no objects: {path}")
    return objects


def _inventory_hosts(data: Any, under_hosts: bool = False) -> list[str]:
    hosts: list[str] = []
    if isinstance(data, dict):
        for key, value in data.items():
            if under_hosts:
                hosts.append(str(key))
            elif str(key).lower() == "hosts":
                hosts.extend(_inventory_hosts(value, True))
            else:
                hosts.extend(_inventory_hosts(value, False))
    elif isinstance(data, list) and not under_hosts:
        for item in data:
            hosts.extend(_inventory_hosts(item, False))
    return hosts


def inventory_hosts(path: Path) -> list[str]:
    hosts = _inventory_hosts(load_yaml(path))
    if not hosts:
        raise ScopeError(f"no inventory hosts found in {path}")
    return hosts


def _target_values(data: Any) -> list[str]:
    if isinstance(data, str):
        return [data]
    if isinstance(data, list):
        values: list[str] = []
        for item in data:
            values.extend(_target_values(item))
        return values
    if isinstance(data, dict):
        values = []
        for key, item in data.items():
            if str(key).lower() in HOST_KEYS:
                values.extend(_target_values(item))
            elif str(key).lower() in {"hosts", "children", "all"}:
                values.extend(_inventory_hosts({key: item}))
        return values
    return []


def target_file_hosts(path: Path) -> list[str]:
    if not path.is_file():
        raise ScopeError(f"target list was not found: {path}")
    suffix = path.suffix.lower()
    if suffix == ".csv":
        with path.open(newline="", encoding="utf-8-sig") as handle:
            rows = list(csv.DictReader(handle))
        hosts = []
        for row in rows:
            for key, value in row.items():
                if str(key).lower() in HOST_KEYS and value:
                    hosts.append(str(value))
                    break
    elif suffix in {".json", ".yml", ".yaml"}:
        data = (json.loads(path.read_text(encoding="utf-8")) if suffix == ".json" else load_yaml(path))
        hosts = _target_values(data)
        if not hosts:
            hosts = _inventory_hosts(data)
    else:
        hosts = []
        for line in path.read_text(encoding="utf-8").splitlines():
            value = line.strip().split("#", 1)[0].strip().lstrip("-").strip()
            if value and value.lower() not in HOST_KEYS:
                hosts.extend(part.strip() for part in value.split(",") if part.strip())
    if not hosts:
        raise ScopeError(f"no target hosts found in {path}")
    return hosts


def campaign_inventories(path: Path) -> list[Path]:
    campaign = load_yaml(path)
    if not isinstance(campaign, dict):
        raise ScopeError(f"campaign must be a YAML mapping: {path}")
    paths = []
    for phase in campaign.get("phases", []):
        for run in phase.get("runs", []) if isinstance(phase, dict) else []:
            if isinstance(run, dict) and run.get("inventory"):
                paths.append(Path(str(run["inventory"])))
    if not paths:
        raise ScopeError(f"campaign has no inventory-backed runs: {path}")
    return paths


def lint_hosts(host_sources: list[tuple[str, list[str]]], ad_export: Path,
               policy_path: Path = DEFAULT_POLICY) -> dict[str, Any]:
    policy = load_policy(policy_path)
    objects = load_ad_objects(ad_export)
    protected_ous = [
        (entry["id"], normalize_dn(entry["distinguished_name"]))
        for entry in policy["protected_ous"]
    ]
    domain = str(policy.get("domain", DEFAULT_DOMAIN))
    blocked = []
    seen = set()
    for source, hosts in host_sources:
        for host in hosts:
            aliases = host_aliases(host, domain)
            for obj in objects:
                if not aliases.intersection(host_aliases(obj["cn"], domain)):
                    continue
                object_dn = normalize_dn(obj["distinguishedName"])
                for ou_id, ou_dn in protected_ous:
                    if object_dn == ou_dn or object_dn.endswith("," + ou_dn):
                        key = (source, normalize_host(host), ou_id, object_dn)
                        if key not in seen:
                            blocked.append({
                                "source": source,
                                "host": host,
                                "matching_ou": ou_id,
                                "distinguishedName": obj["distinguishedName"],
                            })
                            seen.add(key)
    return {
        "policy_id": policy["policy_id"],
        "policy_file": str(policy_path),
        "ad_export": str(ad_export),
        "sources": [{"source": source, "host_count": len(hosts)} for source, hosts in host_sources],
        "protected_hosts": blocked,
        "status": "FAIL" if blocked else "PASS",
    }


def print_result(result: dict[str, Any]) -> None:
    print(f"Target scope validation: {result['status']}")
    print(f"  Policy: {result['policy_id']}")
    print(f"  AD evidence: {result['ad_export']}")
    print(f"  Hosts checked: {sum(item['host_count'] for item in result['sources'])}")
    if result["protected_hosts"]:
        print("Protected targets must be removed from the supplied list before execution:")
        for item in result["protected_hosts"]:
            print(f"  BLOCKED {item['host']} -> {item['matching_ou']} ({item['distinguishedName']})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--ad-export", type=Path, required=True,
                        help="JSON, YAML, or CSV exported from the protected AD searches")
    parser.add_argument("--inventory", type=Path, action="append", default=[])
    parser.add_argument("--targets", type=Path, action="append", default=[])
    parser.add_argument("--campaign", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()

    try:
        paths: list[tuple[str, list[str]]] = []
        for path in args.inventory:
            paths.append((str(path), inventory_hosts(path)))
        for path in args.targets:
            paths.append((str(path), target_file_hosts(path)))
        if args.campaign:
            for path in campaign_inventories(args.campaign):
                paths.append((str(path), inventory_hosts(path)))
        if not paths:
            raise ScopeError("provide --inventory, --targets, or --campaign")
        result = lint_hosts(paths, args.ad_export, args.policy)
    except (ScopeError, OSError, yaml.YAMLError, json.JSONDecodeError) as exc:
        print(f"Target scope validation: ERROR\n  {exc}", file=sys.stderr)
        return 2

    print_result(result)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"  Report: {args.report}")
    return 1 if result["protected_hosts"] else 0


if __name__ == "__main__":
    raise SystemExit(main())