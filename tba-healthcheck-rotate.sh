#!/usr/bin/env bash
# Auto-rotate TBA alert-healthcheck .md files.
# Keeps a rolling window of the last KEEP_DAYS calendar days (default 7),
# deletes anything older, commits, and pushes.
#
# Mirrors the manual rotation Rey did by hand on 2026-07-07 (commit 07a0d61)
# — this automates that so the files don't pile up again.
set -euo pipefail

REPO_DIR="/opt/stacks/trading-bull-academy"
HEALTHCHECK_DIR="paperclip/workspaces/ops/alert-healthchecks"
KEEP_DAYS="${TBA_HEALTHCHECK_KEEP_DAYS:-7}"

cd "$REPO_DIR"

# Pull first so we rotate against the latest state (in case anything else pushed).
git pull origin main --ff-only >/dev/null 2>&1 || true

CUTOFF_DATE=$(date -u -d "-${KEEP_DAYS} days" +%Y-%m-%d)

DELETED=()
for f in "$HEALTHCHECK_DIR"/*_alert_healthcheck.md; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  file_date="${base:0:10}"  # YYYY-MM-DD prefix
  if [[ "$file_date" < "$CUTOFF_DATE" ]]; then
    git rm -q "$f"
    DELETED+=("$base")
  fi
done

if [ "${#DELETED[@]}" -eq 0 ]; then
  echo "No healthcheck files older than $CUTOFF_DATE — nothing to rotate."
  exit 0
fi

git commit -q -m "chore: auto-rotate alert healthchecks — drop $(IFS=,; echo "${DELETED[*]}")"
git push origin main

echo "Rotated ${#DELETED[@]} file(s), older than $CUTOFF_DATE:"
printf '  - %s\n' "${DELETED[@]}"
