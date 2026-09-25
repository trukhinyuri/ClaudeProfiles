# Architecture

Claude Profiles is a thin layer around the official Claude Desktop app. It never changes how Claude talks to Anthropic; it only decides which data directory each Claude window uses and keeps a few local files consistent between them.

```text
                ┌──────────────────────── Claude Profiles.app ────────────────────────┐
                │  SwiftUI window · menu bar · claude-profiles CLI                    │
                │                 └───────── ClaudeProfilesKit ─────────┘             │
                └───────┬──────────────────────┬───────────────────────┬──────────────┘
          creates/opens │                reads │                 syncs │
                        ▼                      ▼                       ▼
   Claude <LABEL>.app launcher      config.json (account ID)    claude-code-sessions/
     └─ open -n engine clone        plan-usage-history.json       <account>/<org>/local_*.json
        --user-data-dir=<profile>   IndexedDB (account email)     deleted_*  archived-sessions.idx
```

## Profiles

A profile is three things, all derived from a registry entry in `~/Library/Application Support/Claude Profiles/profiles.json`:

1. **Engine.** An APFS clone of `/Applications/Claude.app` created with `clonefile(2)`, so it shares disk blocks with the original. The only change is a Finder custom icon, which adds an `Icon\r` file and a Finder flag to the bundle. No code or resource is modified and Anthropic’s signature still verifies with `codesign --verify` (the `--strict` check flags the extra icon file). Because the Dock shows a running app’s icon from its bundle path, each profile window gets its own labeled icon.
2. **Data directory.** Claude Desktop is an Electron app, and Electron keeps everything (cookies, sign-in, window state, caches) in the directory passed with `--user-data-dir`. Each profile gets its own, so each can be signed in to a different account at the same time.
3. **Launcher.** A tiny app bundle whose executable is a shell script calling `claude-profiles open <id>`, with a fallback to `open -n -a <engine> --args --user-data-dir=<dir>`. Launchers can be kept in the Dock and are indexed by Spotlight; engines can’t, because opening an engine directly would start it without its data directory.

Engines are rebuilt when `CFBundleVersion` of the installed Claude differs from the clone’s and the profile isn’t running (`ProfileManager.refresh()` and on open).

## Signing in

Claude Desktop opens Google sign-in in the default browser, which returns the result through a `claude://` link. Launch Services delivers that link to the registered copy of Claude, and every profile runs a copy with the same bundle identifier, so without help the main app receives it and discards it as a sign-in it didn’t start.

`SignInRouting` fixes the destination rather than the link. Opening a profile that has no signed-in account unregisters the main app and the other app copies (`lsregister -u`) and registers that profile’s copy, and records this in `sign-in.json`. Each status refresh checks whether the profile is now signed in, has been waiting for more than 15 minutes, or never started; then the copies are unregistered and the main app is registered again. Claude Profiles never sees the link or anything in it. Email sign-in happens inside the window and needs none of this.

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

`CoworkSync` shares Cowork sessions the same way, from a differently-shaped folder:

```text
<data dir>/local-agent-mode-sessions/<account-uuid>/<org-uuid>/
    local_<session>.json      one card per session, holding absolute paths (works from any account/org folder)
    local_<session>/          working folder — never copied
    cowork-*-cache.json, remote-session-spaces.json, scheduled-tasks.json, rpm/, <8 hex chars>/
                               per-organization files — never copied; a shared scheduled-tasks.json would run
                               every task in every open window at once
```

Only `local_*.json` cards move between folders. Cowork keeps no tombstone for a deleted session, so a card that disappears from a folder can't be told apart from one that folder never had without help: `CoworkSync` keeps a small state file, `cowork-sync.json` in the Claude Profiles state directory, recording which cards each folder held after the last run. A card missing from a folder that held it last time is read as deleted there. While any Claude window is open, it is simply not copied back into that folder, and the folder keeps being read that way on every later run; once all windows are closed, it is removed from every folder that still has it (backed up first) — unless some other copy was modified since the last run, in which case that's read as someone still using the session, and it's kept and shared instead of removed. A folder the state file doesn't know about yet (a new profile) is only ever filled, never treated as a source of deletions.

The app syncs at launch and every minute while running (it stays in the menu bar when the window is closed); `claude-profiles sync` does the same on demand. Removing a profile syncs once more after its window quits, so Claude Code sessions started in it moments ago aren’t lost. Its Cowork sessions can't outlive it, because their working folders are inside its data directory: after the profile goes to the Trash, `CoworkSync.removeCards(workingIn:)` removes their cards from every other folder, backing each one up.

## Sharing the setup

Claude Desktop keeps some setup next to the sign-in, in each data directory. Each time a profile window is started, `SettingsSync` and `InterfaceSync` bring it in line with the main app, which is the source. They run only while the profile's window is closed, because Claude writes these files back when it quits. A replaced file goes to `Backups/<date>/` first.

`SettingsSync`:

- `Claude Extensions`, `Claude Extensions Settings`, `extensions-installations.json`, `ssh_configs.json` and `claude-ssh-remote` are copied as they are (APFS clones).
- `claude-code/<version>` builds the main app has finished downloading (they have a `.verified` file) are cloned under a temporary name and then renamed, so a profile never sees half a build and its first session needn't download one.
- `claude_desktop_config.json` and `mcp-user-tool-toggles.json` are merged key by key with the main app's values first, so settings only the profile has are kept. `mcpServers` mirrors the main app exactly. The scheduler switches (`ccdScheduledTasksEnabled`, `coworkScheduledTasksEnabled`, `wakeSchedulerEnabled`) are always off in profiles, so a scheduled task runs once, in the main app. Tool toggles are stored per account; the main account's choices are given to the profile's account.
- In `config.json`, only `userThemeMode`, `windowControlsZoomFactor` and `locale` are set. The file also holds the profile's sign-in, so it is edited in place with its permissions kept, and never copied or backed up.

`InterfaceSync` handles what Claude keeps in the `https://claude.ai` origin of its Local Storage:

- A fixed list of keys: sidebar pins and hidden projects, starred sessions and groups, unread markers, session filters and sections, per-session model choice and results, editor preferences, and dismissed tips. Drafts, caches, analytics, the default model (it depends on the plan) and anything that identifies the account are not on the list.
- Keys Claude files per account (`…status-filter.<account>`, `…folder-permission-mode.<account>`, a few notices) are copied under the profile's account. A per-account key the main app doesn't have is removed from the profile, so both show Claude's default.
- The sidebar store `dframe-store` is merged field by field. Fields about the account itself (`lastSidebarScopeKey`, `…ByScope` counts, `…ByOrg` flags) stay the profile's; the main app's custom groups move from its `account/organization` scope to the profile's.
- The main app wins, except for a value changed only in the profile since the last run. `Interface/<profile>.json` in the state directory records the values both sides last agreed on, which is what tells the two cases apart.

`LocalStorage` reads Chromium's LevelDB database directly: `CURRENT`, the manifest, `.ldb` tables (with Snappy) and `.log` files, newest sequence number wins. It writes by adding one new, higher-numbered `.log` file holding one batch; LevelDB replays it the next time Claude opens the database, and existing files are never changed. It refuses to write while another process holds the database's `LOCK`.

Claude reads sessions and per-account settings only at launch, and a new profile doesn't know its account until it is signed in. So when the app sees a profile's window go from signed out to signed in, it shares sessions, creates that account's session folders, quits the window normally and opens it again. A window that doesn't quit within 20 seconds is left alone.

## Reading Claude Desktop data

`DesktopData` reads, and never writes:

| Fact | Source | Notes |
|---|---|---|
| Signed-in account | `config.json` → `lastKnownAccountUuid` | The file also holds OAuth token caches; `DesktopData` reads only this key, and `SettingsSync` only the three appearance keys. |
| Usage | `plan-usage-history.json` → latest sample `u.fh` (5-hour %) and `u.sd` (weekly %) | Recorded by Claude Desktop itself; the 5-hour value is shown as “reset” once five hours have passed. |
| Email | IndexedDB cache of the claude.ai profile (scanned; only the email is kept, cached per account) | The address must follow `email_address` within 140 bytes and the account UUID must appear within the 80 bytes before it, so addresses of teammates in the same cache are ignored. |

## Testing

All logic lives in `ClaudeProfilesKit` and takes a `Paths` value, so tests run against a temporary home directory and never touch real data. `Backup` accepts a `discard` closure so pruning can be tested without filling the real Trash.
