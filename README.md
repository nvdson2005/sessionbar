# sessionbar

macOS menu bar status for every active Claude Code session: which ones are **working**, which **need your input** (permission prompts), and which are **idle**.

```
 ● ● ●                       ← one dot per session: orange = needs you, green = working, grey = idle
 ──────────────────────────────────────────────────────────────
 NEEDS YOU (1)
 ⚠ api-server   main        Claude needs your permission…   12s
 WORKING (1)
 ✦ web-app      feat/ui     Edit                            3m
 IDLE (1)
 ☾ notes        —           Done                            8m
 ──────────────────────────────────────────────────────────────
 3 sessions · oldest 2h
 ✓ Notify when a session needs you
 ✓ Notification sound
 Clean up stale sessions
 Refresh
```

- **Click a session** to jump to its exact terminal tab (iTerm2 and Terminal; VS Code and Cursor open the project window; other apps are brought to the front).
- **Hold ⌥** to switch the rows to *Open in Finder*.
- **Hover a session** for a tooltip with its full path, status, branch and terminal.
- **Notifications:** when a session starts waiting for you, a notification appears. Click it to jump to that session. A dot that has been waiting for more than 2 minutes blinks.
- The title shows up to 6 dots, then `+N`.

## How it works

```
Claude Code session ──hooks──▶ ~/.local/state/sessionbar/<session_id>.json ◀──reads── SwiftBar (every 3s)
```

- **Claude Code plugin** (`plugin/`): hooks on `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop` and `SessionEnd` write one small JSON state file per session. It doesn't touch your `settings.json`, and your existing hooks keep working.
- **CLI** (`bin/sessionbar`): reads the state files, drops sessions whose `claude` process has died, and renders output for SwiftBar or the terminal.
- **SwiftBar plugin** (`swiftbar/sessionbar.3s.sh`): a thin wrapper that runs `sessionbar swiftbar`.

## Install

```sh
brew install --cask swiftbar          # open it once and choose a plugin folder
brew install nvdson2005/tap/sessionbar
sessionbar setup                      # installs the Claude Code plugin + SwiftBar plugin
```

Restart any running Claude Code sessions so they load the hooks.

To install only the Claude Code plugin by hand, run this inside Claude Code:

```
/plugin install sessionbar --marketplace nvdson2005/sessionbar
```

Install without brew, from a checkout:

```sh
SESSIONBAR_MARKETPLACE="$PWD" ./bin/sessionbar setup
```

## Commands

| Command | Does |
|---|---|
| `sessionbar setup [dir]` | Install the Claude Code plugin and copy the SwiftBar plugin into SwiftBar's folder (or `dir`) |
| `sessionbar status [--json]` | List active sessions in the terminal |
| `sessionbar focus <id>` | Bring a session's terminal tab to the front |
| `sessionbar open <id>` | Open a session's folder in Finder |
| `sessionbar config [notify\|sound on\|off]` | Show or change settings (stored in `~/.config/sessionbar/config`) |
| `sessionbar notify-test` | Send a test notification |
| `sessionbar clean` | Remove state for sessions whose process is gone |
| `sessionbar doctor` | Check the installation |
| `sessionbar uninstall` | Remove both plugins and all state |

Environment variables: `SESSIONBAR_DIR` (state folder), `SESSIONBAR_STALE_SECS` (max age for sessions with no known PID, default 12h), `SESSIONBAR_MARKETPLACE` (marketplace source for `setup`).

## Requirements

macOS, Claude Code CLI, `jq` (built into macOS 15+, or `brew install jq`), and [SwiftBar](https://github.com/swiftbar/SwiftBar).

## Development

```sh
tests/run.sh                          # hook + CLI smoke tests, uses a temp state folder
claude plugin validate .              # marketplace manifest
claude plugin validate plugin         # plugin manifest + hooks
```

### Release

1. Bump the version in `bin/sessionbar`, `plugin/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and `swiftbar/sessionbar.3s.sh`.
2. Tag and push: `git tag v0.1.0 && git push --tags`.
3. Get the checksum: `curl -sL https://github.com/nvdson2005/sessionbar/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256`.
4. Update `url` and `sha256` in `Formula/sessionbar.rb` in the `homebrew-tap` repo, then push.

## License

MIT
