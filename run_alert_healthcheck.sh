#!/usr/bin/env bash
set -euo pipefail
source /opt/scripts/tba/tba.env
cd /opt/stacks/trading-bull-academy/paperclip/infrastructure/mcp-servers/trading-bull/scripts
exec python3 run_daily_alert_healthcheck.py "$@"
