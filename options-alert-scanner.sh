#!/usr/bin/env bash
# Options Alert Scanner — sends to @Options_TBull_bot channel
# Uses TBE's Tradier-powered options chains + Velez bar filters
# Credentials: set OPTIONS_FWD_BOT_TOKEN and OPTIONS_FWD_CHANNEL_ID in tba.env
set -euo pipefail
export PATH="/usr/local/lib/hermes-agent/venv/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/tba.env" 2>/dev/null || true
source /root/.hermes/.env 2>/dev/null || true

CONFIG="${1:-$SCRIPT_DIR/options-alerts-config.json}"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/state}"
DEDUP_HOURS="${DEDUP_HOURS:-24}"
CHANNEL_ID="${OPTIONS_FWD_CHANNEL_ID:-}"

# Token: try env var first, fall back to credential file
BOT_TOKEN="${OPTIONS_FWD_BOT_TOKEN:-}"
if [ -z "$BOT_TOKEN" ] && [ -f "/root/.hermes/credentials/options-tbull-bot.token" ]; then
    BOT_TOKEN="$(cat /root/.hermes/credentials/options-tbull-bot.token)"
fi

if [ -z "$BOT_TOKEN" ] || [ -z "$CHANNEL_ID" ]; then
    echo "SKIP: OPTIONS_FWD_BOT_TOKEN or OPTIONS_FWD_CHANNEL_ID not set"
    exit 0
fi
[ -f "$CONFIG" ] || { echo "No config at $CONFIG"; exit 0; }
mkdir -p "$STATE_DIR"

cd /opt/stacks/tbe
python3 - "$CONFIG" "$STATE_DIR" "$DEDUP_HOURS" "$BOT_TOKEN" "$CHANNEL_ID" << 'PYEOF'
import sys, json, os, urllib.request
from datetime import datetime, timezone, timedelta

config_file = sys.argv[1]
state_dir = sys.argv[2]
dedup_hours = int(sys.argv[3])
bot_token = sys.argv[4]
channel_id = sys.argv[5]

with open(config_file) as f:
    config = json.load(f)

alerts_fired = []
now = datetime.now(timezone.utc)

sys.path.insert(0, "/opt/stacks/tbe")
from tbe.market_data import get_option_chain, get_call_chain
from tbe.scanner import scan_put_opportunities
from tbe.call_scanner import scan_call_opportunities
from tbe.velez import VelezLocation, get_velez_location

def get_location(ticker: str) -> VelezLocation:
    """Compute Velez bar location from recent price data. Falls back to NEAR_SMA."""
    try:
        import yfinance as yf
        df = yf.download(ticker, period="5d", interval="1h", progress=False)
        if isinstance(df.columns, pd.MultiIndex):
            df.columns = df.columns.droplevel(1)
        if len(df) >= 20:
            return get_velez_location(df)
    except Exception:
        pass
    return VelezLocation(location="location_1_near_sma", color="green", sma20=0.0, sma200=0.0, distance_to_sma20_pct=0.0)

def dedup_ok(alert_id):
    state_file = os.path.join(state_dir, f"{alert_id}.txt")
    if os.path.exists(state_file):
        try:
            with open(state_file) as sf:
                last_ts = sf.read().strip()
                last_dt = datetime.fromisoformat(last_ts)
                if (now - last_dt).total_seconds() < dedup_hours * 3600:
                    return False
        except Exception:
            pass
    with open(state_file, "w") as sf:
        sf.write(now.isoformat())
    return True

def send_telegram(msg):
    try:
        body = json.dumps({"chat_id": channel_id, "text": msg[:3900], "disable_web_page_preview": True}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{bot_token}/sendMessage",
            data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
            return result.get("ok", False)
    except Exception as e:
        print(f"Telegram send error: {e}", file=sys.stderr)
        return False

def format_alert(opp, ticker, opt_type):
    tier = opp.get("tier", "Solid")
    tier_emoji = {"Legendary": "\U0001f525", "Epic": "\u26a1", "Solid": "\U0001f4ca"}.get(tier, "\U0001f4ca")
    direction_emoji = "\U0001f7e2" if opt_type == "call" else "\U0001f534"
    direction_label = "CALL" if opt_type == "call" else "PUT"
    # Scanner returns roi_annualized / yield_annualized; format_alert uses the old key as fallback
    if opt_type == "put":
        metric_val = opp.get("roi_annualized", opp.get("annualized_roi", 0))
    else:
        metric_val = opp.get("yield_annualized", opp.get("annualized_yield", 0))
    # Scanner returns 'premium'; old key 'mid' kept as fallback for any external callers
    premium_val = opp.get("premium", opp.get("mid", 0))
    lines = [
        f"{tier_emoji} *{ticker} {direction_emoji} {direction_label} \u2014 {tier}*",
        f"",
        f"\u2022 Strike: ${opp['strike']:.2f}",
        f"\u2022 Expiration: {opp.get('dte', '?')}d ({opp.get('expiration', '?')})",
        f"\u2022 Premium: ${premium_val:.2f}",
        f"\u2022 Scenario Metric Estimate: {metric_val:.1f}% annualized",
        f"\u2022 Delta: {opp.get('delta', 0):.2f}",
        f"\u2022 IV Rank: {opp.get('iv_rank', 0):.0f}%",
        f"\u2022 Spot: ${opp.get('spot', 0):.2f}",
        f"\u2022 Location: {opp.get('location', '?')}",
        f"",
        f"Scanner Status: CONDITION_CONFIRMED",
        f"User Action: USER_REVIEW_REQUIRED",
        f"",
        f"_Educational scanner alert \u2014 not a trade recommendation. TBE provides user-controlled submission workflows only. Users are responsible for reviewing every setup, determining suitability, and managing risk._",
    ]
    return "\n".join(lines)

# ── Phase 1: Scan all tickers, collect qualifying opportunities ──────────
all_put_opps = []
all_call_opps = []
scan_errors = []

for ticker_cfg in config.get("tickers", []):
    ticker = ticker_cfg["symbol"]
    try:
        if ticker_cfg.get("scan_puts", True):
            spot, puts_df = get_option_chain(ticker.upper())
            if not puts_df.empty and len(puts_df) >= 5:
                location = get_location(ticker.upper())
                opps = scan_put_opportunities(
                    ticker=ticker, spot=spot, puts_df=puts_df,
                    location=location,
                    min_roi=float(ticker_cfg.get("min_roi", 15)),
                    min_premium=float(ticker_cfg.get("min_premium", 0.10)),
                    max_abs_delta=float(ticker_cfg.get("max_delta", 0.35)),
                )
                all_put_opps.extend(opps)

        if ticker_cfg.get("scan_calls", True):
            spot, calls_df = get_call_chain(ticker.upper())
            if not calls_df.empty and len(calls_df) >= 5:
                location = get_location(ticker.upper())
                opps = scan_call_opportunities(
                    ticker=ticker, spot=spot, calls_df=calls_df,
                    location=location,
                    min_yield=float(ticker_cfg.get("min_yield", 15)),
                    min_premium=float(ticker_cfg.get("min_premium", 0.10)),
                    max_abs_delta=float(ticker_cfg.get("max_delta", 0.35)),
                )
                all_call_opps.extend(opps)
    except Exception as e:
        scan_errors.append(f"{ticker}: {e}")

if scan_errors:
    print(f"Scan errors: {'; '.join(scan_errors)}", file=sys.stderr)
print(f"Scanned: {len(all_put_opps)} put opportunities, {len(all_call_opps)} call opportunities across {len(config.get('tickers',[]))} tickers")

# ── Phase 2: Bull IQ picks the best candidate per side ────────────────────
from tbe.bull_iq import get_bull_iq_pick, get_bull_iq_call_pick

bull_picks = []  # [(opt_type, full_opp_dict, rationale, avoid_str)]

if all_put_opps:
    try:
        pick = get_bull_iq_pick(all_put_opps)
        if pick:
            full = next((o for o in all_put_opps
                         if str(o.get("ticker","")).upper() == str(pick.get("ticker","")).upper()
                         and abs(o.get("strike",0) - pick.get("strike",0)) < 0.01
                         and str(o.get("expiration","")) == str(pick.get("expiration",""))), None)
            if full:
                bull_picks.append(("put", full, pick.get("rationale", ""), pick.get("avoid", "")))
                print(f"Bull IQ put pick: {pick.get('ticker')} {pick.get('strike')} {pick.get('tier')}")
            else:
                print("Bull IQ put pick not found in scan results — falling back to top ROI", file=sys.stderr)
                best = all_put_opps[0]  # Already sorted by ROI desc
                bull_picks.append(("put", best, "", ""))
        else:
            print("Bull IQ returned no put pick — falling back to top ROI", file=sys.stderr)
            if all_put_opps:
                bull_picks.append(("put", all_put_opps[0], "", ""))
    except Exception as e:
        print(f"Bull IQ put error: {e} — falling back to top ROI", file=sys.stderr)
        if all_put_opps:
            bull_picks.append(("put", all_put_opps[0], "", ""))

if all_call_opps:
    try:
        pick = get_bull_iq_call_pick(all_call_opps)
        if pick:
            full = next((o for o in all_call_opps
                         if str(o.get("ticker","")).upper() == str(pick.get("ticker","")).upper()
                         and abs(o.get("strike",0) - pick.get("strike",0)) < 0.01
                         and str(o.get("expiration","")) == str(pick.get("expiration",""))), None)
            if full:
                bull_picks.append(("call", full, pick.get("rationale", ""), pick.get("avoid", "")))
                print(f"Bull IQ call pick: {pick.get('ticker')} {pick.get('strike')} {pick.get('tier')}")
            else:
                print("Bull IQ call pick not found in scan results — falling back to top yield", file=sys.stderr)
                best = all_call_opps[0]
                bull_picks.append(("call", best, "", ""))
        else:
            print("Bull IQ returned no call pick — falling back to top yield", file=sys.stderr)
            if all_call_opps:
                bull_picks.append(("call", all_call_opps[0], "", ""))
    except Exception as e:
        print(f"Bull IQ call error: {e} — falling back to top yield", file=sys.stderr)
        if all_call_opps:
            bull_picks.append(("call", all_call_opps[0], "", ""))

# ── Phase 3: Format and send ──────────────────────────────────────────────
for opt_type, opp, rationale, avoid_str in bull_picks:
    ticker = opp.get("ticker", "?")
    aid = f"opt_{ticker}_{opt_type}_{opp.get('strike',0)}_{opp.get('expiration','?')}"
    if dedup_ok(aid):
        msg = format_alert(opp, ticker, opt_type)
        if rationale:
            msg += f"\n\n_Bull IQ Analysis: {rationale}_"
        if avoid_str:
            msg += f"\n\n_Also considered: {avoid_str}_"
        ok = send_telegram(msg)
        alerts_fired.append({"id": aid, "sent": ok, "tier": opp.get("tier"), "bull_iq": bool(rationale)})

sent = sum(1 for a in alerts_fired if a["sent"])
if alerts_fired:
    tiers = {}
    for a in alerts_fired:
        tiers[a["tier"]] = tiers.get(a["tier"], 0) + 1
    ts = " | ".join(f"{v} {k}" for k, v in tiers.items())
    print(f"Options scan: {sent}/{len(alerts_fired)} sent. {ts}")
else:
    print("CLEAR")
PYEOF
