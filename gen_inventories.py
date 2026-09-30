#!/usr/bin/env python3.12
"""
gen_inventories.py — build grouped chocoDeploy inventories from a scanner workbook.

Reads an input workbook (one row per host x software), filters to software that
maps to our chocoDeploy catalog, and writes one inventory per rollout group into the
external campaign store at $CHOCO_FLEET_DATA_ROOT/incoming/<campaign-id>/ (root defaults to /opt/ansible).
Out-of-catalog software (office, chrome, edge) is
written to an EXCLUDED report, never to a runnable inventory.

READ-ONLY w.r.t. hosts. Generates local files only. Run:
  python3.12 gen_inventories.py /path/to/example-patchlist.xlsx \
    --ad-export <protected-AD-object-export.json> --campaign-id example-campaign
"""
import argparse
import sys, os, re, zipfile, datetime
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "playbooks", "tools"))
from lint_target_scope import ScopeError, lint_hosts

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
DOMAIN = "corp.example.com"
# Generated inventories carry real fleet hostnames, so they belong in the external
# campaign store, never in the repository. Override per campaign with --outdir.
CAMPAIGN_STORE = os.path.join(os.environ.get("CHOCO_FLEET_DATA_ROOT") or "/opt/ansible", "incoming")

# scanner/patchlist software token -> (group filename stem, chocoDeploy selector)
# selector kinds: app -> targetSoftware; runtime -> targetRuntimes
CATALOG = {
    ".net":               ("dotnet",   "runtime", "dotnet_runtime"),
    "asp.net_core":       ("dotnet",   "runtime", "dotnet_runtime"),
    "visual_studio_code": ("vscode",   "app",     "vscode"),
    "desktop":            ("docker",   "app",     "docker-desktop"),  # vendor 'docker' / software 'desktop'
    "vim":                ("vim",      "app",     "vim"),
    "powershell":         ("powershell","runtime","powershell_core"),
    "greenshot":          ("greenshot","app",     "greenshot"),
}
# explicitly out of scope (documented, not run)
EXCLUDED = {"office", "chrome", "edge_chromium-based"}


def read_rows(path):
    z = zipfile.ZipFile(path)
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS):
            shared.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["m"])))
    root = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))

    def ci(ref):
        m = re.match(r"([A-Z]+)", ref or "A1"); n = 0
        for c in m.group(1): n = n * 26 + (ord(c) - 64)
        return n - 1

    rows = []
    for r in root.iter("{%s}row" % NS["m"]):
        cells = {}
        for c in r.findall("m:c", NS):
            t = c.get("t"); v = c.find("m:v", NS)
            cells[ci(c.get("r"))] = (shared[int(v.text)] if (t == "s" and v is not None and v.text)
                                     else (v.text if v is not None else ""))
        rows.append([cells.get(i, "") for i in range(7)])
    return rows


def fqdn(h):
    h = h.strip().lower()
    return h if h.endswith(DOMAIN) else f"{h}.{DOMAIN}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="patch list .xlsx exported from scanner")
    parser.add_argument("--ad-export", required=True,
                        help="AD protected-object export used for target scope validation")
    parser.add_argument("--target-policy", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                           "playbooks", "policies", "target_exclusions.yml"))
    parser.add_argument("--campaign-id", default=datetime.date.today().strftime("%y%m%d"),
                        help="campaign id; output goes to <campaign-store>/<campaign-id>/")
    parser.add_argument("--outdir", default=None,
                        help="explicit output directory (overrides --campaign-id)")
    args = parser.parse_args()
    outdir = args.outdir or os.path.join(CAMPAIGN_STORE, args.campaign_id)
    src = args.source
    rows = read_rows(src)
    groups = defaultdict(set)       # stem -> set(fqdn hosts)
    selector = {}                   # stem -> (kind, target)
    excluded = defaultdict(set)     # software -> hosts
    unknown = defaultdict(set)
    for host, vendor, sw, ver, *_ in rows:
        if not host.strip():
            continue
        sw = sw.strip().lower()
        if sw in CATALOG:
            stem, kind, target = CATALOG[sw]
            groups[stem].add(fqdn(host))
            selector[stem] = (kind, target)
        elif sw in EXCLUDED:
            excluded[sw].add(fqdn(host))
        else:
            unknown[sw].add(fqdn(host))

    try:
        scope = lint_hosts([(src, sorted({host for hosts in groups.values() for host in hosts}))],
                           Path(args.ad_export), Path(args.target_policy))
    except ScopeError as exc:
        print(f"Target scope validation ERROR: {exc}", file=sys.stderr)
        return 2
    protected = {item["host"] for item in scope["protected_hosts"]}
    for item in scope["protected_hosts"]:
        print(f"  WARN excluded {item['host']}: protected OU {item['matching_ou']} "
              f"({item['distinguishedName']})", file=sys.stderr)
    for stem in list(groups):
        groups[stem] -= protected
        if not groups[stem]:
            del groups[stem]

    os.makedirs(outdir, exist_ok=True)
    today = datetime.date.today().isoformat()
    summary = []
    for stem, hosts in sorted(groups.items(), key=lambda x: -len(x[1])):
        kind, target = selector[stem]
        if kind == "app":
            sel = f'-e \'{{"targetSoftware":["{target}"],"removeSoftware":[],"targetRuntimes":[]}}\''
        else:
            sel = f'-e \'{{"targetSoftware":[],"removeSoftware":[],"targetRuntimes":["{target}"]}}\''
        path = os.path.join(outdir, f"inv-{stem}.yml")
        lines = [
            "---",
            f"# {path}",
            f"# Generated {today} from the input workbook by gen_inventories.py.",
            f"# Rollout group: {stem}  ({len(hosts)} hosts)",
            f"# chocoDeploy target: {kind}={target}",
            "#",
            "# AUDIT FIRST, then run live only on operator GO. Streamed, no reboots.",
            "# Suggested run:",
            "#   ansible-playbook playbooks/chocoDeploy.yml \\",
            f"#     -i {path} \\",
            "#     --vault-password-file=vault/.vault_key.txt -l basic_hosts \\",
            '#     -e "deployment=choco_update" \\',
            f"#     {sel}",
            "# Connection vars inherited from group_vars/basic_hosts.yml.",
            "all:",
            "  children:",
            "    basic_hosts:",
            "      hosts:",
        ]
        for h in sorted(hosts):
            lines.append(f"        {h}:")
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
        summary.append((stem, kind, target, len(hosts), path))

    # excluded report
    exrep = os.path.join(outdir, "EXCLUDED_out_of_catalog.txt")
    with open(exrep, "w") as f:
        f.write(f"# Out-of-catalog software from the input workbook ({today})\n")
        f.write("# NOT handled by chocoDeploy. Documented for separate handling.\n\n")
        for sw, hosts in sorted(excluded.items(), key=lambda x: -len(x[1])):
            f.write(f"## {sw}  ({len(hosts)} hosts)\n")
            for h in sorted(hosts):
                f.write(f"{h}\n")
            f.write("\n")
        if unknown:
            f.write("## UNRECOGNIZED software tokens (review):\n")
            for sw, hosts in sorted(unknown.items()):
                f.write(f"#   {sw}: {len(hosts)} hosts\n")

    print(f"Wrote {len(summary)} inventories to {outdir}")
    for stem, kind, target, n, path in summary:
        print(f"  inv-{stem}.yml  {n:4d} hosts  ({kind}={target})")
    print(f"Excluded report: {exrep}")
    for sw, hosts in sorted(excluded.items(), key=lambda x: -len(x[1])):
        print(f"  excluded {sw}: {len(hosts)} hosts")
    if unknown:
        print("UNRECOGNIZED:", {k: len(v) for k, v in unknown.items()})

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
