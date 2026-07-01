#!/usr/bin/env bash
set -euo pipefail
source /opt/scripts/tba/tba.env
CONFIG="/opt/scripts/tba/crypto-alerts-config.json"
[ -f "$CONFIG" ] || { echo "No config at $CONFIG"; exit 0; }
mkdir -p "$STATE_DIR"
python3 - "$CONFIG" "$STATE_DIR" <<'PY'
import sys,json,os,urllib.request,subprocess
from datetime import datetime,timezone
config_file=sys.argv[1]; state_dir=sys.argv[2]
with open(config_file) as f: config=json.load(f)
dedup_hours=config["settings"].get("dedup_hours",24)
alerts_fired=[]
for pair in config["pairs"]:
    symbol=pair["symbol"]; name=pair["name"]
    try:
        url=f"https://api.binance.us/api/v3/klines?symbol={symbol}&interval=1h&limit=250"
        with urllib.request.urlopen(urllib.request.Request(url,headers={"Accept":"application/json"}),timeout=15) as resp:
            raw=json.loads(resp.read())
    except Exception as e:
        print(f"SKIP {symbol}: {e}",file=sys.stderr); continue
    if not raw or len(raw)<50:
        print(f"SKIP {symbol}: {len(raw)} bars",file=sys.stderr); continue
    closes=[float(c[4]) for c in raw]; highs=[float(c[2]) for c in raw]; lows=[float(c[3]) for c in raw]; volumes=[float(c[5]) for c in raw]
    current=closes[-1]; prev=closes[-2] if len(closes)>1 else current
    ma20=sum(closes[-21:-1])/20 if len(closes)>=21 else sum(closes)/len(closes)
    for alert in pair["alerts"]:
        aid=alert["id"]; atype=alert["type"]; params=alert.get("params",{})
        state_file=os.path.join(state_dir,f"{aid}.txt")
        if os.path.exists(state_file):
            try:
                last=datetime.fromisoformat(open(state_file).read().strip())
                if (datetime.now(timezone.utc)-last).total_seconds()/3600<dedup_hours: continue
            except: pass
        fired=False; reason=""
        if atype=="ma_cross":
            period=params.get("ma_period",20)
            ma_val=sum(closes[-(period+1):-1])/period
            if prev<=sum(closes[-(period+2):-2])/period and current>ma_val:
                fired=True; reason=f"close {current:.2f} crossed above {period}MA {ma_val:.2f}"
        elif atype=="nr7":
            lookback=params.get("lookback",7); max_price=params.get("max_price",None)
            ranges=[highs[i]-lows[i] for i in range(-lookback,0)]
            if len(ranges)>=lookback and all(ranges[-1]<=r for r in ranges[:-1]) and current>ma20 and (max_price is None or current<=max_price):
                fired=True; reason=f"NR7: close {current:.2f} above 20MA {ma20:.2f}"
        elif atype=="price_cross":
            level=params.get("level",0); direction=params.get("direction","cross_above")
            if direction=="cross_above" and prev<=level and current>level:
                fired=True; reason=f"close {current:.2f} crossed above {level}"
        if fired:
            alerts_fired.append({"id":aid,"symbol":symbol,"name":name,"setup":alert.get("setup",""),"message":alert.get("message",""),"reason":reason,"price":current,"ma20":round(ma20,2)})
            with open(state_file,'w') as f: f.write(datetime.now(timezone.utc).isoformat())
if alerts_fired:
    lines=["Crypto Alert — Setup Detected\n"]
    for a in alerts_fired:
        lines.append(f"{a['name']} ({a['symbol']}): {a['message']}")
        lines.append(f"  Setup: {a['setup']} | Price: ${a['price']:.2f} | 20MA: ${a['ma20']}")
        lines.append(f"  {a['reason']}\n")
    lines.append("Paper-only analysis. No execution without owner approval.")
    msg="\n".join(lines)
    subprocess.run(["python3","/opt/scripts/tba/send-telegram.py"],input=msg,text=True)
    # Forward to @Crypto_TBull_bot channel
    fwd_token = os.environ.get("CRYPTO_FWD_BOT_TOKEN", "")
    fwd_chat_id = os.environ.get("CRYPTO_FWD_CHANNEL_ID", "")
    if fwd_token and fwd_chat_id:
        try:
            fwd_data = json.dumps({"chat_id": fwd_chat_id, "text": msg, "disable_web_page_preview": True}).encode()
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{fwd_token}/sendMessage",
                data=fwd_data,
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                pass
        except Exception as e:
            print(f"Crypto forward error: {e}", file=sys.stderr)
else: print("CLEAR")
PY
