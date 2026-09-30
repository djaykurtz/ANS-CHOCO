#!/usr/bin/env python3.12
"""
chocoDeploy: Ansible playbook builder - local-only command builder for the chocoDeploy role.

This server has NO endpoints that execute ansible-playbook. The whole point
is to assemble the command (lego-brick style), let the operator copy it,
and paste into the existing streaming terminal. Two side capabilities are
exposed because they can't be done from a browser alone:

  GET  /api/catalog                          -> static catalog.json
  GET  /api/inventories                      -> standing repo inventories + campaign-store inventories
  GET  /api/inventory?path=<rel>             -> parsed YAML for one inventory
  POST /api/ping     {hosts:[...], inventory:<rel>}
                                             -> runs ansible -m win_ping ad-hoc, returns per-host result
  POST /api/inventory/save  {name, hosts:[...], group_vars:{...}, campaign_id}
                                             -> writes a new inventory into the campaign store
                                                (returns the file path)
  GET  /api/inventory/export?path=<rel>      -> raw YAML download

Bind: 127.0.0.1 only.

Launch:
    cd <choco-fleet checkout>
    python3.12 webui/app.py            # default port 5050
    python3.12 webui/app.py --port 5060

No external dependencies. Python stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import urllib.parse
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

THIS_DIR = Path(__file__).resolve().parent           # .../webui
REPO_ROOT = THIS_DIR.parent                          # .../choco-fleet
STATIC_DIR = THIS_DIR / "static"
CATALOG_PATH = THIS_DIR / "catalog.json"
INVENTORY_DIR = REPO_ROOT / "inventory"
# Campaign target lists carry real fleet hostnames and live outside the repo.
CAMPAIGN_STORE = Path(os.environ.get("CHOCO_FLEET_CAMPAIGN_STORE")
                      or Path(os.environ.get("CHOCO_FLEET_DATA_ROOT") or "/opt/ansible") / "incoming")
VAULT_KEY = REPO_ROOT / "vault" / ".vault_key.txt"
VAULT_FILE = REPO_ROOT / "vault" / "corp-ans-secret.yml"
ROLE_DEFAULTS = REPO_ROOT / "playbooks" / "roles" / "chocoDeploy" / "defaults" / "main.yml"

# ---------------------------------------------------------------------------
# Minimal YAML reader for inventory files
# We deliberately keep this dependency-free. The inventories in this repo use
# a narrow shape (`all -> children -> <group> -> hosts -> <hostname>:`); we
# don't try to be a general YAML parser.
# ---------------------------------------------------------------------------

# Host lines appear as `name:`, `name: {}`, or either form with a trailing comment.
_HOSTNAME_RE = re.compile(r"^\s{6,}([A-Za-z0-9][\w\.\-]*)\s*:\s*(?:\{\s*\})?\s*(?:#.*)?$")
_GROUP_RE = re.compile(r"^\s{4}([A-Za-z0-9_][\w\-]*)\s*:\s*(?:#.*)?$")


def parse_inventory(path: Path) -> dict[str, Any]:
    """Very narrow inventory parser. Returns {groups: {name: [hosts...]}, raw: <text>}.
    Looks for `<4-space indent><groupname>:` lines (children of `all -> children`)
    and `<6+ space indent><hostname>:` lines under each group.
    """
    text = path.read_text(encoding="utf-8")
    groups: dict[str, list[str]] = {}
    current_group: str | None = None
    in_hosts = False

    for raw_line in text.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        gm = _GROUP_RE.match(raw_line)
        if gm and not raw_line.lstrip().startswith(("hosts:", "vars:", "children:")):
            current_group = gm.group(1)
            if current_group not in ("children", "hosts", "vars", "all"):
                groups.setdefault(current_group, [])
                in_hosts = False
            continue
        if raw_line.strip() == "hosts:":
            in_hosts = True
            continue
        if raw_line.strip() == "vars:" or raw_line.strip() == "children:":
            in_hosts = False
            continue
        if in_hosts and current_group:
            hm = _HOSTNAME_RE.match(raw_line)
            if hm:
                hostname = hm.group(1)
                if hostname not in groups[current_group]:
                    groups[current_group].append(hostname)

    return {"groups": groups, "raw": text}


def resolve_inventory(path_str: str) -> Path | None:
    """Resolve a client-supplied inventory path against the two allowed roots.
    Returns None for anything outside them, so a crafted path cannot read
    arbitrary files.
    """
    if not path_str:
        return None
    candidate = Path(path_str)
    if not candidate.is_absolute():
        candidate = REPO_ROOT / candidate
    try:
        resolved = candidate.resolve()
    except OSError:
        return None
    for root in (INVENTORY_DIR, CAMPAIGN_STORE):
        try:
            resolved.relative_to(root.resolve())
        except (ValueError, OSError):
            continue
        return resolved if resolved.is_file() else None
    return None


def _display_path(p: Path) -> str:
    """Repo inventories show as relative paths; campaign files stay absolute so
    the copied -i argument works from any cwd."""
    try:
        return str(p.relative_to(REPO_ROOT))
    except ValueError:
        return str(p)


def _scan_inventories(root: Path, source: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if not root.exists():
        return out
    for p in sorted(root.glob("**/*.yml")):
        parts = p.parts
        if "group_vars" in parts or "archive" in parts:
            continue
        if p.name.endswith(".OLD.yml") or ".OLD-" in p.name:
            continue
        try:
            info = parse_inventory(p)
            host_count = sum(len(h) for h in info["groups"].values())
        except Exception:
            host_count = 0
        out.append({
            "path": _display_path(p),
            "name": p.stem,
            "host_count": host_count,
            "source": source,
        })
    return out


def list_inventories() -> list[dict[str, Any]]:
    """Standing inventories from the repo plus per-campaign inventories from the
    external campaign store."""
    return _scan_inventories(INVENTORY_DIR, "repo") + _scan_inventories(CAMPAIGN_STORE, "campaign")


# ---------------------------------------------------------------------------
# Ping (subprocess wrapper around ansible -m win_ping)
# ---------------------------------------------------------------------------

PING_LOCK = threading.Lock()


def run_ping(inventory_rel: str, hosts: list[str]) -> dict[str, Any]:
    """Run `ansible <host1>,<host2>,... -m win_ping` against the given inventory.
    Returns per-host status parsed from ansible stdout.
    """
    if not hosts:
        return {"results": [], "error": "no hosts"}

    inv_path = resolve_inventory(inventory_rel)
    if inv_path is None:
        return {"results": [], "error": f"inventory not found: {inventory_rel}"}

    if not VAULT_KEY.is_file():
        return {"results": [], "error": f"vault key not found at {VAULT_KEY}"}

    # ansible accepts a comma-terminated host pattern.
    pattern = ",".join(hosts) + ("," if len(hosts) == 1 else "")

    cmd = [
        "ansible",
        "-i", str(inv_path),
        "--vault-password-file", str(VAULT_KEY),
        "-e", f"@{VAULT_FILE}",
        pattern,
        "-m", "ansible.windows.win_ping",
    ]

    with PING_LOCK:
        try:
            proc = subprocess.run(
                cmd,
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return {"results": [{"host": h, "ok": False, "msg": "TIMEOUT (>60s)"} for h in hosts],
                    "error": "ping timeout"}
        except FileNotFoundError:
            return {"results": [], "error": "ansible CLI not on PATH"}

    stdout = proc.stdout or ""
    # Parse per-host status. ansible prints lines like:
    #   <host> | SUCCESS => { ... }
    #   <host> | UNREACHABLE! => { ... }
    #   <host> | FAILED! => { ... }
    status_re = re.compile(
        r"^(?P<host>\S+)\s+\|\s+(?P<status>SUCCESS|UNREACHABLE|FAILED|CHANGED)\b(?:[^=]*)=>\s*(?P<json>.*)$"
    )
    results = {}
    for line in stdout.splitlines():
        m = status_re.match(line)
        if m:
            host = m.group("host")
            status = m.group("status")
            results[host] = {
                "host": host,
                "ok": status in ("SUCCESS", "CHANGED"),
                "status": status,
            }

    # Make sure every requested host has an entry (even if missing from stdout).
    out = []
    for h in hosts:
        if h in results:
            out.append(results[h])
        else:
            out.append({"host": h, "ok": False, "status": "NO_OUTPUT",
                        "msg": (proc.stderr or "")[:400]})

    return {"results": out, "rc": proc.returncode}


# ---------------------------------------------------------------------------
# Inventory save (writes under inventory/Adhoc/)
# ---------------------------------------------------------------------------

_SAFE_NAME = re.compile(r"^[A-Za-z0-9_\-]+$")


def save_inventory(name: str, hosts: list[str], group: str = "basic_hosts",
                   group_vars: dict[str, Any] | None = None,
                   campaign_id: str = "") -> dict[str, Any]:
    if not name or not _SAFE_NAME.match(name):
        return {"ok": False, "error": "name must be [A-Za-z0-9_-]+"}
    if not hosts:
        return {"ok": False, "error": "at least one host required"}
    campaign_id = campaign_id or datetime.now(timezone.utc).strftime("%y%m%d")
    if not _SAFE_NAME.match(campaign_id):
        return {"ok": False, "error": "campaign_id must be [A-Za-z0-9_-]+"}

    out_dir = CAMPAIGN_STORE / campaign_id
    out_dir.mkdir(parents=True, exist_ok=True)
    gv_dir = out_dir / "group_vars"
    gv_dir.mkdir(exist_ok=True)

    inv_path = out_dir / f"inv-{name}.yml"
    if inv_path.exists():
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = inv_path.with_suffix(f".OLD-{ts}.yml")
        inv_path.rename(backup)

    lines = ["---", "all:", "  children:", f"    {group}:", "      hosts:"]
    for h in hosts:
        h = h.strip()
        if h:
            lines.append(f"        {h}:")
    inv_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    # Always (re)write a group_vars stub so WinRM auth works the same as TEST hosts.
    gv_path = gv_dir / f"{group}.yml"
    if not gv_path.exists():
        gv_defaults = {
            "ansible_user": "{{ sys_adm }}",
            "ansible_password": "{{ sys_adm_pass }}",
            "ansible_connection": "winrm",
            "ansible_winrm_scheme": "http",
            "ansible_port": 5985,
            "ansible_winrm_transport": "ntlm",
        }
        if group_vars:
            gv_defaults.update({str(k): v for k, v in group_vars.items()})
        out = []
        for k, v in gv_defaults.items():
            if isinstance(v, str):
                out.append(f'{k}: "{v}"')
            else:
                out.append(f"{k}: {v}")
        gv_path.write_text("\n".join(out) + "\n", encoding="utf-8")

    return {"ok": True, "path": str(inv_path)}


# ---------------------------------------------------------------------------
# mtime tracking - lets the frontend tell when something on disk changed
# (catalog.json, role defaults, any inventory file) so it can offer a reload
# without losing the user's in-progress selections.
# ---------------------------------------------------------------------------

def _mtime(p: Path) -> float:
    try:
        return p.stat().st_mtime
    except FileNotFoundError:
        return 0.0


def collect_mtimes() -> dict[str, float]:
    """Snapshot of mtimes the frontend watches. Inventory files are rolled up
    into a single 'inventory_newest' value to keep the payload small even on
    repos with hundreds of inventories.
    """
    inv_newest = 0.0
    for root in (INVENTORY_DIR, CAMPAIGN_STORE):
        if not root.exists():
            continue
        for p in root.glob("**/*.yml"):
            if "archive" in p.parts or "group_vars" in p.parts:
                continue
            if p.name.endswith(".OLD.yml"):
                continue
            m = _mtime(p)
            if m > inv_newest:
                inv_newest = m
    return {
        "catalog":          _mtime(CATALOG_PATH),
        "role_defaults":    _mtime(ROLE_DEFAULTS),
        "inventory_newest": inv_newest,
    }


def is_catalog_stale() -> bool:
    """True when defaults/main.yml is newer than catalog.json. The catalog is
    hand-curated so drift here means the UI may be showing stale versions or
    missing newly-added apps/runtimes.
    """
    cat = _mtime(CATALOG_PATH)
    rd  = _mtime(ROLE_DEFAULTS)
    return bool(cat and rd and rd > cat)


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "chocoDeployBuilder/0.2"

    # quieter logs
    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), format % args))

    # ---- helpers --------------------------------------------------------

    def _send_json(self, payload: Any, status: int = 200) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, body: str, status: int = 200,
                   content_type: str = "text/plain; charset=utf-8",
                   extra_headers: dict[str, str] | None = None) -> None:
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _send_file(self, path: Path, content_type: str) -> None:
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            self._send_text("404 - not found", 404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    # ---- routing --------------------------------------------------------

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/" or path == "":
            self._send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
            return
        if path == "/style.css":
            self._send_file(STATIC_DIR / "style.css", "text/css; charset=utf-8")
            return
        if path == "/app.js":
            self._send_file(STATIC_DIR / "app.js", "application/javascript; charset=utf-8")
            return
        if path == "/favicon.ico":
            self._send_text("", 204)
            return

        if path == "/api/catalog":
            try:
                data = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
            except Exception as e:
                self._send_json({"error": f"catalog read failed: {e}"}, 500)
                return
            self._send_json(data)
            return

        if path == "/api/inventories":
            self._send_json({"inventories": list_inventories()})
            return

        if path == "/api/inventory":
            qs = urllib.parse.parse_qs(parsed.query)
            rel = (qs.get("path") or [""])[0]
            inv = resolve_inventory(rel)
            if inv is None:
                self._send_json({"error": "invalid inventory path"}, 400)
                return
            try:
                self._send_json({"path": rel, **parse_inventory(inv)})
            except Exception as e:
                self._send_json({"error": str(e)}, 500)
            return

        if path == "/api/inventory/export":
            qs = urllib.parse.parse_qs(parsed.query)
            rel = (qs.get("path") or [""])[0]
            inv = resolve_inventory(rel)
            if inv is None:
                self._send_text("invalid path", 400)
                return
            fname = inv.name
            self._send_text(
                inv.read_text(encoding="utf-8"),
                content_type="application/x-yaml; charset=utf-8",
                extra_headers={"Content-Disposition": f'attachment; filename="{fname}"'},
            )
            return

        if path == "/api/health":
            self._send_json({
                "ok": True,
                "repo_root": str(REPO_ROOT),
                "vault_key_present": VAULT_KEY.is_file(),
                "ansible_on_path": bool(shutil.which("ansible")),
                "time": datetime.now(timezone.utc).isoformat(),
                "mtimes": collect_mtimes(),
                "catalog_stale": is_catalog_stale(),
            })
            return

        if path == "/api/changes":
            # Lightweight poll. Frontend calls with ?since=<unix-ts> and gets
            # back the current mtimes plus a flag list of what is newer than
            # 'since'. The frontend uses this to decide whether to surface a
            # "reload available" banner.
            qs = urllib.parse.parse_qs(parsed.query)
            try:
                since = float((qs.get("since") or ["0"])[0])
            except ValueError:
                since = 0.0
            mt = collect_mtimes()
            changed = sorted(k for k, v in mt.items() if v and v > since)
            self._send_json({
                "now": datetime.now(timezone.utc).timestamp(),
                "mtimes": mt,
                "changed": changed,
                "catalog_stale": is_catalog_stale(),
            })
            return

        self._send_text("404 - not found", 404)

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/api/ping":
            body = self._read_json()
            hosts = [str(h).strip() for h in body.get("hosts") or [] if str(h).strip()]
            inv = str(body.get("inventory") or "").strip()
            if not inv:
                self._send_json({"error": "inventory required"}, 400)
                return
            self._send_json(run_ping(inv, hosts))
            return

        if path == "/api/inventory/save":
            body = self._read_json()
            name = str(body.get("name") or "").strip()
            hosts = [str(h).strip() for h in body.get("hosts") or [] if str(h).strip()]
            group = str(body.get("group") or "basic_hosts").strip() or "basic_hosts"
            group_vars = body.get("group_vars") or None
            campaign_id = str(body.get("campaign_id") or "").strip()
            self._send_json(save_inventory(name, hosts, group=group, group_vars=group_vars,
                                           campaign_id=campaign_id))
            return

        self._send_text("404 - not found", 404)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="chocoDeploy: Ansible playbook builder (local only)")
    ap.add_argument("--port", type=int, default=5050)
    ap.add_argument("--bind", default="127.0.0.1")
    args = ap.parse_args()

    if not CATALOG_PATH.is_file():
        print(f"[!] catalog.json missing at {CATALOG_PATH}", file=sys.stderr)
        return 2
    if not STATIC_DIR.is_dir():
        print(f"[!] static dir missing at {STATIC_DIR}", file=sys.stderr)
        return 2

    httpd = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"[+] chocoDeploy: Ansible playbook builder ready -> http://{args.bind}:{args.port}/")
    print(f"    repo root: {REPO_ROOT}")
    print(f"    Ctrl-C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[+] shutting down")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
