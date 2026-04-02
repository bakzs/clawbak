Portfolio bot editable source for OpenClaw.

Canonical brief output:
- /home/usr_13dbakzheeshuen_gmail_com/.openclaw/workspace/portfolio/latest.md
- /home/usr_13dbakzheeshuen_gmail_com/.openclaw/workspace/portfolio/latest.json

Current scheduler:
- /etc/cron.d/portfolio-bot
- runs every 4 hours at minute 15
- runtime user: portmon

Rules:
- Do not use /var/lib/portfolio-bot/out anymore
- Do not store API keys or secrets here
- Keep secrets external via env or external config
- Test manually before promoting to live runtime
