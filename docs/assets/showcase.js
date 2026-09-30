"use strict";

const movements = [
  {
    label: "00 / Full system",
    title: "Separate intent, execution, and evidence.",
    description: "The repository describes approved state. The controller assembles and runs roles. Windows helpers reconcile the actual host. Reports describe outcomes, not guarantees.",
    boundary: "Explore without connecting to a host. The published page is static and carries no vault, inventory exports, or real deployment reports.",
  },
  {
    label: "01 / Reviewable intent",
    title: "Promote configuration, not assumptions.",
    description: "The shared catalog, approved floors, build specifications, and pinned collections form the source contract. validate_catalog.py checks consistency before an operator prepares a run.",
    boundary: "Catalog warnings are coverage gaps. Offline consistency does not establish live package availability, compatibility, or a successful rollout.",
  },
  {
    label: "02 / Artifact preparation",
    title: "Build once; reuse the installation engine.",
    description: "chocoBuild invokes Windows helpers for community internalization and checksum-verified wrappers. Its test-install action includes chocoDeploy with a local source and a single package.",
    boundary: "First-party authoring, classifier, and standalone signing/verification operations remain fail-fast stubs. Download hashing is implemented in wrappers, not proof of completed package signing.",
  },
  {
    label: "03 / Target scope",
    title: "Apply the policy before creating an inventory.",
    description: "csv_to_inventory.py combines host CSV and AD evidence, excludes protected OUs, optionally probes DNS/WinRM, and writes adjacent connection group variables into the campaign store.",
    boundary: "The exclusion is a process gate, not a playbook guard. Unknown hosts are warned; hand-authored and UI-saved inventories bypass it. Review scope before any live run.",
  },
  {
    label: "04 / Host alignment",
    title: "Reconcile what is installed, not just what is listed.",
    description: "The playbook loads local vault vars and invokes chocoDeploy over WinRM. Registry and Chocolatey discovery drive mode-specific application/runtime work, cleanup policy, and deferred reboot handling.",
    boundary: "Conversion can remove software before replacement succeeds. chocoDeploy defaults to no reboot, not no changes. report_only rebuilds existing reports; it is not a deployment dry run.",
  },
  {
    label: "05 / Evidence",
    title: "A retry changes the final state, not the historical record.",
    description: "Per-run JSON and daily host HTML record actions and errors. fleet_summary.py combines the last result per software, resolves successful retries, and writes fleet HTML plus optional structured detail.",
    boundary: "Review coverage and unresolved errors. Usage reports may contain usernames/command lines. Archiving moves consumed JSON and prunes old archives; it is not a read-only option.",
  },
];

const buttons = [...document.querySelectorAll("[data-step]")];
const diagram = document.querySelector(".system-diagram");
let current = 0;

function selectMovement(index, focus = false) {
  current = (index + movements.length) % movements.length;
  const movement = movements[current];
  buttons.forEach((button, i) => {
    if (i === current) {
      button.setAttribute("aria-current", "step");
      if (focus) button.focus();
    } else {
      button.removeAttribute("aria-current");
    }
  });
  diagram.classList.toggle("has-selection", current !== 0);
  diagram.querySelectorAll("[data-steps]").forEach((element) => {
    element.classList.toggle("selected", element.dataset.steps.split(" ").includes(String(current)));
  });
  document.getElementById("movement-label").textContent = movement.label;
  document.getElementById("movement-title").textContent = movement.title;
  document.getElementById("movement-description").textContent = movement.description;
  document.getElementById("movement-boundary").textContent = movement.boundary;
}

buttons.forEach((button) => button.addEventListener("click", () => selectMovement(Number(button.dataset.step))));
document.getElementById("previous").addEventListener("click", () => selectMovement(current - 1));
document.getElementById("next").addEventListener("click", () => selectMovement(current + 1));
document.querySelector(".stepper").addEventListener("keydown", (event) => {
  let destination;
  if (event.key === "ArrowRight") destination = current + 1;
  else if (event.key === "ArrowLeft") destination = current - 1;
  else if (event.key === "Home") destination = 0;
  else if (event.key === "End") destination = movements.length - 1;
  else return;
  event.preventDefault();
  selectMovement(destination, true);
});
