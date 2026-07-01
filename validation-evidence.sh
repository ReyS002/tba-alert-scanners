#!/usr/bin/env bash
set -euo pipefail
source /opt/scripts/tba/tba.env
DATE=$(date +%Y-%m-%d)
mkdir -p "$OUTPUT_DIR/market-scans"
docker exec velez-trading-bot-webhook python3 -c "
import sqlite3, json
from collections import defaultdict
db='/app/data/trading_bull_desk.sqlite3'
conn=sqlite3.connect(db); conn.row_factory=sqlite3.Row
rows=conn.execute('''SELECT d.symbol, d.play AS setup_type, d.side, d.location, d.timeframe, o.pnl, o.r_multiple, o.status AS outcome_status FROM decisions d LEFT JOIN trade_outcomes o ON d.alert_ref = o.alert_ref WHERE o.id IS NOT NULL AND o.r_multiple IS NOT NULL ORDER BY d.id DESC''').fetchall()
groups=defaultdict(list)
for r in rows:
    setup=r['setup_type'] or 'unknown'; symbol=r['symbol'] or '?'; location=r['location'] or 'unknown'
    groups[f'{setup}|{symbol}|{location}'].append({'pnl':r['pnl'] or 0, 'r':r['r_multiple'] or 0, 'status':r['outcome_status'] or '?'})
evidence={}
for key,trades in groups.items():
    setup,symbol,location=key.split('|')
    n=len(trades); wins=sum(1 for t in trades if t['pnl']>0)
    wr=wins/n if n>0 else 0
    rvals=sorted([t['r'] for t in trades])
    avg_r=sum(rvals[1:-1])/(len(rvals)-2) if len(rvals)>=5 else (sum(rvals)/len(rvals) if rvals else 0)
    if n<3: grade='BLOCK'; reason=f'insufficient sample: {n} trades'
    elif wr>=0.50 and avg_r>=0.5 and n>=5: grade='PASS'; reason=f'solid: {wr:.0%} WR, {avg_r:.2f}R avg, {n} trades'
    elif wr>=0.25: grade='CAUTION'; reason=f'mixed: {wr:.0%} WR, {avg_r:.2f}R avg, {n} trades'
    else: grade='BLOCK'; reason=f'weak: {wr:.0%} WR, {avg_r:.2f}R avg, {n} trades'
    evidence[key]={'setup_type':setup,'symbol':symbol,'location':location,'sample_size':n,'win_rate':round(wr,3),'avg_r_multiple':round(avg_r,3),'validation_grade':grade,'validation_reason':reason}
all_trades=[t for g in groups.values() for t in g]
total_n=len(all_trades); total_wins=sum(1 for t in all_trades if t['pnl']>0)
result={'source':'velez-bot-journal','global_stats':{'total_trades':total_n,'win_rate':round(total_wins/total_n,3) if total_n>0 else 0,'patterns_tracked':len(evidence)},'patterns':sorted(evidence.values(),key=lambda p:({'PASS':0,'CAUTION':1,'BLOCK':2}.get(p['validation_grade'],9),-p['win_rate']))}
print(json.dumps(result,indent=2,default=str))
conn.close()
" > "$OUTPUT_DIR/market-scans/validation-evidence-$DATE.json" 2>/dev/null
[ ! -s "$OUTPUT_DIR/market-scans/validation-evidence-$DATE.json" ] && { echo "Evidence pipeline: ERROR"; exit 1; }
python3 - "$OUTPUT_DIR/market-scans/validation-evidence-$DATE.json" <<'PY'
import sys,json,subprocess
with open(sys.argv[1]) as f: data=json.load(f)
gs=data['global_stats']; patterns=data['patterns']
passed=[p for p in patterns if p['validation_grade']=='PASS']
blocked=[p for p in patterns if p['validation_grade']=='BLOCK']
lines=[f"Validation Evidence — {len(passed)} patterns ready\n"]
if passed:
    lines.append("READY (PASS):")
    for p in passed[:5]: lines.append(f"  {p['setup_type']}/{p['symbol']}: {p['win_rate']:.0%} WR, {p['avg_r_multiple']:.2f}R ({p['sample_size']} trades)")
    lines.append("")
if blocked: lines.append(f"GATED (BLOCK): {len(blocked)} patterns need more data")
lines.append(f"\nGlobal: {gs['total_trades']} trades, {gs['win_rate']:.1%} WR")
msg="\n".join(lines)
subprocess.run(["python3","/opt/scripts/tba/send-telegram.py"],input=msg,text=True)
PY
