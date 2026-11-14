---
name: notch-notes
description: Read, search, create, append, update, and delete Markdown notes in NotchNotes (刘海笔记), manage the NotchNotes temporary file shelf, or open/close/toggle the notch drawer via the `notch-notes` CLI. Trigger whenever the user mentions NotchNotes, 刘海笔记, notch notes, reading/writing scratch notes in the Mac notch, or staging files in the notch file shelf.
---

# NotchNotes CLI (`notch-notes`)

Operate **NotchNotes** safely from the terminal. When NotchNotes is running, commands sync live with the in-memory UI over a private Unix Domain Socket; when NotchNotes is closed, commands safely update `notes.json` (under `flock` exclusive lock) and `UserDefaults`.

## 1. Locate the Executable

Always resolve the CLI binary in this order:

```bash
if command -v notch-notes >/dev/null 2>&1; then
  NOTCH_NOTES_BIN="$(command -v notch-notes)"
elif [ -x "$HOME/.local/bin/notch-notes" ]; then
  NOTCH_NOTES_BIN="$HOME/.local/bin/notch-notes"
else
  NOTCH_NOTES_BIN="/Applications/NotchNotes.app/Contents/MacOS/notch-notes"
fi
```

Verify availability before running mutations:

```bash
"$NOTCH_NOTES_BIN" --help
```

## 2. Safety Rules (Prevent Accidental Data Loss)

1. **Inspect before mutating**: Always run `list --json` or `get [<target>] --json` before calling `append`, `update`, or `delete` so you target the right tab.
2. **Prefer `append` or `add` over `update`**: Only use `update` when intentionally replacing the entire note body, and confirm you read the full existing text first.
3. **Never delete blindly**: `delete` requires an explicit `<target>` (prefer exact UUID from `list --json`) and refuses to delete the last remaining tab.

## 3. Quick Reference (`--json` Recommended for Agents)

### Read & Search Notes

```bash
# List all note tabs (1-based index, id, title, characterCount, isActive, createdAt)
"$NOTCH_NOTES_BIN" list --json

# Read the active note or a specific note (by UUID, UUID prefix, 1-based index, or title)
"$NOTCH_NOTES_BIN" get --json
"$NOTCH_NOTES_BIN" get 1 --json
"$NOTCH_NOTES_BIN" get "Project" --json

# Line-by-line case-insensitive search across all tabs
"$NOTCH_NOTES_BIN" search "TODO" --json
```

### Create, Append, Update & Delete Notes

```bash
# Create a new note tab (add --select to focus it in the UI)
"$NOTCH_NOTES_BIN" add --text $'# Daily Standup\n- [ ] Ship CLI' --json
cat summary.md | "$NOTCH_NOTES_BIN" add --stdin --select --json

# Append to a note (inserts a leading newline automatically unless --no-newline is set)
"$NOTCH_NOTES_BIN" append 1 --text "- [ ] Follow up with design" --json
printf '%s\n' "-Done" | "$NOTCH_NOTES_BIN" append --active --stdin --json

# Replace full content of a specific note (read via `get` first!)
"$NOTCH_NOTES_BIN" update "<uuid>" --text $'# Updated Title\nNew body' --json

# Delete a specific note tab (cannot delete when only 1 tab remains)
"$NOTCH_NOTES_BIN" delete "<uuid>" --json
```

### File Shelf & Notch Drawer

```bash
# Inspect, stage, or clean up files in the NotchNotes file shelf
"$NOTCH_NOTES_BIN" shelf list --json
"$NOTCH_NOTES_BIN" shelf add ./report.pdf ./diagram.png --json
"$NOTCH_NOTES_BIN" shelf remove "<item-id-or-path>" --json
"$NOTCH_NOTES_BIN" shelf clear --json

# Control the notch drawer (launches NotchNotes automatically on open/toggle if closed)
"$NOTCH_NOTES_BIN" panel open --json
"$NOTCH_NOTES_BIN" panel close --json
"$NOTCH_NOTES_BIN" panel toggle --json
```
