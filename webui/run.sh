#!/usr/bin/env bash
# Convenience launcher for chocoDeploy: Ansible playbook builder.
# Usage:
#   ./webui/run.sh            # localhost:5050
#   ./webui/run.sh --port 5060
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3.12 webui/app.py "$@"
