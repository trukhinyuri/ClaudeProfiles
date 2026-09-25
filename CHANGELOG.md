# Changelog

## Unreleased

- Cowork sessions shared across all profiles, the same way Claude Code sessions already are
- Profile windows look like the main one: sidebar layout, pinned, starred and unread sessions, groups, filters, theme, zoom and language come from the main app
- Scheduled tasks stay off in profile windows, so each task runs once, in the main app (0.1.0 copied the main app’s scheduler settings into profiles)
- Tool toggles chosen in the main app now apply to each profile’s own account
- A profile window restarts once after its first sign-in, so shared sessions show up right away
- New profiles reuse the Claude Code build the main app has already downloaded
- Removing a profile also removes its Cowork sessions from other windows, since their files go to the Trash with it

## 0.1.0 — 2026-09-25

First public release.

- One Claude Desktop window per subscription, each with a labeled Dock icon and launcher
- Claude Code sessions, deletions and archive shared across all profiles, with backups
- Signed-in email and five-hour/weekly usage for every subscription
- Add, open and remove subscriptions from the app, the menu bar or the `claude-profiles` CLI
- App copies rebuilt automatically after Claude Desktop updates
- Profile windows get the main app's extensions, MCP servers, tool toggles, SSH hosts and preferences when they start
- Google and email sign-in both work in profile windows: while one signs in, `claude://` sign-in links go to it instead of the main app
