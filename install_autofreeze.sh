#!/usr/bin/env bash
# ==============================================================================
# Script: install_autofreeze.sh
# Purpose: Installs a macOS LaunchAgent to automatically freeze blacklisted
#          daemons 10 seconds after user login.
#          Prevents daemons like fileproviderd, contactsd, and corespotlightd
#          from consuming CPU and memory after every system reboot.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FREEZE_SCRIPT="$SCRIPT_DIR/freeze_daemons.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/com.free-mmm.autofreeze.plist"
USER_ID="$(id -u)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ ! -f "$FREEZE_SCRIPT" ]]; then
  echo -e "${RED}[ERROR] freeze_daemons.sh not found at: $FREEZE_SCRIPT${NC}"
  exit 1
fi

chmod +x "$FREEZE_SCRIPT"
mkdir -p "$HOME/Library/LaunchAgents"

# Unload existing agent if currently loaded
launchctl bootout "gui/$USER_ID/com.free-mmm.autofreeze" 2>/dev/null || true

echo -e "${CYAN}>>> Creating LaunchAgent: $PLIST_PATH${NC}"
cat << EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.free-mmm.autofreeze</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>sleep 10 &amp;&amp; "$FREEZE_SCRIPT" -f</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/free-mmm-autofreeze.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/free-mmm-autofreeze.err</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST_PATH"

echo -e "${CYAN}>>> Registering LaunchAgent with launchd...${NC}"
if launchctl bootstrap "gui/$USER_ID" "$PLIST_PATH" 2>/dev/null; then
  echo -e "${GREEN}${BOLD}[SUCCESS] Auto-freeze LaunchAgent installed and loaded successfully!${NC}"
elif launchctl load "$PLIST_PATH" 2>/dev/null; then
  echo -e "${GREEN}${BOLD}[SUCCESS] Auto-freeze LaunchAgent loaded via fallback!${NC}"
else
  echo -e "${YELLOW}[NOTE] LaunchAgent written. It will automatically activate on next login.${NC}"
fi

echo -e ">>> Every time you log in, background daemons will be paused automatically."
echo -e ">>> Logs will be written to: /tmp/free-mmm-autofreeze.log"
echo -e ">>> To uninstall anytime, run: ${BOLD}./uninstall_autofreeze.sh${NC}\n"
