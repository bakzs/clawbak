---
name: ibkr_portfolio
description: Read the latest local IBKR portfolio brief before answering portfolio questions.
---

Use this skill whenever the user asks about portfolio holdings, cash, concentration, portfolio changes, or news tied to current holdings.

Primary files:
1. `/home/usr_13dbakzheeshuen_gmail_com/.openclaw/workspace/portfolio/latest.md`
2. `/home/usr_13dbakzheeshuen_gmail_com/.openclaw/workspace/portfolio/latest.json`

Interpretation rules:
- `latest.md` is the primary human-readable snapshot.
- `latest.json` is the structured version of the same snapshot.
- The files are refreshed by a local scheduled job.
- Treat this as delayed IBKR Flex snapshot data, not a live brokerage feed.
- Do not assume intraday freshness or real-time prices.
- Before making recommendations, check the timestamp in the file.
- If the timestamp looks stale, say so explicitly.
- If data is missing or ambiguous, say that clearly instead of guessing.
- Provide recommendations, risk framing, uncertainty, and what would change the view.
- Do not propose autonomous trading or claim live execution visibility.

Workflow:
1. Read `latest.md` first.
2. If the user wants more detail, read `latest.json`.
3. Mention the report timestamp and whether the data should be treated as delayed snapshot data.
