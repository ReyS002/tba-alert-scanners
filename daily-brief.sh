#!/usr/bin/env bash
set -euo pipefail
source /opt/scripts/tba/tba.env
cd "$REPO"
npm run build --silent >/dev/null 2>&1 || true
MESSAGE="$(node dist/scripts/telegram-daily-brief.js)"
printf "%s\n\nBoundary: owner brief only. No broker action, no publishing." "$MESSAGE" | python3 /opt/scripts/tba/send-telegram.py
echo "$MESSAGE"
