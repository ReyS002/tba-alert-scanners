#!/usr/bin/env bash
set -euo pipefail
source /opt/scripts/tba/tba.env
DATE=$(date +%Y-%m-%d)
mkdir -p "$OUTPUT_DIR/market-scans"
JOURNAL=$(docker exec velez-trading-bot-webhook python3 -c "
import sqlite3, json
from datetime import datetime, timezone, timedelta
db='/app/data/trading_bull_desk.sqlite3'
conn=sqlite3.connect(db); conn.row_factory=sqlite3.Row
exposure=[dict(r) for r in conn.execute('SELECT symbol,side,play,entry_price,stop_price,qty,timeframe,location,timestamp FROM decisions WHERE status IN ("accepted","submitted") ORDER BY id DESC LIMIT 10')]
today=(datetime.now(timezone.utc)-timedelta(hours=24)).isoformat()
decisions=[]
for r in conn.execute('SELECT * FROM decisions WHERE timestamp > ? ORDER BY id DESC LIMIT 50',(today,)):
    d=dict(r)
    for k in list(d.keys()):
        if isinstance(d[k],str) and len(d[k])>200: d[k]=d[k][:200]
    decisions.append(d)
outcomes=[dict(r) for r in conn.execute('SELECT * FROM trade_outcomes ORDER BY id DESC LIMIT 20')]
watchlist=[dict(r) for r in conn.execute('SELECT * FROM watchlist WHERE enabled=1')]
print(json.dumps({'exposure':exposure[:5],'decisions_today':len(decisions),'recent_decisions':decisions[:5],'outcomes':outcomes[:5],'watchlist_count':len(watchlist),'watchlist':[w['symbol'] for w in watchlist]},indent=2,default=str))
conn.close()
" 2>/dev/null)
[ -z "$JOURNAL" ] && { echo "ERROR: could not read bot journal"; exit 1; }
echo "$JOURNAL" > "$OUTPUT_DIR/market-scans/velez-bot-journal-$DATE.json"
python3 - "$JOURNAL" "$DATE" <<'PY'
import sys,json,subprocess,os
data=json.loads(sys.argv[1]);date=sys.argv[2]
exposure=data.get("exposure",[]); outcomes=data.get("outcomes",[])
lines=[f"Velez Bot Daily Brief — {date}\n"]
if exposure:
    lines.append("ACTIVE POSITIONS:")
    for e in exposure:
        lines.append(f"  {e.get('symbol','?')} {e.get('side','?').upper()} | {e.get('play','?')} | Entry:{e.get('entry_price','?')} | Stop:{e.get('stop_price','?')} | Qty:{e.get('qty','?')}")
    lines.append("")
else: lines.append("No active positions.\n")
lines.append(f"Decisions today: {data.get('decisions_today',0)}")
lines.append(f"Watchlist: {len(data.get('watchlist',[]))} symbols")
if outcomes:
    lines.append("\nRECENT OUTCOMES:")
    total=0
    for o in outcomes[:5]:
        sym=o.get("symbol","?");pnl=o.get("pnl",0) or 0;r=o.get("r_multiple",0) or 0
        total+=pnl
        lines.append(f"  {sym}: {o.get('status','?')} | PnL:${pnl:.2f} | R:{r:.2f}")
    lines.append(f"  Total PnL: ${total:.2f}")
lines.append("\nPaper-only. Read-only bridge.")
msg="\n".join(lines)
subprocess.run(["python3","/opt/scripts/tba/send-telegram.py"],input=msg,text=True)
PY
