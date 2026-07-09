#!/usr/bin/env bash
# Shared ET-time guard for TZ-less cron.
# Debian/Ubuntu cron has no CRON_TZ support (No-multiple-timezones.patch),
# so the standard workaround (per `man 5 crontab` LIMITATIONS section) is:
# schedule the job at BOTH its EDT-UTC-equivalent and EST-UTC-equivalent
# minute, and gate actual execution on the real America/New_York wall clock
# matching the intended time. Exactly one invocation proceeds per day,
# year-round, with no manual DST re-patching ever needed again.
#
# Usage: cron-et-guard.sh HH:MM command [args...]
set -euo pipefail

INTENDED_ET="$1"
shift

ACTUAL_ET="$(TZ=America/New_York date +%H:%M)"

if [ "$ACTUAL_ET" != "$INTENDED_ET" ]; then
  exit 0  # not the real ET time yet — this is the redundant UTC slot, skip silently
fi

exec "$@"
