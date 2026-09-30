#!/usr/bin/env python3
"""
Nexus package ingestion tool for the choco-fleet Chocolatey mirror migration
(control node -> mirror-01 SMB share  =>  control node -> Nexus at 192.0.2.20).

Downloads a package from the public Chocolatey community feed, optionally swaps in a newer/different installer binary,
pushes the nupkg to the `chocolatey-development` (nuget) repo and the raw
installer asset(s) to `chocolatey-installers` (raw), then updates the
existing manifest system (manifests/current/packages.csv + a new dated
manifests/runs/<runid>/packages.nexus.csv snapshot) so ingestion done this
way stays visible to whatever else reads that manifest.

Usage:
  # Straight community-feed ingest (what we validated with nxlog 3.2.2329):
  python3 nexus_ingest.py --id nxlog --version 3.2.2329

  # Swap in a newer/different installer binary before pushing (e.g. once a
  # newer JRE build is obtained through a proper Oracle OTN channel):
  python3 nexus_ingest.py --id jre8 --version 8.0.491 \
      --installer /path/to/jre-8u491-windows-x64.exe

  # Preview without writing anything:
  python3 nexus_ingest.py --id foo --version 1.2.3 --dry-run

Auth: reads the Nexus API key from --api-key-file (default
vault/.nexus_api_key). Never pass the key as a bare argument or print it --
this script only ever reads it from disk.
"""
import argparse
import csv
import hashlib
import io
import re
import sys
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timezone

COMMUNITY_FEED = "https://community.chocolatey.org/api/v2/package"
NEXUS_DEV_REPO = "chocolatey-development"
NEXUS_RAW_REPO = "chocolatey-installers"

# Matches the externally-maintained Nexus manifest schema exactly (that manifest
# is kept by a separate ingestion tool; see docs/FUTURE_BUILDS.md).
MANIFEST_FIELDS = [
    "PackageId", "Version", "Title", "Authors", "Description", "Tags",
    "InstallerUrl", "InstallerUrl64", "InstallerFileName", "InstallerType",
    "SilentArgs", "Checksum", "Checksum64", "ChecksumType", "ChecksumType64",
    "PackageSourcePath", "NuspecPath", "ToolsPath", "InstallScriptPath",
    "InstallerPath", "EmbeddedInstallerFiles", "ExistingNupkg", "ExistingNupkgHash",
    "DestinationNupkg", "Enabled", "RepoReady", "BuildReady", "PackageMode",
    "ManifestStatus", "MissingFields", "IdVersionSource", "NuspecReadStatus",
    "NuspecReadError", "PackageReadStatus", "PackageReadError", "InstallScriptFound",
    "Notes", "DiscoveredOn", "UrlConfidence", "ResolvedVersion", "ActualChecksum",
    "ChecksumStatus", "SyncStatus", "SyncMessage", "LastSyncRunId", "LastSyncOn",
]


def read_key(path):
    with open(path, "r") as f:
        return f.read().strip()


def download_nupkg(pkg_id, version):
    url = f"{COMMUNITY_FEED}/{pkg_id}/{version}"
    with urllib.request.urlopen(url, timeout=60) as resp:
        return resp.read()


def parse_nuspec(nupkg_bytes):
    import xml.etree.ElementTree as ET
    zf = zipfile.ZipFile(io.BytesIO(nupkg_bytes))
    nuspec_name = next(n for n in zf.namelist() if n.endswith(".nuspec"))
    root = ET.fromstring(zf.read(nuspec_name))
    ns = {"n": root.tag.split("}")[0].strip("{")} if "}" in root.tag else {}

    def find(tag):
        el = root.find(f".//n:{tag}", ns) if ns else root.find(f".//{tag}")
        return el.text.strip() if el is not None and el.text else ""

    meta = {
        "id": find("id"), "version": find("version"), "title": find("title"),
        "authors": find("authors"), "description": find("description"),
        "tags": find("tags"),
    }
    tools_files = [n for n in zf.namelist() if n.startswith("tools/") and not n.endswith("/")]
    install_script = "tools/chocolateyInstall.ps1" if "tools/chocolateyInstall.ps1" in zf.namelist() else ""
    embedded = [n for n in tools_files if re.search(r"\.(exe|msi)$", n, re.I)]
    return meta, zf, install_script, embedded


def rebuild_nupkg_with_installer(nupkg_bytes, old_embedded_name, new_installer_path):
    """Swap one embedded installer file for a locally-provided one, keeping
    everything else in the nupkg (nuspec, other tools/ files) unchanged."""
    src = zipfile.ZipFile(io.BytesIO(nupkg_bytes))
    out_buf = io.BytesIO()
    with open(new_installer_path, "rb") as f:
        new_bytes = f.read()
    with zipfile.ZipFile(out_buf, "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            data = src.read(item.filename)
            if item.filename == old_embedded_name:
                data = new_bytes
            dst.writestr(item, data)
    return out_buf.getvalue()


def sha256_of(data):
    return hashlib.sha256(data).hexdigest().upper()


def push_nupkg(nexus_url, api_key, nupkg_bytes, filename):
    boundary = "----NexusIngestBoundary"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="package"; filename="{filename}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode() + nupkg_bytes + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        f"{nexus_url}/repository/{NEXUS_DEV_REPO}/",
        data=body, method="PUT",
        headers={
            "X-NuGet-ApiKey": api_key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, False
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", "replace")
        if e.code == 400 and "already exists" in body_text:
            return e.code, True
        raise


def find_component_id(nexus_url, api_key, repo, dest_path):
    """Look up the component id for an exact raw asset path, if it exists."""
    group, _, name = dest_path.rpartition("/")
    url = f"{nexus_url}/service/rest/v1/search?repository={repo}&group=/{group}"
    req = urllib.request.Request(url, headers={"X-NuGet-ApiKey": api_key})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = __import__("json").load(resp)
    for item in data.get("items", []):
        if item.get("name", "").rstrip("/") == f"/{dest_path}":
            return item["id"]
    return None


def delete_component(nexus_url, api_key, component_id):
    req = urllib.request.Request(
        f"{nexus_url}/service/rest/v1/components/{component_id}",
        method="DELETE", headers={"X-NuGet-ApiKey": api_key},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status


def push_raw(nexus_url, api_key, data, dest_path, overwrite=False):
    if overwrite:
        existing_id = find_component_id(nexus_url, api_key, NEXUS_RAW_REPO, dest_path)
        if existing_id:
            try:
                delete_component(nexus_url, api_key, existing_id)
            except urllib.error.HTTPError as e:
                if e.code == 403:
                    print(f"  (no delete permission for {dest_path} -- this API key is push-only; skipping overwrite)")
                    return None
                raise
    req = urllib.request.Request(
        f"{nexus_url}/repository/{NEXUS_RAW_REPO}/{dest_path}",
        data=data, method="PUT",
        headers={"X-NuGet-ApiKey": api_key, "Content-Type": "application/octet-stream"},
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return resp.status


def fetch_manifest(nexus_url):
    url = f"{nexus_url}/repository/{NEXUS_RAW_REPO}/manifests/current/packages.csv"
    with urllib.request.urlopen(url, timeout=30) as resp:
        raw = resp.read().decode("utf-8-sig")
    return list(csv.DictReader(io.StringIO(raw)))


def render_manifest_csv(rows):
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=MANIFEST_FIELDS, quoting=csv.QUOTE_ALL)
    writer.writeheader()
    for r in rows:
        writer.writerow({k: r.get(k, "") for k in MANIFEST_FIELDS})
    return buf.getvalue().encode("utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--id", required=True, help="Chocolatey package id (e.g. nxlog, jre8)")
    ap.add_argument("--version", required=True, help="Version to pull from the community feed")
    ap.add_argument("--nexus-url", default="http://192.0.2.20:8081")
    ap.add_argument("--api-key-file", default="vault/.nexus_api_key")
    ap.add_argument("--installer", help="Local file to swap in for the first embedded installer (optional)")
    ap.add_argument("--dry-run", action="store_true", help="Download/inspect only, push nothing")
    args = ap.parse_args()

    print(f"Downloading {args.id} {args.version} from the community feed...")
    nupkg_bytes = download_nupkg(args.id, args.version)
    meta, zf, install_script, embedded = parse_nuspec(nupkg_bytes)
    print(f"  Title={meta['title']!r} Authors={meta['authors']!r} embedded={embedded or '(none -- external download package)'}")

    if args.installer:
        if not embedded:
            print("ERROR: --installer given but this package has no embedded installer to swap.", file=sys.stderr)
            sys.exit(1)
        print(f"Swapping {embedded[0]} for local file {args.installer} ...")
        nupkg_bytes = rebuild_nupkg_with_installer(nupkg_bytes, embedded[0], args.installer)
        zf = zipfile.ZipFile(io.BytesIO(nupkg_bytes))

    if args.dry_run:
        print("Dry run -- not pushing anything.")
        return

    api_key = read_key(args.api_key_file)
    nupkg_filename = f"{args.id}.{args.version}.nupkg"
    status, already_present = push_nupkg(args.nexus_url, api_key, nupkg_bytes, nupkg_filename)
    if already_present:
        print(f"nupkg already present in {NEXUS_DEV_REPO} (HTTP {status}, redeploy not allowed) -- continuing to manifest update.")
    else:
        print(f"Pushed nupkg to {NEXUS_DEV_REPO}: HTTP {status}")

    installer_pushed = []
    for name in embedded:
        data = zf.read(name)
        fname = name.split("/")[-1]
        dest = f"{args.id}/{args.version}/{fname}"
        st = push_raw(args.nexus_url, api_key, data, dest, overwrite=True)
        installer_pushed.append((fname, sha256_of(data)))
        print(f"Pushed installer asset {dest} to {NEXUS_RAW_REPO}: HTTP {st}")

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    run_id = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    row = {k: "" for k in MANIFEST_FIELDS}
    row.update({
        "PackageId": meta["id"], "Version": meta["version"], "Title": meta["title"],
        "Authors": meta["authors"], "Description": meta["description"][:500],
        "Tags": meta["tags"], "InstallScriptPath": install_script,
        "EmbeddedInstallerFiles": ";".join(embedded),
        "Enabled": "TRUE", "RepoReady": "TRUE", "BuildReady": "TRUE",
        "PackageMode": "AnsibleIngest", "ManifestStatus": "Synced",
        "IdVersionSource": "EmbeddedNuspec", "NuspecReadStatus": "Read",
        "PackageReadStatus": "Read", "InstallScriptFound": "TRUE" if install_script else "FALSE",
        "Notes": "Ingested via choco-fleet chocoBuild tooling (nexus_ingest.py)",
        "DiscoveredOn": now_iso, "ResolvedVersion": meta["version"],
        "SyncStatus": "Synced", "SyncMessage": "Pushed via nexus_ingest.py",
        "LastSyncRunId": run_id, "LastSyncOn": now_iso,
    })
    if installer_pushed:
        fname, checksum = installer_pushed[0]
        row.update({
            "InstallerFileName": fname, "Checksum": checksum, "ChecksumType": "sha256",
            "ActualChecksum": checksum, "ChecksumStatus": "ChecksumCaptured",
        })

    print("Fetching current manifest...")
    rows = fetch_manifest(args.nexus_url)
    rows = [r for r in rows if not (r.get('\ufeff"PackageId"', r.get("PackageId")) == meta["id"] and r.get("Version") == meta["version"])]
    rows.append(row)

    csv_bytes = render_manifest_csv(rows)
    st = push_raw(args.nexus_url, api_key, csv_bytes, "manifests/current/packages.csv", overwrite=True)
    if st is not None:
        print(f"Updated manifests/current/packages.csv: HTTP {st}")
    st = push_raw(args.nexus_url, api_key, csv_bytes, f"manifests/runs/{run_id}/packages.nexus.csv")
    print(f"Wrote manifests/runs/{run_id}/packages.nexus.csv: HTTP {st}")

    print("Done.")


if __name__ == "__main__":
    main()
