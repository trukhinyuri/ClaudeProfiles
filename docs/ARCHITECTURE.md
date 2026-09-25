# Architecture

ClaudeUnlimited is a thin layer around the official Claude Desktop app. It never changes how Claude talks to Anthropic; it only decides which data directory each Claude window uses and keeps a few local files consistent between them.

```text
                ┌──────────────────────── ClaudeUnlimited.app ────────────────────────┐
                │  SwiftUI window · menu bar · claude-unlimited CLI                    │
                │                 └───────── ClaudeUnlimitedKit ─────────┘             │
                └───────┬──────────────────────┬───────────────────────┬──────────────┘
          creates/opens │                reads │                 syncs │
                        ▼                      ▼                       ▼
   Claude <LABEL>.app launcher      config.json (account ID)    claude-code-sessions/
     └─ open -n engine clone        plan-usage-history.json       <account>/<org>/local_*.json
        --user-data-dir=<profile>   IndexedDB (account email)     deleted_*  archived-sessions.idx
```

## Profiles

A profile is three things, all derived from a registry entry in `~/Library/Application Support/ClaudeUnlimited/profiles.json`:

1. **Engine.** An APFS clone of `/Applications/Claude.app` created with `clonefile(2)`, so it shares disk blocks with the original. The only change is a Finder custom icon, which adds an `Icon\r` file and a Finder flag to the bundle. No code or resource is modified and Anthropic’s signature still verifies with `codesign --verify` (the `--strict` check flags the extra icon file). Because the Dock shows a running app’s icon from its bundle path, each profile window gets its own labeled icon.
2. **Data directory.** Claude Desktop is an Electron app, and Electron keeps everything (cookies, sign-in, window state, caches) in the directory passed with `--user-data-dir`. Each profile gets its own, so each can be signed in to a different account at the same time.
3. **Launcher.** A tiny app bundle whose executable is a shell script calling `claude-unlimited open <id>`, with a fallback to `open -n -a <engine> --args --user-data-dir=<dir>`. Launchers can be kept in the Dock and are indexed by Spotlight; engines can’t, because opening an engine directly would start it without its data directory.

Engines are rebuilt when `CFBundleVersion` of the installed Claude differs from the clone’s and the profile isn’t running (`ProfileManager.refresh()` and on open).

## Session sharing

Claude Code conversations are stored in `~/.claude/projects` and are the same for every window. What differs is the sidebar: Claude Desktop lists sessions from small index cards kept per account and organization:

```text
<data dir>/claude-code-sessions/<account-uuid>/<org-uuid>/
    local_<session>.json      one card per session
    deleted_<session>         tombstone for a deleted session
    archived-sessions.idx     {"v": 1, "archived": [...]}
```

`SessionSync` gathers these from every account/organization folder of every data directory and makes them consistent:

- **Cards.** The newest copy of each card (by modification time) is written to every folder. The copy keeps the source’s modification time, so it never looks newer than the original.
- **Deletions.** A session with a tombstone anywhere is never copied again. Tombstones are copied and deleted cards removed only when no Claude window is running, so nothing is ever removed from under a running Claude.
- **Archive.** Archived session lists are merged by union. Removals are not propagated: a running Claude can write back a stale list, which would be indistinguishable from un-archiving many sessions at once.
- **Safety.** Files are written atomically, and a card is re-checked right before it is replaced so a copy Claude has just updated is never overwritten with an older one. Every removed card is copied to `Backups/<date>/` first, and so is the first version of the day of every overwritten file. Backup days older than a week are moved to the Trash.
- **Concurrency.** The app, the CLI and launchers share `flock(2)` locks: a sync that finds another one running is skipped, and engine rebuilds wait for each other. A damaged `profiles.json` is reported and never overwritten; the previous version is kept as `profiles.json.bak`.

Symlinking the folders instead of copying doesn’t work: Claude Desktop creates them with `mkdir` and fails on a symlink.

The app syncs at launch and every minute while running (it stays in the menu bar when the window is closed); `claude-unlimited sync` does the same on demand. Removing a profile syncs once more after its window quits, so sessions started in it moments ago aren’t lost.

## Reading Claude Desktop data

`DesktopData` reads, and never writes:

| Fact | Source | Notes |
|---|---|---|
| Signed-in account | `config.json` → `lastKnownAccountUuid` | The file also holds OAuth token caches; only this key is read. |
| Usage | `plan-usage-history.json` → latest sample `u.fh` (5-hour %) and `u.sd` (weekly %) | Recorded by Claude Desktop itself; the 5-hour value is shown as “reset” once five hours have passed. |
| Email | IndexedDB cache of the claude.ai profile (scanned; only the email is kept, cached per account) | The address must follow `email_address` within 140 bytes and the account UUID must appear within the 80 bytes before it, so addresses of teammates in the same cache are ignored. |

## Testing

All logic lives in `ClaudeUnlimitedKit` and takes a `Paths` value, so tests run against a temporary home directory and never touch real data. `Backup` accepts a `discard` closure so pruning can be tested without filling the real Trash.
