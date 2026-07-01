#!/usr/bin/env bash
set -euo pipefail
source /opt/scripts/tba/tba.env
cd "$REPO"
printf "[Trading Bull Academy Weekly Governance]\n\nGenerated: %s\n\n" "$(date)"
printf "Repo status:\n"
git status --short --branch
printf "\nLatest safety artifact:\n"
latest=$(ls -t paperclip/workspaces/operations/paperclip_safety_health_*.json 2>/dev/null | head -1 || true)
[ -n "$latest" ] && echo "$latest" || echo "No safety artifact found."
