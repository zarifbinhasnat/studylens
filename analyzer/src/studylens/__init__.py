"""StudyLens analyzer.

Labels the minutes the StudyLens app records with a local Ollama vision model, writes the summary the
desktop widget shows, and applies the weekend check-in. Everything stays on this Mac.

    studylens setup                 describe what you study in your own words; the local model builds your categories
    studylens setup --preset FILE   start from a preset such as examples/bcs-preliminary.json
    studylens analyze               label new samples, delete their screenshots, write summary.json (run by launchd)
    studylens relabel               use the latest weekend check-in to fix "Other" time this week
    studylens report                print today and the last 7 days
    studylens notion-init PAGE_URL  create the Daily and Weekly tables under a Notion page you shared
    studylens notion                push today to Notion now

Notion sync is optional: it runs when config.json has a "notion" section and the integration token is in the
login Keychain (service "studylens-notion"). Only totals and topics are sent, never titles or screenshots.
"""

import base64
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from pathlib import Path

DATA = Path(os.environ.get("STUDYLENS_DATA", Path.home() / "Library/Application Support/StudyLens"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples(
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, app TEXT, bundle TEXT, title TEXT,
  state TEXT NOT NULL, video INTEGER DEFAULT 0, private INTEGER DEFAULT 0, shot TEXT,
  category TEXT, topic TEXT, activity TEXT, summary TEXT, label_source TEXT);
CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
CREATE TABLE IF NOT EXISTS checkins(id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, reply TEXT NOT NULL, applied INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS title_cache(key TEXT PRIMARY KEY, category TEXT, topic TEXT, activity TEXT, summary TEXT);
"""

ACTIVITIES = ["reading", "watching", "practicing", "writing", "coding", "chatting", "browsing", "other"]
IDLE, PRIVATE = "Idle", "Private browsing"
LABELED = ("ai", "inherit", "cache", "rule", "you")


def load_config():
    return json.loads((DATA / "config.json").read_text())


def connect():
    db = sqlite3.connect(DATA / "studylens.db", timeout=15)
    db.row_factory = sqlite3.Row
    db.executescript("PRAGMA journal_mode=WAL;" + SCHEMA)
    return db


def categories(cfg):
    """Category name -> {group, color, hint, weight}, in config order."""
    return {
        c["name"]: {"group": g["name"], "color": g["color"], "hint": c.get("hint", ""), "weight": c.get("weight")}
        for g in cfg["groups"]
        for c in g["categories"]
    }


def on_ac_power():
    return "AC Power" in subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout


def ollama(cfg, messages, schema):
    body = {
        "model": cfg["model"],
        "messages": messages,
        "stream": False,
        "format": schema,
        "keep_alive": cfg["keep_alive"],
        "options": {"temperature": 0, "num_ctx": 4096},
    }
    req = urllib.request.Request(
        cfg["ollama_url"].rstrip("/") + "/api/chat",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(json.load(r)["message"]["content"])


def category_list(cats):
    return "\n".join(f"- {n}: {c['hint']}" if c["hint"] else f"- {n}" for n, c in cats.items())


def classify(cfg, cats, app, title, shot):
    schema = {
        "type": "object",
        "properties": {
            "category": {"type": "string", "enum": list(cats)},
            "topic": {"type": "string"},
            "activity": {"type": "string", "enum": ACTIVITIES},
            "summary": {"type": "string"},
        },
        "required": ["category", "topic", "activity", "summary"],
    }
    about = f"About them: {cfg['about']}\n\n" if cfg.get("about") else ""
    system = (
        "You label what a person is doing on their Mac, for their own private study-time tracker. "
        + about + "Pick exactly one category:\n" + category_list(cats) + "\n\n"
        "Judge by the actual content on screen (the PDF, page, video, slides or code), not just the app name. "
        "A lecture video or an article that fits a subject belongs to that subject; non-study videos are "
        "Entertainment. Text on screen may be in any language. "
        "topic: the specific subject in at most 6 words, e.g. 'Dijkstra's algorithm' or 'Eigenvalues'. "
        "summary: one short English sentence on what they are doing."
    )
    user = {"role": "user", "content": f"App: {app}\nWindow title: {title or '(none)'}\n"}
    if shot:
        user["content"] += "The screenshot of the screen is attached."
        user["images"] = [base64.b64encode(Path(shot).read_bytes()).decode()]
    else:
        user["content"] += "No screenshot; judge from the app and title only."
    out = ollama(cfg, [{"role": "system", "content": system}, user], schema)
    if out.get("category") not in cats:
        out["category"] = "Other"
    return out


def inherited(db, r):
    """Same window as a minute that was already labeled in the last 30 minutes."""
    return db.execute(
        "SELECT category, topic, activity, summary FROM samples WHERE bundle = ? AND title = ? AND ts < ? AND ts >= ?"
        f" AND label_source IN {LABELED} AND category NOT IN (?, ?) ORDER BY ts DESC LIMIT 1",
        (r["bundle"], r["title"], r["ts"], r["ts"] - 1800, IDLE, PRIVATE),
    ).fetchone()


def analyze(cfg, db):
    cats = categories(cfg)
    budget = None if on_ac_power() else cfg["battery_ai_calls_per_run"]
    calls = 0
    # Wait until a minute can no longer turn into idle time before spending the model on it.
    cutoff = int(time.time()) - int(cfg["idle_minutes"] * 60) - 60
    rows = db.execute("SELECT * FROM samples WHERE label_source IS NULL AND ts < ? ORDER BY ts", (cutoff,)).fetchall()
    for r in rows:
        shot = r["shot"] if r["shot"] and Path(r["shot"]).exists() else None
        if r["state"] == "idle":
            label = (IDLE, "", "other", "", "rule")
        elif r["private"]:
            label = (PRIVATE, "", "browsing", "", "rule")
        elif r["bundle"] in cfg["app_rules"]:
            label = (cfg["app_rules"][r["bundle"]], "", "chatting", "", "rule")
        elif not shot and (prev := inherited(db, r)):
            label = (*prev, "inherit")
        elif not shot and (hit := db.execute(
            "SELECT category, topic, activity, summary FROM title_cache WHERE key = ?", (f"{r['bundle']}|{r['title']}",)
        ).fetchone()):
            label = (*hit, "cache")
        else:
            if budget is not None and calls >= budget:
                break  # on battery: the rest waits for the next run, in order
            try:
                out = classify(cfg, cats, r["app"], r["title"], shot)
            except Exception as e:
                print(f"{datetime.now():%H:%M} model call failed, will retry: {e}", file=sys.stderr)
                break
            calls += 1
            label = (out["category"], out["topic"].strip(), out["activity"], out["summary"].strip(), "ai")
            if not shot:
                db.execute(
                    "INSERT OR REPLACE INTO title_cache VALUES (?, ?, ?, ?, ?)",
                    (f"{r['bundle']}|{r['title']}", *label[:4]),
                )
        keep = cfg["keep_screenshots"] and shot
        db.execute(
            "UPDATE samples SET category = ?, topic = ?, activity = ?, summary = ?, label_source = ?, shot = ? WHERE id = ?",
            (*label, r["shot"] if keep else None, r["id"]),
        )
        db.commit()
        if shot and not keep:
            Path(shot).unlink(missing_ok=True)
    # Screenshots never outlive two days, whatever happened to the analyzer.
    for f in (DATA / "shots").glob("*.jpg"):
        if not cfg["keep_screenshots"] and f.stat().st_mtime < time.time() - 2 * 86400:
            f.unlink(missing_ok=True)
    print(f"{datetime.now():%H:%M} labeled {len(rows)} pending minutes with {calls} model calls")


def minutes(cfg, n):
    return round(n * cfg["sample_seconds"] / 60)


def period(db, since):
    return db.execute("SELECT * FROM samples WHERE ts >= ? ORDER BY ts", (since,)).fetchall()


def unclear_blocks(rows):
    """'Other' minutes grouped by window, biggest first."""
    blocks = defaultdict(list)
    for r in rows:
        if r["category"] == "Other":
            blocks[(r["app"], r["title"] or r["summary"] or "")].append(r["id"])
    return sorted(blocks.items(), key=lambda kv: -len(kv[1]))


def hm(m):
    return f"{m // 60}h {m % 60}m" if m >= 60 else f"{m}m"


def write_summary(cfg, db):
    cats = categories(cfg)
    focus = set(cfg["focus_groups"])
    now = datetime.now()
    today = period(db, int(now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()))
    week = period(db, int((now - timedelta(days=7)).timestamp()))

    active = [r for r in today if r["state"] == "active"]
    by_cat = Counter(r["category"] for r in active if r["category"] in cats)
    focused = sum(n for c, n in by_cat.items() if cats[c]["group"] in focus)
    topics = Counter(
        (r["category"], r["topic"]) for r in active if r["category"] in cats and cats[r["category"]]["group"] in focus and r["topic"]
    )

    # Balance over the last 7 days for one weighted group (e.g. exam subjects by marks):
    # subjects that got far less time than their share of the weight.
    group = cfg.get("balance_group")
    weights = {n: c["weight"] for n, c in cats.items() if c["group"] == group and c["weight"]}
    week_by_cat = Counter(r["category"] for r in week if r["state"] == "active")
    group_total = sum(week_by_cat[n] for n in weights)
    balance_note = ""
    if weights and group_total < 60 / (cfg["sample_seconds"] / 60):
        balance_note = f"{group}: {hm(minutes(cfg, group_total))} in the last 7 days"
    elif weights:
        total_weight = sum(weights.values())
        behind = sorted(
            (n for n in weights if week_by_cat[n] < 0.5 * group_total * weights[n] / total_weight),
            key=lambda n: week_by_cat[n] / weights[n],
        )
        if behind:
            balance_note = f"{group} behind this week: " + ", ".join(n.removeprefix(group + " ") for n in behind[:3])

    week_active = [r for r in week if r["state"] == "active"]
    week_focus = sum(1 for r in week_active if r["category"] in cats and cats[r["category"]]["group"] in focus)
    top_week = Counter(r["category"] for r in week_active if r["category"] in cats).most_common(3)
    lines = [f"Last 7 days: {hm(minutes(cfg, week_focus))} focused. Top: "
             + ", ".join(f"{c} {hm(minutes(cfg, n))}" for c, n in top_week)]
    unclear = unclear_blocks(week_active)[:6]
    if unclear:
        lines.append("\nUnclear time:")
        lines += [f"• {app} · {what[:60]} ({hm(minutes(cfg, len(ids)))})" for (app, what), ids in unclear]

    summary = {
        "updated": now.strftime("%H:%M"),
        "focused_min": minutes(cfg, focused),
        "active_min": minutes(cfg, len(active)),
        "idle_min": minutes(cfg, sum(1 for r in today if r["state"] == "idle")),
        "categories": [
            {"name": c, "color": cats[c]["color"], "min": minutes(cfg, n)} for c, n in by_cat.most_common()
        ],
        "highlights": [f"{c.removeprefix('Course: ')} · {t} ({hm(minutes(cfg, n))})" for (c, t), n in topics.most_common(3)],
        "balance_note": balance_note,
        "checkin_text": "\n".join(lines),
    }
    tmp = DATA / "summary.json.tmp"
    tmp.write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    tmp.replace(DATA / "summary.json")
    return summary


def relabel(cfg, db):
    """Use the latest weekend reply to put this week's unclear minutes where they belong."""
    checkin = db.execute("SELECT * FROM checkins WHERE applied = 0 ORDER BY ts DESC LIMIT 1").fetchone()
    if not checkin:
        print("No new check-in.")
        return
    cats = categories(cfg)
    week = [r for r in period(db, checkin["ts"] - 7 * 86400) if r["state"] == "active"]
    blocks = unclear_blocks(week)[:40]
    if blocks:
        schema = {
            "type": "object",
            "properties": {
                "assignments": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {"block": {"type": "integer"}, "category": {"type": "string", "enum": list(cats)}},
                        "required": ["block", "category"],
                    },
                }
            },
            "required": ["assignments"],
        }
        listing = "\n".join(f"{i}. {app} · {what}" for i, ((app, what), _) in enumerate(blocks))
        prompt = (
            "A person's study tracker could not place some screen time this week. In their own words, this is what "
            f"they did:\n\"{checkin['reply']}\"\n\nCategories:\n{category_list(cats)}\n\nUnclear blocks:\n{listing}\n\n"
            "Assign a category only to blocks that their reply clearly explains. Leave the rest out."
        )
        out = ollama(cfg, [{"role": "user", "content": prompt}], schema)
        moved = 0
        for a in out.get("assignments", []):
            if 0 <= a["block"] < len(blocks) and a["category"] in cats and a["category"] != "Other":
                ids = blocks[a["block"]][1]
                db.executemany("UPDATE samples SET category = ?, label_source = 'you' WHERE id = ?",
                               [(a["category"], i) for i in ids])
                moved += len(ids)
        print(f"Moved {hm(minutes(cfg, moved))} of unclear time using your check-in.")
    db.execute("UPDATE checkins SET applied = 1 WHERE id = ?", (checkin["id"],))
    db.commit()
    summary = write_summary(cfg, db)

    weekly = DATA / "weekly"
    weekly.mkdir(exist_ok=True)
    stamp = datetime.fromtimestamp(checkin["ts"])
    (weekly / f"{stamp:%G-W%V}.md").write_text(
        f"# Week {stamp:%G-W%V}\n\n## Your check-in\n\n{checkin['reply']}\n\n## Tracker\n\n{summary['checkin_text']}\n"
    )
    if "notion" in cfg and notion_token():
        focused = day_totals(cfg, db, checkin["ts"] - 7 * 86400, checkin["ts"])["Focused"]
        try:
            notion_upsert(cfg, cfg["notion"]["weekly_database_id"], "Week", f"{stamp:%G-W%V}", stamp, {
                "Focused": {"number": focused},
                "My reply": rich_text(checkin["reply"]),
                "Tracker summary": rich_text(summary["checkin_text"]),
            })
        except Exception as e:
            print(f"Weekly check-in not sent to Notion: {e}", file=sys.stderr)


# Notion

NOTION_STATE = DATA / "notion_state.json"


def notion_token():
    r = subprocess.run(["security", "find-generic-password", "-s", "studylens-notion", "-w"], capture_output=True, text=True)
    return r.stdout.strip() or None


def notion(method, path, token, body=None):
    req = urllib.request.Request(
        "https://api.notion.com/v1/" + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Notion-Version": "2022-06-28", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def rich_text(s):
    return {"rich_text": [{"text": {"content": s[:1900]}}]} if s else {"rich_text": []}


def notion_upsert(cfg, database_id, title_prop, title, day, props):
    """One row per (database, date): remembered locally, else looked up, else created."""
    token = notion_token()
    state = json.loads(NOTION_STATE.read_text()) if NOTION_STATE.exists() else {}
    key = f"{database_id}:{day:%Y-%m-%d}"
    props = {title_prop: {"title": [{"text": {"content": title}}]}, "Date": {"date": {"start": f"{day:%Y-%m-%d}"}}, **props}
    page_id = state.get(key)
    if not page_id:
        found = notion("POST", f"databases/{database_id}/query", token,
                       {"filter": {"property": "Date", "date": {"equals": f"{day:%Y-%m-%d}"}}, "page_size": 1})["results"]
        page_id = found[0]["id"] if found else None
    if page_id:
        notion("PATCH", f"pages/{page_id}", token, {"properties": props})
    else:
        page_id = notion("POST", "pages", token, {"parent": {"database_id": database_id}, "properties": props})["id"]
    state[key] = page_id
    NOTION_STATE.write_text(json.dumps(state, indent=1))


def day_totals(cfg, db, start, end):
    """Hours per group and what was studied between two timestamps."""
    cats = categories(cfg)
    focus = set(cfg["focus_groups"])
    rows = db.execute("SELECT * FROM samples WHERE ts >= ? AND ts < ?", (start, end)).fetchall()
    active = [r for r in rows if r["state"] == "active"]
    hours = lambda n: round(n * cfg["sample_seconds"] / 3600, 2)
    by_group = Counter(cats[r["category"]]["group"] for r in active if r["category"] in cats)
    by_cat = Counter(r["category"] for r in active if r["category"] in cats and cats[r["category"]]["group"] in focus)
    topics = Counter(
        f"{r['category'].removeprefix('Course: ')} · {r['topic']}"
        for r in active if r["category"] in cats and cats[r["category"]]["group"] in focus and r["topic"]
    )
    out = {g["name"]: hours(by_group[g["name"]]) for g in cfg["groups"]}
    out.update({
        "Focused": hours(sum(by_group[g] for g in focus)),
        "On screen": hours(len(active)),
        "Idle": hours(sum(1 for r in rows if r["state"] == "idle")),
        "Top subjects": ", ".join(f"{c.removeprefix('Course: ')} {hm(minutes(cfg, n))}" for c, n in by_cat.most_common(4)),
        "Studied": "; ".join(t for t, _ in topics.most_common(6)),
    })
    return out


def sync_day(cfg, db, day, balance_note=None):
    start = int(day.timestamp())
    t = day_totals(cfg, db, start, start + 86400)
    # Only the group columns that exist in Notion (made by notion-init); renamed groups would be rejected.
    columns = ["Focused", "On screen", "Idle", *cfg["notion"].get("group_columns", [])]
    props = {k: {"number": t.get(k, 0)} for k in columns}
    props["Top subjects"] = rich_text(t["Top subjects"])
    props["Studied"] = rich_text(t["Studied"])
    if balance_note is not None:
        props["Balance note"] = rich_text(balance_note)
    notion_upsert(cfg, cfg["notion"]["daily_database_id"], "Day", f"{day:%a %-d %b}", day, props)


def sync_notion(cfg, db, summary):
    if "notion" not in cfg or not notion_token():
        return
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    try:
        state = json.loads(NOTION_STATE.read_text()) if NOTION_STATE.exists() else {}
        last = state.get("last_day")
        if last and last != f"{today:%Y-%m-%d}":
            sync_day(cfg, db, datetime.strptime(last, "%Y-%m-%d"))  # final numbers for the day that just ended
        sync_day(cfg, db, today, summary["balance_note"])
        state = json.loads(NOTION_STATE.read_text())
        state["last_day"] = f"{today:%Y-%m-%d}"
        NOTION_STATE.write_text(json.dumps(state, indent=1))
    except Exception as e:
        print(f"{datetime.now():%H:%M} Notion sync failed, will retry: {e}", file=sys.stderr)


def save_config(cfg):
    path = DATA / "config.json"
    if path.exists():
        path.with_name(f"config.backup-{datetime.now():%Y%m%d-%H%M%S}.json").write_text(path.read_text())
    path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")


def notion_init(cfg, page):
    token = notion_token()
    if not token:
        sys.exit("No Notion token: add it with  security add-generic-password -s studylens-notion -a notion -w")
    ids = re.findall(r"[0-9a-f]{32}", page.replace("-", "").lower())
    if not ids:
        sys.exit("Give the URL of the Notion page you shared with your integration.")
    groups = [g["name"] for g in cfg["groups"]]
    number, text = {"number": {}}, {"rich_text": {}}

    def create(title, props):
        body = {"parent": {"type": "page_id", "page_id": ids[-1]}, "title": [{"text": {"content": title}}], "properties": props}
        return notion("POST", "databases", token, body)["id"]

    daily = create("Daily", {
        "Day": {"title": {}}, "Date": {"date": {}}, "Focused": number, "On screen": number, "Idle": number,
        **{g: number for g in groups}, "Top subjects": text, "Studied": text, "Balance note": text,
    })
    weekly = create("Weekly check-ins", {
        "Week": {"title": {}}, "Date": {"date": {}}, "Focused": number, "My reply": text, "Tracker summary": text,
    })
    cfg["notion"] = {"daily_database_id": daily, "weekly_database_id": weekly, "group_columns": groups}
    save_config(cfg)
    print("Created the Daily and Weekly check-ins tables. StudyLens will update them every 10 minutes.")


OTHER_GROUP = {
    "name": "Other", "color": "gray",
    "categories": [
        {"name": "Admin & email", "hint": "Email, forms, payments, files, calendar"},
        {"name": "Chat & social", "hint": "Messaging and social media"},
        {"name": "Entertainment", "hint": "Non-study videos, reels, games, sports, music"},
        {"name": "Other", "hint": "Anything that fits nowhere else or is unclear"},
    ],
}
PALETTE = ["blue", "orange", "purple", "green", "pink", "teal", "yellow", "red"]


def describe_to_groups(cfg, description):
    schema = {
        "type": "object",
        "properties": {
            "about": {"type": "string"},
            "balance_group": {"type": ["string", "null"]},
            "groups": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "categories": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "name": {"type": "string"},
                                    "hint": {"type": "string"},
                                    "weight": {"type": ["number", "null"]},
                                },
                                "required": ["name", "hint"],
                            },
                        },
                    },
                    "required": ["name", "categories"],
                },
            },
        },
        "required": ["about", "groups"],
    }
    prompt = (
        "Turn this description into categories for a private study-time tracker that a vision model will use to "
        "label screenshots.\n\n"
        f"Description:\n\"\"\"\n{description}\n\"\"\"\n\n"
        "Rules:\n"
        "- Make 1 to 4 groups of related things, e.g. 'University', 'Exam prep', 'Projects', 'Work'.\n"
        "- One category per course, subject or project they name; at most 4 words per name; no duplicates.\n"
        "- hint: what that category looks like on screen (topics, book names, websites, tools, languages), "
        "so it can be recognised from a screenshot.\n"
        "- If an exam gives marks or weights per subject, put them in weight and set balance_group to that "
        "group's name; otherwise weight and balance_group are null.\n"
        "- Do not add email, chat, social media, entertainment or 'Other'; those are added automatically.\n"
        "- about: one sentence describing the person and their goals."
    )
    return ollama(cfg, [{"role": "user", "content": prompt}], schema)


def setup(cfg, args):
    groups, about, balance = [], [], None
    if "--preset" in args:
        preset = json.loads(Path(args[args.index("--preset") + 1]).read_text())
        groups += preset["groups"]
        about += [preset.get("about", "")]
        balance = preset.get("balance_group")
        print(f"Preset added: {', '.join(g['name'] for g in preset['groups'])}.")

    print("Describe what you study or work on, in your own words: courses, exams (with marks if you know them),")
    print("projects, languages, anything you want tracked. Finish with an empty line.")
    lines = []
    while (line := input("> ").strip()):
        lines.append(line)
    if lines:
        print("Asking the local model to build your categories…")
        try:
            out = describe_to_groups(cfg, "\n".join(lines))
        except Exception as e:
            sys.exit(f"The model could not be reached ({e}). Is Ollama running and {cfg['model']} downloaded?")
        groups += [g for g in out["groups"] if g["categories"]]
        about += [out["about"]]
        balance = balance or out.get("balance_group")
    if not groups:
        sys.exit("Nothing to set up.")

    seen = {c["name"] for c in OTHER_GROUP["categories"]}
    free = [c for c in PALETTE if c not in {g.get("color") for g in groups}] or PALETTE
    for i, g in enumerate(g for g in groups if "color" not in g):
        g["color"] = free[i % len(free)]
    for g in groups:
        g["categories"] = [c for c in g["categories"] if c["name"] not in seen and not seen.add(c["name"])]
        for c in g["categories"]:
            if not c.get("weight"):
                c.pop("weight", None)
    groups = [g for g in groups if g["categories"]]

    print()
    for g in groups:
        print(f"{g['name']}")
        for c in g["categories"]:
            weight = f" (weight {c['weight']:g})" if c.get("weight") else ""
            print(f"  - {c['name']}{weight}: {c['hint']}")
    print("Other: Admin & email, Chat & social, Entertainment, Other")
    if input("\nSave these categories? [Y/n] ").strip().lower() not in ("", "y", "yes"):
        sys.exit("Nothing changed.")

    cfg["groups"] = groups + [OTHER_GROUP]
    cfg["focus_groups"] = [g["name"] for g in groups]
    cfg["balance_group"] = balance if balance in cfg["focus_groups"] else None
    cfg["about"] = " ".join(a for a in about if a)
    save_config(cfg)
    print("Saved. New minutes are labeled with these categories from now on.")
    if "notion" in cfg and set(cfg["focus_groups"]) - set(cfg["notion"].get("group_columns", [])):
        print("Note: your Notion Daily table has no columns for the new groups; run notion-init on a new page to recreate it.")


def report(cfg, db):
    s = write_summary(cfg, db)
    print(f"Today: {hm(s['focused_min'])} focused, {hm(s['active_min'])} on screen, {hm(s['idle_min'])} idle")
    for c in s["categories"]:
        print(f"  {c['name']:<28} {hm(c['min'])}")
    for h in s["highlights"]:
        print(f"  • {h}")
    if s["balance_note"]:
        print(s["balance_note"])
    print()
    print(s["checkin_text"])


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "analyze"
    cfg, db = load_config(), connect()
    if command == "analyze":
        analyze(cfg, db)
        sync_notion(cfg, db, write_summary(cfg, db))
    elif command == "notion":
        if "notion" not in cfg or not notion_token():
            sys.exit("Notion is not set up yet: see the README, then run  studylens notion-init PAGE_URL")
        sync_notion(cfg, db, write_summary(cfg, db))
        print("Synced today to Notion.")
    elif command == "notion-init" and len(sys.argv) > 2:
        notion_init(cfg, sys.argv[2])
    elif command == "setup":
        setup(cfg, sys.argv[2:])
    elif command == "relabel":
        relabel(cfg, db)
    elif command == "report":
        report(cfg, db)
    else:
        sys.exit(__doc__)
