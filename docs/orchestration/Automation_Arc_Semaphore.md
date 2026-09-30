# Automation, Arc, and Semaphore: where each fits

A planning and decision reference for orchestrating the Ansible roles in this
repo and for third-party application patching. It covers what Azure Automation
and Azure Arc should and could be used for, how they integrate with Ansible, and
where Semaphore fits. Verify current Azure capabilities before building, since
these services change.

## The one split that drives everything

There are two kinds of patching, and they land on two different systems.

| Update type | Owner | Why |
|---|---|---|
| Operating system, Microsoft updates, WSUS-published updates | Azure Update Manager | Update Manager applies updates from Microsoft Update, Linux packages, and WSUS only |
| Third-party applications (7-Zip, vim, PyCharm, VS Code, .NET runtimes, and the rest of the Chocolatey catalog) | Ansible plus Chocolatey (this repo) | These apps do not publish through Microsoft Update or WSUS, so no Azure service patches them |

The practical result: Azure handles the OS layer, and the Ansible and Chocolatey
tooling stays the engine for third-party application patching. They complement
each other. Neither replaces the other.

## Azure Update Manager

**Should be used for:** OS patch compliance and scheduling across Windows and
Linux, for machines in Azure, on-premises, and other clouds once they are
Arc-connected. It gives per-resource RBAC, maintenance windows, periodic
assessment, and compliance dashboards, with no dependency on Log Analytics or an
Automation account.

**Could be used for:** application updates, but only for applications that ship
through Microsoft Update or WSUS. It cannot patch the Chocolatey catalog.

**Does not do:** arbitrary third-party application patching. That stays with Ansible.

## Azure Arc-enabled servers

Arc projects each non-Azure server into Azure as a resource, using the Connected
Machine agent. Note that Arc is for machines outside Azure; it is not for VMs
that already run in Azure.

**Should be used for:**
- A single inventory and identity plane for the fleet. Each host becomes an Azure
  resource with an ID, RBAC, and a managed identity.
- Enabling Azure Update Manager on the fleet for the OS layer.
- Monitoring and compliance through the Azure Monitor Agent and Machine
  Configuration audit policies.

**Could be used for:**
- A delivery channel to the guest that does not need WinRM line of sight, using
  Arc VM extensions such as the Custom Script Extension or Run Command. This can
  run a script on a host directly, which is an alternative way to trigger a
  Chocolatey action or to kick off a local Ansible pull.
- Hosting the Azure Automation Hybrid Runbook Worker as an extension, so runbooks
  execute on the Arc-connected machine.
- Machine Configuration for desired-state audit and enforce, which is guest
  configuration and DSC-style, not Ansible.

**Trade-off to weigh:** the Arc extension push model is a different delivery path
than the current WinRM pull. It removes the WinRM line-of-sight requirement, but
it is per-host and does not give you the run orchestration, reporting, and
conversion logic that the chocoDeploy role already provides. Use it for reach,
not as a replacement for the role.

## Azure Automation

Automation runs PowerShell and Python runbooks, with schedules, webhooks, RBAC,
and credential and variable stores.

**Key limitation:** the Azure-hosted runbook sandbox cannot run `ansible-playbook`
and cannot reach the on-premises fleet. To run the roles from Automation you use
a Hybrid Runbook Worker, a registered machine (`ansible-ctl-01`, or another
Arc-connected host)
where a runbook shells out to `ansible-playbook`.

**Should be used for:** an Azure-side front door when a run needs to start from an
Azure trigger. Examples are a schedule, a webhook, an approval, or a ticket or
ITSM event. It is also the place for Azure-native job history and for wiring runs
to Key Vault and Azure Monitor.

**Could be used for:** orchestrating the full patch flow if you want the trigger
and audit trail in Azure, by having a runbook on the Hybrid Worker call the
existing playbooks or call the Semaphore API.

**Should not be used for:** trying to run Ansible in the cloud sandbox. It will
not reach the fleet.

## Where and if Semaphore fits

Semaphore is an optional lightweight, open-source Ansible UI.
It could provide an execution and interface plane for the roles; that integration
is not supplied by this repository.

**It is one possible Ansible control plane** for this pattern,
because:
- It runs `ansible-playbook` directly on `ansible-ctl-01`, which has the
  vault workflow, repo-local collections, and reach to the fleet.
- It provides the pieces you would otherwise build by hand: task templates,
  inventories, a key and environment store, schedules, a REST API, git-backed
  projects, and per-run history.
- It is lighter than AWX and does not push you toward paid tiers.

**How it relates to Azure:**
- Semaphore is the Ansible execution layer. Azure Automation and Arc are the
  Azure-native trigger, identity, inventory, and OS-patch layers.
- If a run must start from Azure, an Automation runbook or a Logic App calls the
  Semaphore API to launch a task. Otherwise Semaphore runs on its own schedule.
- Semaphore and Azure Update Manager do not overlap. Update Manager does the OS,
  Semaphore drives the third-party application patching through the roles.

## Integration patterns

1. **Baseline split (recommended start).** Arc-connect the fleet. Azure Update
   Manager owns OS patching. Semaphore drives the Ansible roles for third-party
   application patching. Two clean lanes, little coupling.
2. **Azure front door.** An Automation runbook or Logic App reacts to an Azure
   trigger or approval and calls the Semaphore API, or calls `ansible-playbook`
   on a Hybrid Runbook Worker. Use this only when the trigger truly originates in
   Azure.
3. **Arc push as reach extension.** For hosts without WinRM line of sight, use Arc
   Run Command or the Custom Script Extension to run a bootstrap that enables
   WinRM or performs a local action, then hand back to the normal role path. This
   mirrors the domain-onboarding handoff idea in the domJoin plan.

## Decision framework

- OS and Microsoft and WSUS updates: **Azure Update Manager**, enabled through Arc.
- Third-party application patching: **Ansible and Chocolatey**, driven by **Semaphore**.
- Fleet inventory, identity, RBAC, and monitoring in one place: **Azure Arc**.
- A run that must start from an Azure event, schedule, or approval: **Azure
  Automation** in front of Semaphore or a Hybrid Runbook Worker.
- A scheduler, credential store and run history are separate from the local
  command builder. An optional control plane such as Semaphore can provide them.

## Preparations that apply to any of the above
- Make the playbooks fully parameterized and non-interactive, everything through
  extra-vars.
- Return real exit codes. The `failed_when: false` patterns in chocoDeploy can
  report success while a host is broken, which any trigger that trusts the exit
  code will hide. Fix this before automating.
- Move secrets to a callable store. A worker or Semaphore pulls credentials from
  Key Vault or from its own key store, rather than relying on a human-seeded
  `.vault_key.txt`.
- Adopt a dynamic inventory, ideally the Foreman plugin, so runs target current
  hosts.
- Keep runs SCM-backed from the Azure DevOps repo so they are versioned.
- Gate fleet-changing runs behind RBAC and an approver. Keep the standing rules,
  such as no fleet reboots during a patch window.

## Open questions to confirm
- [ ] Is the fleet Arc-connected today, or would onboarding the Connected Machine
  agent be step one?
- [ ] Do you want OS patching moved to Azure Update Manager, or does another
  process own the OS layer today?
- [ ] Current Semaphore health: version, service state, and whether its project
  still points at the live DevOps repo.
- [ ] Do any real triggers originate in Azure today, or would Automation be
  solving a problem you do not have yet?
