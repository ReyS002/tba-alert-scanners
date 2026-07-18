#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/lib/hermes-agent/venv/bin:$PATH"
source /opt/scripts/tba/tba.env
source /root/.hermes/.env 2>/dev/null
CONFIG="/opt/scripts/tba/forex-alerts-config.json"
[ -f "$CONFIG" ] || { echo "No config at $CONFIG"; exit 0; }
mkdir -p "$STATE_DIR"
python3 - "$CONFIG" "$STATE_DIR" <<'PY'
import sys,json,os,urllib.request
from datetime import datetime,timezone,timedelta
from zoneinfo import ZoneInfo

# ── Market-hours gate (US Eastern, DST-aware) — Forex 24/5: Sun 17:00 to Fri 17:00 ──
now_et = datetime.now(ZoneInfo("America/New_York"))
wd = now_et.weekday()
h, m = now_et.hour, now_et.minute
if (wd == 4 and (h, m) >= (17, 0)) or wd == 5 or (wd == 6 and (h, m) < (17, 0)):
    print("AFTER_HOURS")
    sys.exit(0)

config_file = sys.argv[1]; state_dir = sys.argv[2]
with open(config_file) as f: config = json.load(f)
dedup_hours = config["settings"].get("dedup_hours", 24)
alerts_fired = []

# ── OANDA config ─────────────────────────────────────────────────────────────
OANDA_TOKEN = os.environ.get("OANDA_API_KEY", "") or os.environ.get("OANDA_ACCESS_TOKEN", "")
OANDA_BASE = os.environ.get("OANDA_BASE_URL", "https://api-fxpractice.oanda.com")

def fetch_oanda_candles(instrument: str, count: int = 100) -> list:
    """Fetch daily candles from OANDA. Returns list of {time, o, h, l, c, v}."""
    if not OANDA_TOKEN:
        return []
    url = f"{OANDA_BASE}/v3/instruments/{instrument}/candles?count={count}&granularity=D&price=MB"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {OANDA_TOKEN}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
    except Exception:
        return []
    candles = data.get("candles", [])
    result = []
    for c in candles:
        mid = c.get("mid", {})
        result.append({
            "time": c["time"],
            "o": float(mid.get("o", 0)),
            "h": float(mid.get("h", 0)),
            "l": float(mid.get("l", 0)),
            "c": float(mid.get("c", 0)),
            "v": int(c.get("volume", 0)),
        })
    return result

for pair in config["pairs"]:
    symbol = pair["symbol"]; name = pair["name"]; yahoo_sym = pair.get("yahoo_symbol", symbol)
    closes = []; highs = []; lows = []; volumes = []
    data_source = "none"

    # Primary: OANDA
    oanda_instrument = symbol.replace("/", "_")
    candles = fetch_oanda_candles(oanda_instrument, count=150)
    if len(candles) >= 50:
        closes = [c["c"] for c in candles]
        highs = [c["h"] for c in candles]
        lows = [c["l"] for c in candles]
        volumes = [c["v"] for c in candles]
        data_source = "oanda"

    # Fallback: Yahoo Finance
    if len(closes) < 50:
        try:
            import yfinance as yf
            data = yf.download(yahoo_sym, period="3mo", interval="1d", progress=False, auto_adjust=True)
            if not data.empty and len(data) >= 50:
                closes = data["Close"].values.flatten().tolist()
                highs = data["High"].values.flatten().tolist()
                lows = data["Low"].values.flatten().tolist()
                volumes = data["Volume"].values.flatten().tolist()
                data_source = "yahoo"
        except Exception as e:
            print(f"SKIP {symbol} yahoo fallback: {e}", file=sys.stderr)

    if len(closes) < 50:
        print(f"SKIP {symbol}: insufficient data from OANDA/yahoo ({len(closes)} bars)", file=sys.stderr)
        continue

    current = closes[-1]; prev = closes[-2] if len(closes) > 1 else current
    ma20 = sum(closes[-21:-1]) / 20 if len(closes) >= 21 else sum(closes) / len(closes)
    ma50 = sum(closes[-51:-1]) / 50 if len(closes) >= 51 else ma20
    atr_period = 14
    trs = [max(highs[i]-lows[i], abs(highs[i]-closes[i-1]), abs(lows[i]-closes[i-1]))
           for i in range(-atr_period, 0)] if len(closes) > atr_period else [highs[-1]-lows[-1]]
    atr = sum(trs) / len(trs) if trs else 0.0001

    for alert in pair.get("alerts", []):
        aid = alert["id"]; atype = alert["type"]; params = alert.get("params", {})
        state_file = os.path.join(state_dir, f"forex_{aid}.txt")
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
                fired = True; reason = f"{name} {current:.5f} crossed above 20MA {ma20:.5f}"
        elif atype == "ma_cross_50":
            prev_ma50 = sum(closes[-52:-2]) / 50 if len(closes) >= 52 else ma50
            if prev <= prev_ma50 and current > ma50:
                fired = True; reason = f"{name} {current:.5f} crossed above 50MA {ma50:.5f}"
        elif atype == "atr_breakout":
            mult = params.get("atr_mult", 1.5)
            prev_20ma = sum(closes[-22:-2]) / 20 if len(closes) >= 22 else ma20
            if abs(current - prev_20ma) > atr * mult:
                fired = True; reason = f"{name} {current:.5f} {abs(current-prev_20ma)/atr:.1f} ATR from 20MA"
        elif atype == "nr7":
            lookback = params.get("lookback", 7)
            ranges = [highs[i] - lows[i] for i in range(-lookback, 0)]
            if len(ranges) >= lookback and all(ranges[-1] <= r for r in ranges[:-1]):
                fired = True; reason = f"NR7: narrowest range in {lookback} days"
        if fired:
            alerts_fired.append({
                "id": aid, "symbol": symbol, "name": name,
                "setup": alert.get("setup", ""), "message": alert.get("message", ""),
                "reason": reason, "price": round(current, 5), "ma20": round(ma20, 5),
                "ma50": round(ma50, 5), "atr": round(atr, 5),
                "source": data_source,
            })
            with open(state_file, 'w') as f:
                f.write(datetime.now(timezone.utc).isoformat())

if alerts_fired:
    lines = ["\U0001f4b1 Forex Alert — Setup Detected\n"]
    for a in alerts_fired:
        lines.append(f"{a['name']} ({a['symbol']}): {a['message']}")
        lines.append(f"  Setup: {a['setup']} | Price: {a['price']:.5f} | 20MA: {a['ma20']:.5f} | Source: {a['source']}")
        if a.get('ma50'): lines.append(f"  50MA: {a['ma50']:.5f} | ATR: {a['atr']:.5f}")
        lines.append(f"  {a['reason']}\n")
    lines.append("Educational purposes only. Manage your risk.")
    msg = "\n".join(lines)
    fwd_token = os.environ.get("FOREX_FWD_BOT_TOKEN", "")
    fwd_chat_id = os.environ.get("FOREX_FWD_CHANNEL_ID", "")
    if fwd_token and fwd_chat_id:
        try:
            fwd_data = json.dumps({"chat_id": fwd_chat_id, "text": msg, "disable_web_page_preview": True}).encode()
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{fwd_token}/sendMessage",
                data=fwd_data, headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                result = json.loads(resp.read())
                print(f"Forex alert sent: {result.get('ok')}")
        except Exception as e:
            print(f"Forex forward error: {e}", file=sys.stderr)
    else:
        print("Forex forwarding not configured")
else:
    print("CLEAR")
PY
