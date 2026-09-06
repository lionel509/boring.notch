# Claude Code -> notch

`notch-claude.py` announces terminal-tab state changes in the notch. Copy it to
`~/.claude/hooks/` and register it in `~/.claude/settings.json`:

```json
"hooks": {
  "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/notch-claude.py started" }] }],
  "Stop":         [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/notch-claude.py done"    }] }],
  "Notification": [
    { "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "~/.claude/hooks/notch-claude.py waiting" }] },
    { "matcher": "idle_prompt",       "hooks": [{ "type": "command", "command": "~/.claude/hooks/notch-claude.py stalled" }] }
  ]
}
```

Use the absolute path -- `~` is not expanded. Do **not** set `"async": true`: the hook is
silently never invoked with it, which is how it looked broken while every other part worked.

The tab label is, in order: `$NOTCH_TAB`, else the `aiTitle` Claude Code writes into the
transcript (its own name for the session -- the one in the terminal tab), else the gist of the
last message, else the directory. The directory is last on purpose: nearly every session is
launched from `~/Documents`, so as a label it names all the tabs at once.
