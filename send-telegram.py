#!/usr/bin/env python3
"""Send a Telegram message using bot token and chat ID from tba.env."""
import os, sys, json, urllib.request

token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
if not token or not chat_id:
    print("ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set", file=sys.stderr)
    sys.exit(1)

text = sys.stdin.read().strip()
if not text:
    sys.exit(0)

body = json.dumps({
    "chat_id": chat_id,
    "text": text[:3900],
    "disable_web_page_preview": True
}).encode()

req = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=body,
    headers={"Content-Type": "application/json"}
)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read())
        if not result.get("ok"):
            print(f"Telegram error: {result}", file=sys.stderr)
except Exception as e:
    print(f"Telegram send failed: {e}", file=sys.stderr)
