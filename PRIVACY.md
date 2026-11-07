# Privacy

StudyLens watches your screen, so here is exactly what it does with that.

## What stays on your Mac

Everything, by default. StudyLens has no server, no account and no analytics.

| Data | Where | How long |
|---|---|---|
| Front app and window title, once a minute | `~/Library/Application Support/StudyLens/studylens.db` | Until you delete it |
| Screenshots of the display you are working on | `…/StudyLens/shots/` | Deleted as soon as they are labeled; never more than 2 days |
| AI labels (subject, topic, one-line summary) | `studylens.db` | Until you delete it |
| Your weekend check-in replies | `studylens.db` and `…/StudyLens/weekly/` | Until you delete it |

The AI model runs locally in [Ollama](https://ollama.com). Screenshots are sent only to `127.0.0.1:11434`
(Ollama on your own Mac).

## What is never recorded

- Chrome incognito and Safari private windows: no title, no screenshot. If StudyLens cannot check (for example
  before you allow Accessibility), it treats every Safari window as private.
- Apps in `no_screenshot_apps` (WhatsApp, Messages, Passwords, password managers, System Settings by default).
- Anything while the screen is locked or asleep, or while tracking is paused from the menu.

## What can leave your Mac

Only if you set up Notion sync: daily totals per group, your top subjects, short topic names, and your
weekend check-in reply are written to your own Notion workspace through your own integration token
(stored in your macOS Keychain). Window titles and screenshots are never sent.

## Location

Only used if you add a place to `hide_widget_at` with coordinates. StudyLens keeps a yes/no ("am I at one of
these places?") in memory and never stores or sends your location.

## Deleting everything

Run `uninstall.sh` and answer yes to deleting your data, or remove `~/Library/Application Support/StudyLens`.
