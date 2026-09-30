# WinRM Troubleshooting — Fixes and Workarounds

Practical reference for Windows fleet hosts that are unreachable or erroring over WinRM,
built from the 2026-08-20 RealVNC removal directive where ~15 hosts across two batches
came back UNREACHABLE or failed mid-run. Update this doc whenever a new failure signature
or fix is confirmed against a real host — this is meant to save re-diagnosis time.

## Quick triage: read the exact Ansible/WinRM error text first

Don't guess "creds" or "network" — the error text tells you which layer failed.
Grep the console log (`grep -A4 "fatal: \[<host>\]: UNREACHABLE" <logfile>`) and match:

| Error text contains | Layer that failed | Likely cause | NOT this |
|---|---|---|---|
| `Failed to resolve ... Name or service not known` | DNS | Stale record, renamed/decommissioned host | not creds, not network segment |
| `No route to host` (errno 113) | Network/routing | Genuinely different subnet/VLAN, or host powered off with no ARP response | not creds |
| `Connection to <host> timed out (connect timeout=30)` | TCP handshake | Host down, firewall dropping (not rejecting) port 5985 | not creds |
| `Read timed out (read timeout=30)` | TCP connected, no response | WinRM service hung/overloaded, or mid-reboot | not creds |
| `Bad HTTP response ... Code 500 / s:Receiver w:InternalError` | WinRM service itself | NTLM negotiated fine — the target's WinRM/PowerShell host process is broken. See below. | **NOT** creds (that's 401), **NOT** network (it answered) |
| `401` / `Access is denied` | Auth | Wrong creds, account locked/expired, or (if testing loopback from your own admin workstation) UAC remote-token filtering — see note below | — |

**UAC note (401/Access-denied on loopback self-tests only):** if you `Invoke-Command
-ComputerName $env:COMPUTERNAME` from your own admin workstation as a local admin and get
"Access is denied", that's `LocalAccountTokenFilterPolicy` filtering the network token for
local accounts — unrelated to fleet-host WinRM-500 errors, and testing from your own
workstation/dev VM tells you nothing about a target host's WinRM state anyway (different
account, different auth path). Diagnose target hosts directly (see below), not by proxy
from your own machine.

## The "Bad HTTP 500 / could not launch a host process" signature

Full client-side error on a working peer:
```
Connecting to remote server <target> failed with the following error message : The WSMan
service could not launch a host process to process the given request. Make sure the WSMan
provider host server and proxy are properly registered.
```
`Test-WSMan` against the host still returns a response, but with `ProductVersion` showing
`OS: 0.0.0 SP: 0.0 Stack: 3.0` instead of a real build number — that `0.0.0` is the tell.

This means: DNS resolved, TCP connected, NTLM/Kerberos negotiated, WinRM's listener answered
— but the shell plugin (`wsmprovhost.exe` / the `Microsoft.PowerShell` PSSessionConfiguration)
can't be launched. **This is not a credentials problem and not a network-segment problem.**

## Diagnosing a host you (or Ansible) can't reach directly: the double-hop-safe relay

If your control node itself is remote/unreachable to the target, or you want to confirm the
failure isn't specific to the control node's own network path, probe from a **healthy sibling
host on the same rack/subnet** instead — using a scheduled task with stored credentials, not a
delegated PSRemoting session. A scheduled task authenticates fresh with its own stored
username/password when it fires, so it doesn't hit the classic double-hop wall (a delegated
NTLM/Kerberos token from hop 1 can't auth hop 2; a task's own stored cred can).

In practice: push a small PowerShell script to the healthy sibling, register and run a
scheduled task (stored credentials) that runs `Test-NetConnection`, `Test-WSMan` and
`Invoke-Command` against the target, fetch the JSON result back, then remove the task,
script and result file. Nothing changes on the target.

## Remote fixes that DON'T need WinRM to already be working

The broken piece is WinRM's own shell-plugin/host-process — so any fix path that also goes
*through* WinRM is a non-starter. These use other RPC channels:

1. **SCM/service bounce over SMB** (`sc.exe \\<target> stop winrm` / `start winrm`) — cheapest,
   safest, no reboot. **Confirmed on a real host:** the service stops/starts cleanly (exit
   code 0, new PID assigned) — but if the underlying shell-plugin registration is what's
   corrupted (not just a hung process), the exact same "could not launch a host process"
   error persists immediately after the bounce. Worth trying first regardless — it's free
   and occasionally the whole fix if the service was just hung.
   - **Bug to avoid:** `sc.exe` is an external command — non-zero exit does NOT throw a
     PowerShell exception, so wrapping it in `try/catch` silently hides failures. Always
     check `$LASTEXITCODE` and capture stdout/stderr explicitly.

2. **WMI/DCOM remote command execution** (`Invoke-CimMethod -ClassName Win32_Process -MethodName
   Create`, forcing `-Protocol Dcom` explicitly — `New-CimSession` defaults to WSMan, which is
   the broken channel) — can run `winrm quickconfig -quiet -force` directly on the target to
   re-register the shell plugin. **Confirmed failure mode on a hardened host:** fails with
   `The RPC server is unavailable.` even though the SCM/SMB channel (#1) works fine on the same
   host — meaning classic DCOM (port 135 + dynamic RPC ports) is firewalled off while
   SMB-tunneled RPC (port 445, used by SCM/`sc.exe`) is not. This is a common hardened-firewall
   posture — don't assume DCOM works just because SCM does, or vice versa.

3. **PsExec / SMB-based remote execution** (not yet implemented in this repo) — uses the same
   SMB/ADMIN$/SCM channel that `sc.exe` already proved works, rather than DCOM. Worth adding as
   the next escalation step for hosts where #1 doesn't fix it and #2 is blocked by firewall,
   before falling back to "needs console access or a reboot."

4. **Remote Task Scheduler** (`schtasks /s <target> /create ...`) — also SMB/RPC-based,
   independent of DCOM and WinRM. Can register+trigger a task directly on the target itself
   (not just relay from a peer) to run an arbitrary fix command.

## When none of the above work

If SCM restart doesn't clear it and DCOM is blocked (and PsExec/remote-schtasks aren't
available or also fail), the host needs **console/RDP access** or **a reboot** — there's no
further remote lever. Flag it for the remediation-inventory / offline-hosts list rather than
looping on remote attempts.

## Aggregate results — 2026-08-20 RealVNC removal directive

14 hosts (13 from the cloudsync batch + 1 localonly sibling pair) showed the "Bad HTTP 500 /
could not launch a host process" signature. Ran the full diagnostic+fix sweep
(`winrm-relay-diag.yml`) against all 14 from a healthy same-rack sibling each:

| Check | Result |
|---|---|
| TCP 5985 reachable | 14/14 |
| `Test-WSMan` returns `OS: 0.0.0` (the broken-shell tell) | 14/14 |
| `sc.exe \\target stop/start winrm` succeeds (exit 0, new PID) | 14/14 — but fixes nothing |
| DCOM (`New-CimSession -Protocol Dcom`) connects, but `Win32_Process.Create` returns code 8 (unknown failure) | 7/14 |
| DCOM itself unreachable (`The RPC server is unavailable.`) | 7/14 |
| **Actually fixed by any remote method** | **0/14** |

**Conclusion:** this was a real, systemic, fleet-wide signature — not 14 unrelated one-offs.
Every affected host can be reached and its WinRM *service* bounced cleanly, but the
underlying process-launch capability is broken on all of them (whether invoked via WSMan's
shell host or via WMI), split roughly evenly on whether DCOM even responds. **None of the
three validated remote-fix mechanisms (SCM bounce, DCOM/WMI process creation, and by
extension anything else that depends on spawning a new remote process) can clear this.**
These hosts need console/RDP access or a reboot — there is no further remote lever once
you've confirmed this exact signature. Don't spend more time trying remote fixes on hosts
matching this pattern; route them straight to the remediation/offline-hosts list.

The `PsExec` and remote-`schtasks` options above were **not** tried in this sweep — they're
listed as the next things to attempt if a future occurrence needs a remote fix before this
"needs console/reboot" conclusion is reached again, but given process-launch itself was
broken on every affected host here (not just one particular channel), it's unlikely they'd
have helped this specific instance either.
