Ansible Roles allow you to organize and reuse your automation code efficiently. By grouping related tasks, variables, handlers, and other artifacts into a structured format, roles enable modularity and reusability, which can significantly streamline your organization's automation processes.

Role Directory Structure
An Ansible role has a defined directory structure with seven main standard directories. Each role must include at least one of these directories, but you can omit any directories the role does not use. The typical structure includes:

tasks/: Contains the main.yml file with a list of tasks that the role provides to the play for execution.
handlers/: Contains handlers that are imported into the parent play for use by the role or other roles and tasks in the play.
templates/: Contains files for use with the template resource, typically ending in .j2.
files/: Contains files for use with the copy resource or script files for use with the script resource.
vars/: Contains high precedence variables provided by the role to the play.
defaults/: Contains very low precedence values for variables provided by the role.

ansible-project/
├── site.yml                      # Main playbook entry point
├── inventory/
│   └── hosts                    # Inventory file (can be static or dynamic)
├── group_vars/
│   └── all.yml                  # Global variables
├── roles/
│   ├── role1/                   # One role per logical task group like remote connectivity, server updates, software installs
│   │   ├── tasks/
│   │   │   └── main.yml         # Main task file
│   │   ├── handlers/
│   │   │   └── main.yml         # Handlers (e.g., restart services)
│   │   ├── templates/           # Jinja2 templates (e.g., config files)
│   │   ├── files/               # Static files to copy
│   │   ├── vars/
│   │   │   └── main.yml         # Role-specific variables
│   │   ├── defaults/
│   │   │   └── main.yml         # Default variables
│   │   ├── meta/
│   │   │   └── main.yml         # Role metadata (dependencies, etc.)
│   │   └── README.md            # Role documentation
│   └── role2/
│       └── ...                  # Repeat for each group of related tasks

Use descriptive, lowercase, hyphenated names for roles that reflect the task they perform. For example:

configure-firewall
install-dotnet
set-local-policies
check-disk-space


TOP LEVEL PLAYBOOK example:

---
- name: Apply system configuration
  hosts: all
  become: yes
  roles:
    - role1
    - role2
    # Add more roles as needed

