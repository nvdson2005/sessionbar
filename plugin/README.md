# sessionbar (Claude Code plugin)

Hooks that record each Claude Code session's state (working, waiting for input, idle) as one small JSON file per session in `~/.local/state/sessionbar/`. The sessionbar CLI and SwiftBar plugin read these files to show all active sessions in the macOS menu bar. The hooks print nothing, always exit 0 and never block Claude Code. They need `jq`.

See the [repository README](../README.md) for installation and the menu bar setup.
