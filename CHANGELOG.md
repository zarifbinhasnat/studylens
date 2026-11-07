# Changelog

## 0.2.0 — 2026-11-07

- **Subjects & labels window** (menu bar → Subjects & labels…): Overview charts, Recent activity with a type-or-pick
  subject box, and a Subjects editor with "Add with AI". No more editing config.json by hand.
- **Labels you choose stick**: for a specific window always, and for a topic whenever the AI sees it again; corrected
  topics become examples in the AI's prompt.
- **One thing, one label**: a window with a specific title keeps its first label (or yours) instead of being re-judged
  on every screenshot; topics keep their subject; earlier duplicates are merged.
- **Screen Time-style charts** in the widget and the Overview tab, with idle time and entertainment shown separately.
- Activity is named by what you did (page title or chat topic), not by the app.
- Widget stays fully on screen when moved between monitors or when one is unplugged; option to keep it above windows.
- `studylens suggest`, and the installer retries registering the background job.

## 0.1.1 — 2026-11-07

- `studylens setup` keeps all courses in one group instead of making a group per course.

## 0.1.0 — 2026-11-07

First public release.

- Menu-bar app: per-minute sampling, idle detection that respects video and calls, multi-monitor screenshots,
  Chrome incognito and Safari private-window protection, desktop widget, hide-at-places, weekend check-in.
- Analyzer: local labeling with an Ollama vision model, title cache, battery budget, screenshot cleanup.
- `studylens setup`: describe your subjects in your own words, or start from a preset (BCS preliminary included).
- Balance note for weighted subjects (e.g. exam marks).
- Optional Notion sync with `notion-init`.
- One-line installer, uninstaller, release zip.
