# Contributing

Thanks for helping. A few ground rules keep the project useful and safe for everyone:

- **Stay within Anthropic’s terms.** Changes that handle credentials or tokens, proxy requests, pool limits or switch accounts automatically won’t be merged. See [Staying within Anthropic’s terms](README.md#staying-within-anthropics-terms).
- **Never lose user data.** Anything that overwrites or removes a file must back it up first or move it to the Trash.
- **Test what you change.** `make test` runs the suite; logic belongs in `ClaudeProfilesKit`, where it can be tested against a sandboxed home directory.

## Layout

| Path | What |
|---|---|
| `Sources/ClaudeProfilesKit` | Profiles, session sharing, reading Claude Desktop data, icons |
| `Sources/ClaudeProfiles` | SwiftUI app and menu bar |
| `Sources/claude-profiles` | Command-line tool |
| `Tests/ClaudeProfilesKitTests` | Swift Testing suite |
| `scripts/build-app.sh` | Assembles and signs `Claude Profiles.app` |

To take screenshots without real accounts, launch the app with sample data:

```sh
open -n --env CLAUDE_PROFILES_DEMO=1 "build/Claude Profiles.app"
```
