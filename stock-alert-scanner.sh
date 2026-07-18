#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/lib/hermes-agent/venv/bin:$PATH"
source /opt/scripts/tba/tba.env
source /root/.hermes/.env 2>/dev/null
CONFIG="/opt/scripts/tba/stock-alerts-config.json"
[ -f "$CONFIG" ] || { echo "No config at $CONFIG"; exit 0; }
mkdir -p "$STATE_DIR"
python3 - "$CONFIG" "$STATE_DIR" <<'PY'
import sys,json,os,urllib.request
from datetime import datetime,timezone,timedelta
from zoneinfo import ZoneInfo

# ── Market-hours gate (US Eastern, DST-aware) — NYSE 9:30–16:00 Mon–Fri ──
now_et = datetime.now(ZoneInfo("America/New_York"))
if now_et.weekday() >= 5 or not (9, 30) <= (now_et.hour, now_et.minute) < (16, 0):
    print("AFTER_HOURS")
    sys.exit(0)

config_file = sys.argv[1]; state_dir = sys.argv[2]
with open(config_file) as f: config = json.load(f)
dedup_hours = config["settings"].get("dedup_hours", 24)
alerts_fired = []

for ticker in config["tickers"]:
    symbol = ticker["symbol"]; name = ticker["name"]
    try:
        import yfinance as yf
        data = yf.download(symbol, period="3mo", interval="1d", progress=False, auto_adjust=True)
        if data.empty or len(data) < 50:
            print(f"SKIP {symbol}: {len(data)} bars", file=sys.stderr); continue
        closes = data["Close"].values.flatten().tolist()
        highs = data["High"].values.flatten().tolist()
        lows = data["Low"].values.flatten().tolist()
        volumes = data["Volume"].values.flatten().tolist()
        current = closes[-1]; prev = closes[-2] if len(closes) > 1 else current
        ma20 = sum(closes[-21:-1]) / 20 if len(closes) >= 21 else sum(closes) / len(closes)
        ma50 = sum(closes[-51:-1]) / 50 if len(closes) >= 51 else ma20
        ma200 = sum(closes[-201:-1]) / 200 if len(closes) >= 201 else None
        avg_vol = sum(volumes[-21:-1]) / 20 if len(volumes) >= 21 and sum(volumes[-21:-1]) > 0 else 1
        vol_ratio = volumes[-1] / avg_vol if avg_vol > 0 else 1.0
    except Exception as e:
        print(f"SKIP {symbol}: {e}", file=sys.stderr); continue

    for alert in ticker.get("alerts", []):
        aid = alert["id"]; atype = alert["type"]; params = alert.get("params", {})
        state_file = os.path.join(state_dir, f"stock_{aid}.txt")
        if os.path.exists(state_file):
            try:
                last_ts = datetime.fromisoformat(open(state_file).read().strip())
                if (datetime.now(timezone.utc) - last_ts).total_seconds() / 3600 < dedup_hours:
                    continue
            except: pass
        fired = False; reason = ""
        if atype == "ma_cross_20":
            prev_ma20 = sum(closes[-22:-2]) / 20 if len(closes) >= 22 else ma20
            if prev <= prev_ma20 and current > ma20:
                fired = True; reason = f"close ${current:.2f} crossed above 20MA ${ma20:.2f}"
        elif atype == "ma_cross_50":
            prev_ma50 = sum(closes[-52:-2]) / 50 if len(closes) >= 52 else ma50
            if prev <= prev_ma50 and current > ma50:
                fired = True; reason = f"close ${current:.2f} crossed above 50MA ${ma50:.2f}"
        elif atype == "golden_cross":
            prev_ma50 = sum(closes[-52:-2]) / 50 if len(closes) >= 52 else ma50
            prev_ma200 = sum(closes[-202:-2]) / 200 if len(closes) >= 202 and ma200 else None
            if ma200 and prev_ma200 and prev_ma50 <= prev_ma200 and ma50 > ma200:
                fired = True; reason = f"50MA ${ma50:.2f} crossed above 200MA ${ma200:.2f} (golden cross)"
        elif atype == "elephant_bar":
            body = abs(current - float(data["Open"].values.flatten()[-1]))
            rng = highs[-1] - lows[-1] if highs[-1] > lows[-1] else 0.01
            if body / rng >= 0.65 and vol_ratio >= 1.2 and current > ma20:
                fired = True; reason = f"elephant bar: body {body/rng:.0%} range, {vol_ratio:.1f}x volume"
        elif atype == "nr7":
            lookback = params.get("lookback", 7)
            ranges = [highs[i] - lows[i] for i in range(-lookback, 0)]
            if len(ranges) >= lookback and all(ranges[-1] <= r for r in ranges[:-1]):
                fired = True; reason = f"NR7: narrowest range in {lookback} days, close ${current:.2f}"
        elif atype == "volume_spike":
            if vol_ratio >= params.get("min_vol_ratio", 2.0):
                fired = True; reason = f"volume {vol_ratio:.1f}x average"
        if fired:
            alerts_fired.append({
                "id": aid, "symbol": symbol, "name": name,
                "setup": alert.get("setup", ""), "message": alert.get("message", ""),
                "reason": reason, "price": round(current, 2), "ma20": round(ma20, 2),
                "ma50": round(ma50, 2) if ma50 else None,
                "ma200": round(ma200, 2) if ma200 else None,
                "vol_ratio": round(vol_ratio, 1),
            })
            with open(state_file, 'w') as f:
                f.write(datetime.now(timezone.utc).isoformat())

if alerts_fired:
    lines = ["📈 Stock Alert — Setup Detected\n"]
    for a in alerts_fired:
        lines.append(f"{a['name']} ({a['symbol']}): {a['message']}")
        lines.append(f"  Setup: {a['setup']} | Price: ${a['price']:.2f} | 20MA: ${a['ma20']:.2f}")
        if a.get('ma50'): lines.append(f"  50MA: ${a['ma50']:.2f}")
        if a.get('ma200'): lines.append(f"  200MA: ${a['ma200']:.2f}")
        lines.append(f"  {a['reason']}\n")
    lines.append("Educational purposes only. Manage your risk.")
    msg = "\n".join(lines)
    # Forward to @Stocks_TBull_bot channel
    fwd_token = os.environ.get("STOCK_FWD_BOT_TOKEN", "")
    fwd_chat_id = os.environ.get("STOCK_FWD_CHANNEL_ID", "")
    if fwd_token and fwd_chat_id:
        try:
            fwd_data = json.dumps({"chat_id": fwd_chat_id, "text": msg, "disable_web_page_preview": True}).encode()
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{fwd_token}/sendMessage",
                data=fwd_data, headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                result = json.loads(resp.read())
                print(f"Stock alert sent: {result.get('ok')}")
        except Exception as e:
            print(f"Stock forward error: {e}", file=sys.stderr)
    else:
        print("Stock forwarding not configured")
else:
    print("CLEAR")
PY
