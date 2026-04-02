#!/opt/portfolio-bot/venv/bin/python
import json
import os
import re
import time
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

BASE = Path("/opt/portfolio-bot")
STATE = BASE / "state"
LOGS = BASE / "logs"
OUT = Path("/home/usr_13dbakzheeshuen_gmail_com/.openclaw/workspace/portfolio")
ENV_FILE = BASE / ".env"

os.umask(0o027)

STATE.mkdir(parents=True, exist_ok=True)
LOGS.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)


def load_env(path: Path) -> dict:
    data = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data


CFG = load_env(ENV_FILE)
SESSION = requests.Session()
SESSION.headers.update({"User-Agent": CFG.get("USER_AGENT", "portfolio-bot/1.0")})


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def strip_ns(tag: str) -> str:
    return tag.split("}", 1)[-1]


def first(*vals):
    for v in vals:
        if v not in (None, "", "N/A"):
            return v
    return None


def to_float(val):
    if val in (None, "", "N/A"):
        return None
    s = str(val).strip().replace(",", "")
    if s.startswith("(") and s.endswith(")"):
        s = "-" + s[1:-1]
    try:
        return float(s)
    except ValueError:
        return None


def parse_dt(val: str):
    if not val:
        return None
    try:
        return datetime.fromisoformat(val.replace("Z", "+00:00"))
    except Exception:
        return None


def load_json(path: Path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def write_json(path: Path, obj):
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")


def fetch_flex_report() -> bytes:
    token = CFG["IBKR_FLEX_TOKEN"]
    query_id = CFG["IBKR_FLEX_QUERY_ID"]
    base_url = "https://ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService"

    send = SESSION.get(
        f"{base_url}/SendRequest",
        params={"t": token, "q": query_id, "v": 3},
        timeout=60,
    )
    send.raise_for_status()

    root = ET.fromstring(send.text)
    status = root.findtext("Status")
    if status != "Success":
        error = root.findtext("ErrorMessage") or send.text
        raise RuntimeError(f"IBKR /SendRequest failed: {error}")

    ref_code = root.findtext("ReferenceCode")
    if not ref_code:
        raise RuntimeError("IBKR /SendRequest succeeded but returned no ReferenceCode")

    for attempt in range(24):
        time.sleep(5 if attempt else 3)
        get_stmt = SESSION.get(
            f"{base_url}/GetStatement",
            params={"t": token, "q": ref_code, "v": 3},
            timeout=60,
        )
        get_stmt.raise_for_status()

        try:
            root2 = ET.fromstring(get_stmt.content)
        except ET.ParseError:
            return get_stmt.content

        tag = strip_ns(root2.tag)

        # A real Flex report usually has a top-level report root, not FlexStatementResponse
        if tag != "FlexStatementResponse":
            return get_stmt.content

        status2 = root2.findtext("Status") or "Fail"
        err = (root2.findtext("ErrorMessage") or "").lower()

        if status2 == "Fail" and any(x in err for x in ["progress", "not ready", "please wait", "generation"]):
            continue

        if status2 == "Fail":
            raise RuntimeError(f"IBKR /GetStatement failed: {root2.findtext('ErrorMessage') or 'unknown error'}")

    raise RuntimeError("IBKR Flex report did not become available in time")


def ensure_daily_flex() -> bytes:
    xml_path = STATE / "ibkr_latest.xml"
    meta_path = STATE / "flex_meta.json"
    meta = load_json(meta_path, {})
    today = now_utc().date().isoformat()

    if xml_path.exists() and meta.get("date") == today:
        return xml_path.read_bytes()

    report = fetch_flex_report()
    xml_path.write_bytes(report)
    write_json(meta_path, {"date": today, "fetched_at": iso(now_utc())})
    return report


def parse_flex(xml_bytes: bytes) -> dict:
    root = ET.fromstring(xml_bytes)

    positions = []
    cash = defaultdict(float)
    seen = set()

    for elem in root.iter():
        tag = strip_ns(elem.tag)
        attrs = {k.lower(): v for k, v in elem.attrib.items()}

        # Position parsing
        symbol = (attrs.get("symbol") or attrs.get("underlyingsymbol") or "").strip()
        qty_raw = first(attrs.get("position"), attrs.get("quantity"), attrs.get("currentquantity"))
        qty = to_float(qty_raw)

        if symbol and qty is not None and abs(qty) > 0:
            market_value = to_float(
                first(
                    attrs.get("marktomarketvalue"),
                    attrs.get("positionvalue"),
                    attrs.get("marketvalue"),
                    attrs.get("value"),
                    attrs.get("netassetvalue"),
                )
            )
            mark_price = to_float(first(attrs.get("markprice"), attrs.get("price"), attrs.get("closeprice"), attrs.get("unitprice")))
            unrealized = to_float(first(
                attrs.get("unrealizedpl"),
                attrs.get("unrealizedpnl"),
                attrs.get("mtmpl"),
                attrs.get("fifo_unrealized_pl"),
                attrs.get("pl")
            ))
            avg_cost = to_float(first(
                attrs.get("avgcost"),
                attrs.get("averagecost"),
                attrs.get("costprice"),
                attrs.get("costbasisprice"),
                attrs.get("costbasis"),
                attrs.get("cost")
            ))
            if avg_cost is None and market_value is not None and unrealized is not None and qty not in (None, 0):
                try:
                    avg_cost = (market_value - unrealized) / qty
                except ZeroDivisionError:
                    avg_cost = None
            cost_basis = None
            if avg_cost is not None and qty is not None:
                cost_basis = avg_cost * qty

            asset = first(attrs.get("assetcategory"), attrs.get("assetclass"), attrs.get("securitytype"), tag) or tag
            description = first(attrs.get("description"), attrs.get("issuer"), attrs.get("name")) or ""

            key = (symbol, asset, qty, market_value)
            if re.search(r"[A-Za-z]", symbol) and key not in seen:
                positions.append(
                    {
                        "symbol": symbol.upper(),
                        "description": description,
                        "asset": asset,
                        "quantity": qty,
                        "market_value": market_value,
                        "mark_price": mark_price,
                        "avg_cost": avg_cost,
                        "cost_basis": cost_basis,
                        "unrealized_pnl": unrealized,
                    }
                )
                seen.add(key)

        # Cash parsing
        currency = (attrs.get("currency") or "").strip().upper()
        cash_raw = first(
            attrs.get("endingcash"),
            attrs.get("endingcashbal"),
            attrs.get("endingcashbalance"),
            attrs.get("cash"),
            attrs.get("settledcash"),
            attrs.get("totalcashvalue"),
        )
        cash_val = to_float(cash_raw)
        if currency and cash_val is not None and "cash" in tag.lower():
            cash[currency] += cash_val

    # Sort by market value desc, then abs(quantity)
    positions.sort(key=lambda x: ((x["market_value"] or 0.0), abs(x["quantity"] or 0.0)), reverse=True)

    total_mv = sum(abs(p["market_value"]) for p in positions if p["market_value"] is not None)
    for p in positions:
        mv = p["market_value"]
        p["weight"] = (abs(mv) / total_mv) if (mv is not None and total_mv > 0) else None

    return {"positions": positions, "cash": dict(sorted(cash.items()))}


def watched_symbols(positions):
    allow = [x.strip().upper() for x in CFG.get("SYMBOL_ALLOWLIST", "").split(",") if x.strip()]
    if allow:
        return allow

    max_symbols = int(CFG.get("MAX_NEWS_SYMBOLS", "5"))
    symbols = []
    for p in positions:
        sym = (p.get("symbol") or "").upper()
        asset = (p.get("asset") or "").upper()

        if not re.fullmatch(r"[A-Z0-9.\-]{1,15}", sym):
            continue
        if any(x in asset for x in ["OPT", "OPTION", "FUT", "FOREX", "CASH"]):
            continue

        symbols.append((abs(p.get("market_value") or 0.0), sym))

    out = []
    seen = set()
    for _, sym in sorted(symbols, reverse=True):
        if sym not in seen:
            out.append(sym)
            seen.add(sym)
        if len(out) >= max_symbols:
            break
    return out


def fetch_marketaux_news(symbols):
    token = CFG.get("MARKETAUX_API_TOKEN", "").strip()
    if not token:
        return []

    lookback_hours = int(CFG.get("NEWS_LOOKBACK_HOURS", "24"))
    published_after = (now_utc() - timedelta(hours=lookback_hours)).strftime("%Y-%m-%dT%H:%M")
    seen_state_path = STATE / "seen_news.json"
    seen = set(load_json(seen_state_path, []))

    collected = []

    for sym in symbols:
        resp = SESSION.get(
            "https://api.marketaux.com/v1/news/all",
            params={
                "api_token": token,
                "symbols": sym,
                "filter_entities": "true",
                "must_have_entities": "true",
                "language": "en",
                "limit": 3,
                "published_after": published_after,
            },
            timeout=60,
        )

        if resp.status_code == 402:
            break  # plan usage limit reached for the day
        resp.raise_for_status()

        payload = resp.json()
        for item in payload.get("data", []):
            uuid = item.get("uuid")
            if not uuid or uuid in seen:
                continue

            match_entity = {}
            for entity in item.get("entities", []):
                if (entity.get("symbol") or "").upper() == sym:
                    match_entity = entity
                    break

            sentiment = float(match_entity.get("sentiment_score") or 0.0)
            match_score = float(match_entity.get("match_score") or 0.0)
            published_at = parse_dt(item.get("published_at"))
            age_hours = lookback_hours
            if published_at:
                age_hours = max((now_utc() - published_at).total_seconds() / 3600.0, 0.0)

            score = abs(sentiment) * 2.0 + min(match_score / 25.0, 2.0) + max(0.0, 1.5 - age_hours / max(lookback_hours, 1))

            collected.append(
                {
                    "uuid": uuid,
                    "symbol": sym,
                    "title": item.get("title"),
                    "description": item.get("description"),
                    "url": item.get("url"),
                    "source": item.get("source"),
                    "published_at": item.get("published_at"),
                    "sentiment_score": sentiment,
                    "match_score": match_score,
                    "score": round(score, 3),
                }
            )
            seen.add(uuid)

    # retain a bounded seen-set
    seen_list = list(seen)[-5000:]
    write_json(seen_state_path, seen_list)

    collected.sort(key=lambda x: x["score"], reverse=True)
    return collected


def build_actions(positions, news):
    actions = []

    for p in positions[:10]:
        w = p.get("weight")
        if w is not None and w >= 0.25:
            actions.append({
                "type": "concentration",
                "symbol": p["symbol"],
                "message": f'{p["symbol"]} is a high concentration position at about {w:.1%} of reported market value.'
            })

    for n in news[:10]:
        if n["sentiment_score"] <= -0.25 and n["score"] >= 2.0:
            actions.append({
                "type": "negative_news",
                "symbol": n["symbol"],
                "message": f'Negative news signal on {n["symbol"]}: "{n["title"]}"'
            })

    if not actions:
        actions.append({
            "type": "none",
            "symbol": None,
            "message": "No high-priority action candidates from the current free-data ruleset."
        })

    return actions[:10]


def write_outputs(parsed, news, actions):
    generated_at = iso(now_utc())
    flex_meta = load_json(STATE / "flex_meta.json", {})
    flex_fetched_at = flex_meta.get("fetched_at", "unknown")

    payload = {
        "generated_at": generated_at,
        "holdings_fetched_at": flex_fetched_at,
        "positions": parsed["positions"],
        "cash": parsed["cash"],
        "news": news,
        "actions": actions,
        "notes": [
            "Holdings come from IBKR Activity Flex and are end-of-day style data, not live positions.",
            "News comes from free sources and is incomplete by construction.",
            "This report is decision support, not trading automation."
        ],
    }

    latest_json = OUT / "latest.json"
    write_json(latest_json, payload)

    lines = []
    lines.append("# Portfolio brief")
    lines.append("")
    lines.append(f"- Generated at: `{generated_at}`")
    lines.append(f"- Holdings snapshot fetched at: `{flex_fetched_at}`")
    lines.append("- Data mode: `daily IBKR holdings + free news`")
    lines.append("")

    lines.append("## Top positions")
    lines.append("")
    if parsed["positions"]:
        for p in parsed["positions"][:10]:
            mv = "n/a" if p["market_value"] is None else f'{p["market_value"]:,.2f}'
            wt = "n/a" if p["weight"] is None else f'{p["weight"]:.1%}'
            cb = "n/a" if p.get("cost_basis") is None else f'{p["cost_basis"]:,.2f}'
            upl = "n/a" if p.get("unrealized_pnl") is None else f'{p["unrealized_pnl"]:,.2f}'
            ac = "n/a" if p.get("avg_cost") is None else f'{p["avg_cost"]:,.4f}'
            lines.append(f'- **{p["symbol"]}** | qty `{p["quantity"]}` | MV `{mv}` | cost basis `{cb}` | UPL `{upl}` | avg cost `{ac}` | weight `{wt}` | asset `{p["asset"]}`')
    else:
        lines.append("- No positions parsed from Flex XML.")
    lines.append("")

    lines.append("## Cash")
    lines.append("")
    if parsed["cash"]:
        for ccy, amt in parsed["cash"].items():
            lines.append(f"- **{ccy}**: `{amt:,.2f}`")
    else:
        lines.append("- No cash rows parsed.")
    lines.append("")

    lines.append("## New / high-signal news")
    lines.append("")
    if news:
        for n in news[:15]:
            sent = f'{n["sentiment_score"]:+.3f}'
            lines.append(
                f'- **{n["symbol"]}** | score `{n["score"]}` | sentiment `{sent}` | {n["title"]} ({n["source"]}, {n["published_at"]})'
            )
            if n.get("url"):
                lines.append(f'  - {n["url"]}')
    else:
        lines.append("- No new news items in the current lookback window.")
    lines.append("")

    lines.append("## Action candidates")
    lines.append("")
    for a in actions:
        sym = a["symbol"] or "portfolio"
        lines.append(f'- **{sym}**: {a["message"]}')
    lines.append("")

    lines.append("## Constraints")
    lines.append("")
    lines.append("- Not a live quote feed.")
    lines.append("- Free news coverage is incomplete.")
    lines.append("- Recommendations require human review.")

    latest_md = OUT / "latest.md"
    latest_md.write_text("\n".join(lines) + "\n")

    # convenience copies with timestamp
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    (OUT / f"brief_{stamp}.md").write_text(latest_md.read_text())
    write_json(OUT / f"brief_{stamp}.json", payload)


def main():
    xml_bytes = ensure_daily_flex()
    parsed = parse_flex(xml_bytes)
    symbols = watched_symbols(parsed["positions"])
    news = fetch_marketaux_news(symbols)
    actions = build_actions(parsed["positions"], news)
    write_outputs(parsed, news, actions)
    print(f"OK: wrote {OUT / 'latest.md'} and {OUT / 'latest.json'}")


if __name__ == "__main__":
    main()
