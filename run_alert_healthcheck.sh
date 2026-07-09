#!/usr/bin/env bash
set -euo pipefail
source /opt/scripts/tba/tba.env
# also load the Hermes env for TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID (healthcheck
# needs them; tba.env only carries the per-sector forward-bot tokens).
# set -a forces auto-export so the bare (non-exported) vars in .hermes/.env are
# visible to the python child process — without it os.getenv() returns empty.
set -a
source /root/.hermes/.env 2>/dev/null || true
set +a
cd /opt/stacks/trading-bull-academy/paperclip/infrastructure/mcp-servers/trading-bull/scripts
exec python3 run_daily_alert_healthcheck.py "$@"
