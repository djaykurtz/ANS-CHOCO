#!/usr/bin/env python3
"""Validate the shared package catalog and optional campaign manifests."""

import argparse
import re
import sys
from pathlib import Path
import yaml

from lint_target_scope import ScopeError, campaign_inventories, inventory_hosts, lint_hosts


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "playbooks/catalogs/chocolatey_packages.yml"
DEPLOY_DEFAULTS = ROOT / "playbooks/roles/chocoDeploy/defaults/main.yml"
INTERNALIZE_SPEC = ROOT / "playbooks/roles/chocoBuild/files/internalize-spec.yml"
DEPLOY_TASKS = ROOT / "playbooks/roles/chocoDeploy/tasks"
APP_FLOOR_RE = re.compile(r"acceptable_versions\.applications\.(\w+)\.min_version")


class Validator:
    def __init__(self) -> None:
        self.errors = []
        self.warnings = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warning(self, message: str) -> None:
        self.warnings.append(message)


def load_yaml(path):
    with path.open(encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a YAML mapping")
    return data


def check_catalog(validator, catalog):
    if catalog.get("schema_version") != 1:
        validator.error("catalog schema_version must be 1")

    packages = catalog.get("packages")
    if not isinstance(packages, dict) or not packages:
        validator.error("catalog packages must be a non-empty mapping")
        return

    seen_package_ids = {}
    allowed_methods = {"community", "wrapper", "firstparty", "manual"}

    for key, entry in packages.items():
        prefix = f"packages.{key}"
        if not isinstance(entry, dict):
            validator.error(f"{prefix} must be a mapping")
            continue

        package_id = entry.get("package_id")
        if not isinstance(package_id, str) or not package_id:
            validator.error(f"{prefix}.package_id is required")
        elif package_id in seen_package_ids:
            validator.error(
                f"{prefix}.package_id duplicates {seen_package_ids[package_id]}"
            )
        else:
            seen_package_ids[package_id] = prefix

        if not entry.get("display_name"):
            validator.error(f"{prefix}.display_name is required")
        if entry.get("kind") not in {"application", "runtime"}:
            validator.error(f"{prefix}.kind must be application or runtime")
        if not entry.get("approved_version"):
            validator.error(f"{prefix}.approved_version is required")
        if entry.get("version_policy") not in {"minimum", "exact"}:
            validator.error(f"{prefix}.version_policy must be minimum or exact")

        deployment = entry.get("deployment", {})
        if not isinstance(deployment, dict):
            validator.error(f"{prefix}.deployment must be a mapping")

        acquisition = entry.get("acquisition", {})
        if not isinstance(acquisition, dict):
            validator.error(f"{prefix}.acquisition must be a mapping")
            continue
        method = acquisition.get("method")
        if method not in allowed_methods:
            validator.error(f"{prefix}.acquisition.method is invalid: {method!r}")

        mirror_versions = acquisition.get("mirror_versions")
        if not isinstance(mirror_versions, list):
            validator.error(f"{prefix}.acquisition.mirror_versions must be a list")
        elif entry.get("approved_version") not in mirror_versions:
            validator.warning(
                f"{prefix}: approved_version {entry.get('approved_version')} "
                "is not present in mirror_versions"
            )

        if method == "wrapper":
            wrapper = acquisition.get("wrapper", {})
            for required in ("base_version", "new_version", "installer_url"):
                if not wrapper.get(required):
                    validator.error(f"{prefix}.acquisition.wrapper.{required} is required")
            if not (wrapper.get("expected_sha256") or wrapper.get("checksums_url")):
                validator.error(
                    f"{prefix}.acquisition.wrapper needs expected_sha256 or checksums_url"
                )

        community_id = acquisition.get("community_package_id")
        if method in {"community", "wrapper"} and not community_id:
            validator.error(f"{prefix}.acquisition.community_package_id is required")


def deploy_floor(key, package, deploy, deploy_apps):
    """Return (floor, location) that chocoDeploy enforces for a catalog package."""
    floors = deploy.get("acceptable_versions", {})
    if package.get("kind") == "runtime":
        runtime = floors.get("runtimes", {}).get(package.get("runtime_id"), {})
        track = package.get("track")
        where = f"runtimes.{package.get('runtime_id')}" + (f".channels[{track}]" if track else "")
        value = (runtime.get("channels", {}).get(str(track), {}) if track else runtime).get("min_version")
        return value, where
    app = deploy_apps.get(key) or {}
    task_file = DEPLOY_TASKS / str(app.get("task_file", ""))
    # The app's task file names the floor it enforces, so read the key from there.
    match = APP_FLOOR_RE.search(task_file.read_text(encoding="utf-8")) if task_file.is_file() else None
    if not match:
        return None, f"no acceptable_versions.applications key in {task_file.name or '(no task_file)'}"
    return floors.get("applications", {}).get(match.group(1), {}).get("min_version"), f"applications.{match.group(1)}"


def check_floor_alignment(validator, catalog, deploy, deploy_apps):
    """Catalog approved_version must equal the floor chocoDeploy enforces."""
    for key, package in catalog.get("packages", {}).items():
        if not isinstance(package, dict) or not package.get("deployment", {}).get("enabled", True):
            continue
        floor, where = deploy_floor(key, package, deploy, deploy_apps)
        approved = str(package.get("approved_version", ""))
        if floor is None:
            validator.error(f"{key}: cannot find its chocoDeploy floor ({where})")
        elif str(floor) != approved:
            validator.error(f"{key}: approved_version {approved} differs from chocoDeploy floor "
                            f"acceptable_versions.{where} = {floor}; promote both together")


def compare_existing_sources(validator, catalog):
    deploy = load_yaml(DEPLOY_DEFAULTS)
    internalize = load_yaml(INTERNALIZE_SPEC)

    deploy_apps = {
        item.get("key"): item
        for item in deploy.get("choco_managed_apps", [])
        if isinstance(item, dict) and item.get("key")
    }
    catalog_packages = catalog.get("packages", {})

    for key, app in deploy_apps.items():
        if key not in catalog_packages:
            validator.error(f"managed app {key!r} is missing from shared catalog")

    for key in catalog_packages:
        if key not in deploy_apps and catalog_packages[key].get("kind") == "application":
            validator.warning(f"catalog application {key!r} is not in choco_managed_apps")

    check_floor_alignment(validator, catalog, deploy, deploy_apps)

    staged = {}
    for item in internalize.get("choco_internalize_packages", []):
        if isinstance(item, dict) and item.get("id") and item.get("version"):
            staged.setdefault(item["id"], set()).add(str(item["version"]))

    for key, entry in catalog_packages.items():
        acquisition = entry.get("acquisition", {})
        package_id = entry.get("package_id")
        expected = {str(v) for v in acquisition.get("mirror_versions", [])}
        wrapper = acquisition.get("wrapper", {})
        if wrapper.get("new_version"):
            expected.discard(str(wrapper["new_version"]))
        actual = staged.get(package_id, set())
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        if missing:
            validator.warning(
                f"{key}: mirror_versions missing from internalize-spec.yml: {', '.join(missing)}"
            )
        if extra:
            validator.warning(
                f"{key}: internalize-spec.yml has versions absent from shared catalog: {', '.join(extra)}"
            )


def check_campaign(validator, path, catalog):
    try:
        campaign = load_yaml(path)
    except Exception as exc:  # pragma: no cover - command-line diagnostic
        validator.error(f"{path}: {exc}")
        return

    if not campaign.get("campaign_id"):
        validator.error(f"{path}: campaign_id is required")
    phases = campaign.get("phases")
    if not isinstance(phases, list) or not phases:
        validator.error(f"{path}: phases must be a non-empty list")
        return

    known_ids = set()
    for entry in catalog.get("packages", {}).values():
        if not isinstance(entry, dict):
            continue
        if entry.get("package_id"):
            known_ids.add(entry["package_id"])
        known_ids.update(entry.get("aliases", []))
    phase_ids = set()
    run_ids = set()

    for phase_index, phase in enumerate(phases):
        prefix = f"{path}: phases[{phase_index}]"
        if not isinstance(phase, dict):
            validator.error(f"{prefix} must be a mapping")
            continue
        phase_id = phase.get("phase_id")
        if not phase_id:
            validator.error(f"{prefix}.phase_id is required")
        elif phase_id in phase_ids:
            validator.error(f"{prefix}.phase_id duplicates {phase_id}")
        else:
            phase_ids.add(phase_id)

        runs = phase.get("runs")
        if not isinstance(runs, list) or not runs:
            validator.error(f"{prefix}.runs must be a non-empty list")
            continue

        for run_index, run in enumerate(runs):
            run_prefix = f"{prefix}.runs[{run_index}]"
            if not isinstance(run, dict):
                validator.error(f"{run_prefix} must be a mapping")
                continue
            run_id = run.get("run_id")
            if run.get("action") != "fleet_summary" and not run.get("playbook"):
                validator.error(f"{run_prefix}.playbook is required")
            if not run_id:
                validator.error(f"{run_prefix}.run_id is required")
            elif run_id in run_ids:
                validator.error(f"{run_prefix}.run_id duplicates {run_id}")
            else:
                run_ids.add(run_id)

            reboot = run.get("reboot_policy", campaign.get("reboot_policy", "never"))
            if reboot not in {"never", "if_needed", "always"}:
                validator.error(f"{run_prefix}.reboot_policy is invalid: {reboot!r}")
            if reboot != "never":
                validator.warning(f"{run_prefix}: reboot policy is {reboot}; confirm host authorization")

            target = run.get("target_software", [])
            remove = run.get("remove_software", [])
            if target is None or remove is None:
                validator.error(
                    f"{run_prefix}: target_software and remove_software must be explicit lists"
                )
                continue
            if not isinstance(target, list) or not isinstance(remove, list):
                validator.error(f"{run_prefix}: target_software/remove_software must be lists")
                continue

            target_ids = {item.get("key") if isinstance(item, dict) else item for item in target}
            remove_ids = {item.get("key") if isinstance(item, dict) else item for item in remove}
            overlap = sorted(target_ids & remove_ids)
            if overlap:
                validator.error(
                    f"{run_prefix}: package appears in both target_software and remove_software: {overlap}"
                )

            for field, values in (("target_software", target), ("remove_software", remove)):
                for item in values:
                    value = item.get("key") if isinstance(item, dict) else item
                    if value not in known_ids and value != "package-id":
                        validator.warning(f"{run_prefix}.{field}: {value!r} is not in shared catalog; verify ad-hoc intent")

            mode = run.get("mode")
            if remove and not target and mode == "choco_selective":
                validator.error(
                    f"{run_prefix}: removal-only run cannot use choco_selective; use choco_update"
                )
            if remove and not target and mode == "choco_update" and run.get("reboot_policy", campaign.get("reboot_policy", "never")) != "never":
                validator.error(f"{run_prefix}: removal-only runs must use reboot_policy=never")


def check_target_scope(validator, campaign_path, ad_export, policy):
    """Advisory only. The protected-OU check belongs to csv_to_inventory.py."""
    if not ad_export:
        return
    try:
        sources = [(str(path), inventory_hosts(path)) for path in campaign_inventories(campaign_path)]
        result = lint_hosts(sources, ad_export, policy)
    except (ScopeError, OSError) as exc:
        validator.warning(f"{campaign_path}: target scope not checked: {exc}")
        return
    for item in result["protected_hosts"]:
        validator.warning(
            f"{campaign_path}: protected target {item['host']} in "
            f"{item['matching_ou']} ({item['distinguishedName']})"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--campaign", type=Path)
    parser.add_argument("--ad-export", type=Path,
                        help="optional AD export; warns about protected hosts, never blocks")
    parser.add_argument("--target-policy", type=Path,
                        default=ROOT / "playbooks/policies/target_exclusions.yml")
    args = parser.parse_args()

    validator = Validator()
    try:
        catalog = load_yaml(args.catalog)
    except Exception as exc:
        print(f"ERROR: {args.catalog}: {exc}")
        return 2

    check_catalog(validator, catalog)
    compare_existing_sources(validator, catalog)
    if args.campaign:
        check_campaign(validator, args.campaign, catalog)
        check_target_scope(validator, args.campaign, args.ad_export, args.target_policy)

    for warning in validator.warnings:
        print(f"WARN: {warning}")
    for error in validator.errors:
        print(f"ERROR: {error}")

    print(
        f"\nCatalog validation: {'PASS' if not validator.errors else 'FAIL'} "
        f"({len(validator.errors)} errors, {len(validator.warnings)} warnings)"
    )
    return 1 if validator.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
