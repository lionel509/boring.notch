#!/usr/bin/env python3
"""Tell the notch that a Claude Code tab changed state.

Runs on SessionStart, UserPromptSubmit, Stop, SessionEnd and the two Notification kinds, in
every session. The state is passed as argv[1] rather than sniffed out of the payload, because
settings.json already has to register each event separately to give it a matcher -- so the
event name is known at the point of registration and there is nothing to infer.

SessionEnd is not optional decoration. The notch keeps a list of live sessions, and without an
event saying a tab is gone the only way out of that list is an eight-hour timeout -- so a
morning's finished work would still be sitting there mid-afternoon.

Sends `session_id` alongside the label, and this is the part that matters most. The label below
is not an identity: it falls back to a gist of the last message, which changes on every single
Stop, so a notch keyed on it would show one tab over and over under a different name each time.
`session_id` is in every hook payload and is stable for the life of the tab.

Always exits 0. A Stop hook that exits 2 actively prevents Claude from stopping, which is the
exact opposite of the intent here.
"""
import json, os, subprocess, sys, urllib.parse

state = sys.argv[1] if len(sys.argv) > 1 else "done"

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}

# Only announce real interactive tabs. CLAUDE_CODE_ENTRYPOINT is "cli" for a terminal
# session and "sdk-cli" for a headless `claude -p`, including every one a session spawns
# internally -- without this, a feature about three terminals becomes a feature about every
# internal call any of them makes.
#
# It is emphatically NOT the same as CLAUDE_CODE_CHILD_SESSION, which was tried first and
# was wrong: that is set on every *child process* Claude Code spawns, and a hook is one of
# those, so it reads as 1 even in the main session and silenced everything. The test that
# missed it asked whether a nested session was suppressed -- which it was, along with all
# the others. Suppression is not selectivity.
if os.environ.get("CLAUDE_CODE_ENTRYPOINT", "cli") != "cli":
    sys.exit(0)

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

params = {"event": state, "project": label}

# The stable key. Every hook payload carries it; the app treats it as opaque, filters it to
# alphanumerics plus - and _, and never displays it.
session_id = payload.get("session_id")
if isinstance(session_id, str) and session_id.strip():
    params["session_id"] = session_id.strip()

# The full path, not the basename the label uses. It is the one field that tells two tabs with
# the same title apart, and the notch shows it on hover where its length costs nothing.
cwd = payload.get("cwd") or os.getcwd()
if isinstance(cwd, str) and cwd:
    params["cwd"] = cwd

# quote_via=quote, not the default quote_plus: form encoding turns a space into "+", and
# URLComponents on the other end decodes %20 but leaves "+" alone -- so the notch showed
# "I'm+refactoring+the+parser".
subprocess.run(["open", "-g", "boringnotch://claude?" + urllib.parse.urlencode(
    params, quote_via=urllib.parse.quote)], capture_output=True)
