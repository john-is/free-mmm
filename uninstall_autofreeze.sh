#!/usr/bin/env bash
# ==============================================================================
# Script: uninstall_autofreeze.sh
# Purpose: Uninstalls the macOS LaunchAgent that auto-freezes daemons on login.
# ==============================================================================

set -euo pipefail

PLIST_PATH="$HOME/Library/LaunchAgents/com.free-mmm.autofreeze.plist"
USER_ID="$(id -u)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}>>> Unloading Auto-freeze LaunchAgent...${NC}"
launchctl bootout "gui/$USER_ID/com.free-mmm.autofreeze" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true

if [[ -f "$PLIST_PATH" ]]; then
  rm -f "$PLIST_PATH"
  echo -e "${GREEN}${BOLD}[SUCCESS] Auto-freeze LaunchAgent removed: $PLIST_PATH${NC}"
else
  echo -e "${YELLOW}[INFO] LaunchAgent plist not found. Nothing to remove.${NC}"
fi

echo -e ">>> Background daemons will no longer be frozen automatically on login."
