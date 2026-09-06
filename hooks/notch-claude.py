#!/usr/bin/env python3
"""Tell the notch that a Claude Code tab changed state.

Runs on SessionStart, Stop, and the two Notification kinds, in every session. The state is
passed as argv[1] rather than sniffed out of the payload, because settings.json already has to
register each event separately to give it a matcher -- so the event name is known at the point
of registration and there is nothing to infer.

Always exits 0. A Stop hook that exits 2 actively prevents Claude from stopping, which is the
exact opposite of the intent here.
"""
import json, os, subprocess, sys, urllib.parse

state = sys.argv[1] if len(sys.argv) > 1 else "done"

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}

# Don't resurrect a notch that was quit on purpose: `open` on a URL would launch it.
if subprocess.run(["pgrep", "-x", "boringNotch"], capture_output=True).returncode != 0:
    sys.exit(0)


def session_title():
    """Claude Code's own name for this session.

    It writes an `ai-title` entry into the transcript -- the same short phrase it puts in the
    terminal tab -- which is the one label that is both task-derived and already short enough
    for a notch. Nothing else here needs the transcript, so this reads only that one field and
    pre-filters on a substring so a large transcript costs a scan rather than a parse.

    Absent on a brand new session, because the title is generated after the first exchange;
    the fallbacks below cover that.
    """
    path = payload.get("transcript_path")
    if not path:
        return ""
    title = ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"ai-title"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("type") == "ai-title" and entry.get("aiTitle"):
                    title = entry["aiTitle"].strip()
    except OSError:
        return ""
    return title


def gist():
    """One short line saying what this tab was doing.

    The directory is nearly useless as a tab label here -- almost every session is launched
    from ~/Documents, so the basename is "Documents" for all of them at once, which is the
    one thing it must not be. What actually distinguishes three tabs is what each was asked
    to do, and the closest thing to that in the payload is the last thing each one said.
    """
    for key in ("last_assistant_message", "message"):
        text = payload.get(key)
        if isinstance(text, str) and text.strip():
            line = next((l.strip() for l in text.splitlines() if l.strip()), "")
            line = line.lstrip("#*->` ").strip()
            # Left long on purpose: the app does the trimming, on a word boundary, and
            # doing it twice would cut twice.
            return line[:120]
    return ""


# An explicit name always wins: `export NOTCH_TAB=scraper` in a tab labels it for good.
where = os.path.basename(payload.get("cwd") or os.getcwd())
# "Documents" is where nearly every session is launched, so as a tab label it names all of
# them at once. Home and root are the same problem. Anything else is genuinely distinguishing
# and worth showing ahead of the gist.
if where in ("Documents", os.path.basename(os.path.expanduser("~")), "", "/"):
    where = ""

# In preference order: a name set by hand, then the name Claude gave the session, then
# what it last said, then where it is running. Each fallback is strictly worse at answering
# "which tab", and each is there only because the one above it can be missing.
label = (os.environ.get("NOTCH_TAB", "").strip()
         or session_title()
         or (f"{where}: {gist()}".strip(": ") if where else gist())
         or where
         or "session")

# quote_via=quote, not the default quote_plus: form encoding turns a space into "+", and
# URLComponents on the other end decodes %20 but leaves "+" alone -- so the notch showed
# "I'm+refactoring+the+parser".
subprocess.run(["open", "-g", "boringnotch://claude?" + urllib.parse.urlencode(
    {"event": state, "project": label}, quote_via=urllib.parse.quote)], capture_output=True)
