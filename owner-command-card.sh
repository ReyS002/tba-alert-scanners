#!/usr/bin/env bash
set -euo pipefail
source /opt/scripts/tba/tba.env
cd "$REPO"
npm run brief:owner-snapshot:telegram 2>&1
