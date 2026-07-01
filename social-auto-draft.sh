#!/usr/bin/env bash
set -euo pipefail
source /opt/scripts/tba/tba.env
DAY="${1:-$(date +%u)}"
DATE=$(date +%Y-%m-%d)
DRAFTS="$REPO/paperclip/company/social-drafts"
mkdir -p "$DRAFTS"
# Only run Mon(1), Wed(3), Fri(5)
if [ "$DAY" != "1" ] && [ "$DAY" != "3" ] && [ "$DAY" != "5" ]; then
  echo "Social draft: skipping — not Mon/Wed/Fri (day $DAY)"
  exit 0
fi
# Market context
BTC=$(python3 -c "import json,urllib.request; d=json.load(urllib.request.urlopen('https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true')); b=d['bitcoin']; print(f\"\${b['usd']:,.0f} ({b['usd_24h_change']:+.1f}%)\")" 2>/dev/null || echo "unavailable")
ETH=$(python3 -c "import json,urllib.request; d=json.load(urllib.request.urlopen('https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd&include_24hr_change=true')); e=d['ethereum']; print(f\"\${e['usd']:,.0f} ({e['usd_24h_change']:+.1f}%)\")" 2>/dev/null || echo "")
case "$DAY" in 1) THEME="weekly_outlook" ;; 3) THEME="midweek_lesson" ;; 5) THEME="weekend_wisdom" ;; esac
python3 - "$THEME" "$BTC" "$ETH" "$DATE" "$DRAFTS" <<'PY'
import sys, json, os
theme,b tc,eth,date,drafts_dir = sys.argv[1:]
posts = []
if theme == "weekly_outlook":
    posts = [
        {"id": f"auto-mon-{date}", "platform": "x", "body": f"New trading week. BTC at {btc}. The best traders start Monday with a plan, not a prediction. Know your exit before you enter. Wait for your setup to show itself. Trade what you see on the chart, not what you hope will happen. Discipline this week beats regret next week.", "disclosure": "Not financial advice."},
        {"id": f"auto-mon-b-{date}", "platform": "x", "body": f"Every Monday, the market gives you a fresh start. Last week's losses or wins do not matter. What matters is the next trade. One setup at a time. One decision at a time. Stay small until the chart confirms. Protect your account first. The profits will follow.", "disclosure": "Not financial advice."}
    ]
elif theme == "midweek_lesson":
    posts = [
        {"id": f"auto-wed-{date}", "platform": "x", "body": f"Midweek check. BTC at {btc}. The middle of the week is when discipline gets tested. The Monday motivation fades. The weekend is still far away. This is where traders separate from gamblers. Stick to your rules. Trade your plan. One good decision at a time.", "disclosure": "Not financial advice."},
        {"id": f"auto-wed-b-{date}", "platform": "x", "body": f"A mistake traders make on Wednesday is overtrading to make up for a slow Monday and Tuesday. You do not need to be in a trade every day. Sometimes the best trade is no trade. Wait for your setup. The market will still be there tomorrow.", "disclosure": "Not financial advice."}
    ]
elif theme == "weekend_wisdom":
    posts = [
        {"id": f"auto-fri-{date}", "platform": "x", "body": f"Friday close. BTC at {btc}. Whatever happened this week, you are still in the game. Review your trades. What worked. What did not. Write it down. The weekend is for reflection, not regret. Come back Monday with a clearer mind and a sharper plan.", "disclosure": "Not financial advice."},
        {"id": f"auto-fri-b-{date}", "platform": "threads", "body": f"The end of the trading week is the best time to look back and learn. What was your best decision this week. What was your worst. Write both down. The traders who improve the fastest are the ones who review their own trades honestly — no excuses, no cherry-picking. Just what happened and what to do differently next time. Enjoy your weekend. Come back ready.", "disclosure": "Not financial advice."}
    ]
for p in posts: p["total_chars"] = len(p["body"])
pkg = {"package": f"social-auto-draft-{date}", "created": date, "theme": theme, "market_context": {"btc": btc, "eth": eth}, "status": "draft-only — awaiting owner review", "posts": posts, "approval_instructions": "Review each post. Reply with the exact approval phrase to publish."}
outfile = os.path.join(drafts_dir, f"social-draft-package__auto-{date}.json")
with open(outfile, 'w') as f: json.dump(pkg, f, indent=2)
print(f"DRAFT_SAVED={outfile}")
for p in posts: print(f"POST={p['id']} ({p['platform']}) {p['total_chars']}chars")
PY
DRAFT_FILE=$(ls -t "$DRAFTS"/social-draft-package__auto-"$DATE"*.json 2>/dev/null | head -1)
POST_COUNT=$(python3 -c "import json; print(len(json.load(open('$DRAFT_FILE'))['posts']))" 2>/dev/null || echo "?")
printf "Social draft ready — %s posts\nReview: %s\nReply with approval phrase to publish." "$POST_COUNT" "$DRAFT_FILE" | python3 /opt/scripts/tba/send-telegram.py
echo "Social draft: $POST_COUNT posts saved to $DRAFT_FILE"
