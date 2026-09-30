# chocoDeploy Web UI (local builder demo)

A local browser interface that **assembles** `ansible-playbook` commands for the
`chocoDeploy` role -- lego-brick style -- and lets you copy them into your
existing streaming terminal. No `ansible-playbook` invocations are made by
this UI. Inventory discovery, `win_ping` probing, and saving new inventories
are the only side capabilities (they can't be done from a browser alone).

## Launch
Run from the root of your ANS-CHOCO checkout. For an offline preview on any
supported workstation, use `python webui/app.py` and set
`CHOCO_FLEET_CAMPAIGN_STORE` to an empty local directory as shown in the root
README. Ansible and credentials are needed only for authorized `win_ping`, not
command assembly. If running on your own Linux control node, forward port 5050
to your workstation rather than exposing it on the network.

```bash
cd <choco-fleet>
./webui/run.sh                   # default 127.0.0.1:5050
./webui/run.sh --port 5060       # alt port
```
Then open <http://127.0.0.1:5050/> in your browser.

The server uses Python's standard library (3.10+; the launcher uses
`python3.12`). It defaults to loopback; do not override `--bind` to expose it.
Build campaign inventories before using them in the UI; the
protected-OU process check is performed by `playbooks/tools/csv_to_inventory.py`
when received host lists become inventories.

The campaign store defaults to `$CHOCO_FLEET_DATA_ROOT/incoming`
(`/opt/ansible/incoming` on the production control node). Set
`CHOCO_FLEET_CAMPAIGN_STORE` to override just the Web UI campaign store.

## What's in the UI
- **Sidebar -- Browse**: dropdown of the standing repo inventories (`inventory/TEST/`,
  `inventory/Internalize/`) plus every inventory in the external campaign store
  (`/opt/ansible/incoming/**` by default, override with `CHOCO_FLEET_CAMPAIGN_STORE`).
  Each entry is tagged `repo` or `campaign`. Campaign entries use absolute paths so the
  copied `-i` works from any directory. Click an inventory to see its
  hosts. Per-host `ping` button runs `ansible <host> -m ansible.windows.win_ping`
  against the right inventory. `Ping all` does the whole inventory at once.
  `Export` downloads the YAML. **Use this inventory in builder** writes
  `-i <path>` (and, when there is exactly one group, `-l <group>`) into the
  main panel.

- **Sidebar -- Build new**: name + group + hosts textarea. **Save** writes
  `<campaign-store>/<campaign-id>/inv-<name>.yml` (plus `group_vars/<group>.yml` with
  the same WinRM defaults the rest of the repo uses) and auto-selects it. Campaign id
  defaults to today in `YYMMDD`. Target lists are never written into the repository.
  **Download YAML** touches nothing -- it just hands you the file.

- **Main panel -- Steps 1-6**: Target, Mode, Apps, Removals, Runtimes, Flags.
  Mirrors the `chocoDeploy_QuickRef.md` lego shapes:
  - `targetSoftware` sentinel modes (`default` / `filter` / `skip = []`)
  - `removeSoftware` sentinel modes + ad-hoc package ids
  - Runtimes with track chips, `exclusive` / `floor_required` /
    `min_supported_track`, and `*_cleanup_vendor` / `*_audit_only` flags
  - Reboot policy, force-orphan flags (greenshot, winscp), forks, tags,
    free-form `-e` lines

- **Command output**: rendered live. Toggle multi-line vs single-line.
  Two copy buttons (copy = the displayed form, copy single-line = collapse).
  Warnings appear when the command will not run (e.g. no inventory) or
  combines incompatibly (e.g. `filter` with no apps checked).

## Health dot
Top right corner. **Green** when ansible is on PATH and
`vault/.vault_key.txt` exists. **Yellow** if one is missing. **Red** if the
server is unreachable.

## Files
```
webui/
  app.py            # http.server, ~5 endpoints, no execution of ansible-playbook
  catalog.json      # hand-curated mirror of defaults/main.yml
  run.sh
  static/
    index.html
    style.css       # dark theme matching playbooks/roles/chocoDeploy/templates/report.html.j2
    app.js
```

## Updating the catalog
When `playbooks/roles/chocoDeploy/defaults/main.yml` changes
(`choco_managed_apps` versions, new app, new runtime channel, removal
catalog), edit `webui/catalog.json` to match. The UI is intentionally
hand-curated to keep the launcher dependency-free; the JSON file is small
and central.

## What this UI does NOT do
- It does **not** run `ansible-playbook`. The streaming terminal stays
  your single source of live execution.
- It does **not** modify role defaults, vault material, or source-controlled
  inventories. Saving new inventories writes to the campaign store.
- The default bind is `127.0.0.1`; an explicit `--bind` override can expose it,
  so keep it local.
