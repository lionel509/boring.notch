# Claude Code -> notch

`notch-claude.py` announces terminal-tab state changes in the notch: a four-second sneak peek
each time something happens, and a persistent list of live sessions on the Claude tab's
**Sessions** panel.

Copy it to `~/.claude/hooks/` and register it in `~/.claude/settings.json`:

```json
"hooks": {
  "SessionStart":     [{ "hooks": [{ "type": "command", "command": "/Users/you/.claude/hooks/notch-claude.py started" }] }],
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/Users/you/.claude/hooks/notch-claude.py working" }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "/Users/you/.claude/hooks/notch-claude.py done"    }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "/Users/you/.claude/hooks/notch-claude.py ended"   }] }],
  "Notification": [
    { "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "/Users/you/.claude/hooks/notch-claude.py waiting" }] },
    { "matcher": "idle_prompt",       "hooks": [{ "type": "command", "command": "/Users/you/.claude/hooks/notch-claude.py stalled" }] }
  ]
}
```

Use the absolute path -- `~` is not expanded. Do **not** set `"async": true`: the hook is
silently never invoked with it, which is how it looked broken while every other part worked.

## The two entries that are new

**`SessionEnd` is required, not optional.** It is the only event that removes a session from
the panel's list. Without it the list has one exit -- an eight-hour timeout -- so a morning's
finished tabs would still be sitting there mid-afternoon. The app cannot verify a session on
its own: it never sees the process, and a terminal killed with cmd-W fires nothing at all, so
the timeout stays as the backstop for the exits `SessionEnd` does not cover.

**`UserPromptSubmit` is optional.** It is what distinguishes a tab actually working from one
that merely started, and it fires no sneak peek -- submitting a prompt is not news. Skip it and
sessions simply sit at *Started* until they finish.

## What gets sent

`boringnotch://claude?event=<verb>&project=<label>&session_id=<id>&cwd=<path>`

| Verb | Fires on | Panel state | Sneak peek |
|---|---|---|---|
| `started` | SessionStart | Started | yes |
| `working` | UserPromptSubmit | Working | no |
| `waiting` | Notification / permission_prompt | Needs you | yes |
| `stalled` | Notification / idle_prompt | Idle | yes |
| `done` | Stop | Done | yes |
| `ended` | SessionEnd | removed from the list | no |

`session_id` is the identity. The label is not, and cannot be: it falls back to a gist of the
last message, which changes on every Stop, so a list keyed on it would show one tab over and
over under a new name each time it finished a turn. `session_id` is present in every hook
payload and is stable for the life of the tab.

Everything on that URL is untrusted on arrival -- any process running as this user can send
one. The app filters the id down to alphanumerics plus `-` and `_`, strips control characters
from the label and the path, caps all three, and never resolves the path or hands it to a
shell.

The tab label is, in order: `$NOTCH_TAB`, else the `aiTitle` Claude Code writes into the
transcript (its own name for the session -- the one in the terminal tab), else the gist of the
last message, else the directory. The directory is last on purpose: nearly every session is
launched from `~/Documents`, so as a label it names all the tabs at once. `cwd` is sent
separately as the full path and shown on hover, where its length costs nothing.

The session list is not persisted across restarts of the notch. A session id from a previous
launch names a tab that is certainly gone, so restoring it would mean showing sessions that
cannot possibly still be running.
