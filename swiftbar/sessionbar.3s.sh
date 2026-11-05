#!/bin/bash
# <xbar.title>Claude Sessions</xbar.title>
# <xbar.version>v0.2.0</xbar.version>
# <xbar.author>nvdson2005</xbar.author>
# <xbar.desc>Status of all active Claude Code sessions</xbar.desc>
# <xbar.dependencies>jq,sessionbar</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# Thin wrapper installed into the SwiftBar plugin folder by `sessionbar setup`.
# All logic lives in the sessionbar CLI, so `brew upgrade` updates it in place.

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:$PATH"

if ! command -v sessionbar >/dev/null 2>&1; then
  echo "⚠︎ | color=#FF453A"
  echo "---"
  echo "sessionbar not found in PATH"
  echo "Install: brew install nvdson2005/tap/sessionbar"
  exit 0
fi

exec sessionbar swiftbar
