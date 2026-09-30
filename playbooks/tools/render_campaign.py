#!/usr/bin/env python3
"""Render explicit ansible commands from a campaign manifest.

This tool only prints commands. It never invokes Ansible.
"""

import argparse
import json
import shlex
import sys
from pathlib import Path

import yaml

from lint_target_scope import ScopeError, campaign_inventories, inventory_hosts, lint_hosts


ROOT = Path(__file__).resolve().parents[2]
VAULT = "vault/.vault_key.txt"


def shell_json(value):
    return shlex.quote(json.dumps(value, separators=(",", ":")))


def render_run(campaign, phase, run):
    run_id = run.get("run_id", "unnamed-run")
    status = run.get("status", "planned")
    if status in {"blocked", "complete", "cancelled"}:
        print("# {} / {} - skipped because status={}".format(phase.get("phase_id"), run_id, status))
        print()
        return
    if run.get("action") == "fleet_summary":
        print("# {} / {}".format(phase.get("phase_id"), run_id))
        print(run.get("status_command", "python3.12 playbooks/roles/chocoDeploy/files/fleet_summary.py --last-hours 24 --short-names"))
        print()
        return

    playbook = run.get("playbook")
    inventory = run.get("inventory")
    if not playbook or not inventory:
        raise ValueError("{} is missing playbook or inventory".format(run_id))

    variables = {}
    is_deploy = playbook == "playbooks/chocoDeploy.yml"
    if is_deploy and run.get("mode"):
        variables["deployment"] = run["mode"]
    if is_deploy and "target_software" in run:
        variables["targetSoftware"] = run["target_software"]
    if is_deploy and "remove_software" in run:
        variables["removeSoftware"] = run["remove_software"]
    if is_deploy and "target_runtimes" in run:
        variables["targetRuntimes"] = run["target_runtimes"]

    reboot = run.get("reboot_policy", campaign.get("reboot_policy", "never"))
    if is_deploy:
        variables["choco_deploy_reboot"] = reboot

    # Built as a list so the line continuations cannot be malformed. Every
    # supported playbook enforces the target-scope preflight, so the AD export
    # is passed for all of them, not just chocoDeploy.
    args = [
        "ansible-playbook {}".format(playbook),
        "-i {}".format(inventory),
        "--vault-password-file={}".format(VAULT),
        "-l {}".format(run.get("limit", "basic_hosts")),
    ]
    for key in ("deployment", "targetSoftware", "removeSoftware", "targetRuntimes"):
        if key in variables:
            args.append("-e {}".format(shell_json({key: variables[key]})))
    if is_deploy:
        args.append('-e "choco_deploy_reboot={}"'.format(reboot))
    if run.get("skip_tags"):
        args.append("--skip-tags {}".format(",".join(run["skip_tags"])))
    if run.get("forks"):
        args.append("-f {}".format(run["forks"]))

    print("# {} / {}".format(phase.get("phase_id"), run_id))
    print(" \\\n  ".join(args))
    print()


def warn_target_scope(campaign_path, ad_export, policy):
    """Advisory only. The protected-OU check belongs to csv_to_inventory.py."""
    if not ad_export:
        return
    try:
        sources = [(str(path), inventory_hosts(path)) for path in campaign_inventories(campaign_path)]
        result = lint_hosts(sources, ad_export, policy)
    except (ScopeError, OSError) as exc:
        print(f"WARN: target scope not checked: {exc}", file=sys.stderr)
        return
    for item in result["protected_hosts"]:
        print(f"WARN: {item['host']} is in protected OU {item['matching_ou']} ({item['source']})",
              file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign", type=Path)
    parser.add_argument("--phase")
    parser.add_argument("--ad-export", type=Path,
                        help="optional AD export; warns about protected hosts, never blocks")
    parser.add_argument("--target-policy", type=Path,
                        default=ROOT / "playbooks/policies/target_exclusions.yml")
    args = parser.parse_args()

    warn_target_scope(args.campaign, args.ad_export, args.target_policy)

    with args.campaign.open(encoding="utf-8") as handle:
        campaign = yaml.safe_load(handle) or {}

    selected = campaign.get("phases", [])
    if args.phase:
        selected = [phase for phase in selected if phase.get("phase_id") == args.phase]
        if not selected:
            raise SystemExit("phase not found: {}".format(args.phase))

    for phase in sorted(selected, key=lambda item: item.get("order", 0)):
        for run in phase.get("runs", []):
            render_run(campaign, phase, run)


if __name__ == "__main__":
    main()
