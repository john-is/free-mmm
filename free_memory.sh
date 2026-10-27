#!/usr/bin/env bash
# ==============================================================================
# Script: free_memory.sh
# Purpose: Free RAM on macOS by terminating non-whitelisted and
#          blacklisted processes (indexing daemons, screensavers, media analyzers),
#          while safeguarding kernel, compositor, and active terminal/session.
#          Includes built-in controls to disable/enable recurring background daemons.
#          All allowed and targeted process names are loaded from configuration files.
#
# ------------------------------------------------------------------------------
# OPEN SOURCE PREAMBLE & LIABILITY DISCLAIMER (MIT License Terms)
# ------------------------------------------------------------------------------
# Copyright (c) 2026 Open Source Community
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# CAUTION: By running or using this software, the user takes full and sole
# responsibility for any data loss, terminated tasks, or system state
# modifications resulting from its execution.
# ==============================================================================

set -uo pipefail

ORIGINAL_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Color Constants
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Defaults & Settings
# ------------------------------------------------------------------------------
DRY_RUN=false
FORCE=false
USER_ONLY=true
PURGE_CACHE=false
MAX_FREE=false
GRACE_TIMEOUT=2
WHITELIST_FILE=""
BLACKLIST_FILE=""

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Safe-to-Kill Applications, Widgets & Daemons Helper (for --max-free mode)
# ------------------------------------------------------------------------------
is_safe_to_kill_process() {
  local name="$1"
  local comm="$2"

  # Invariant shield: never target critical system infrastructure or developer tools
  case "$name" in
    kernel_task|launchd|diskarbitrationd|opendirectoryd|securityd|trustd|notifyd) return 1 ;;
    powerd|kernelmanagerd|amfid|syspolicyd|endpointsecurityd|aslmanager|deviceinterfaced) return 1 ;;
    fseventsd|logd|syslogd|autofsd|thermalmonitord|watchdogd) return 1 ;;
    WindowServer|loginwindow|runningboardd|WindowManager|SkyLight) return 1 ;;
    coreaudiod|bluetoothd|wifid|configd|mDNSResponder|mDNSResponderHelper|usbd|driverkit|AudioComponentRegistrar) return 1 ;;
    pboard|cfprefsd|distnoted|lsd|tccd|secd|UserEventAgent|fontd|fontworker) return 1 ;;
    Finder|Dock|SystemUIServer|ControlCenter|NotificationCenter) return 1 ;;
    Terminal|iTerm2|iTerm|alacritty|kitty|wezterm-gui|wezterm|warp) return 1 ;;
    bash|zsh|sh|fish|login|sshd|ssh|tmux|screen) return 1 ;;
    node|java|python*|ruby|git|ollama|chrome-devtools-mcp|"Antigravity IDE"|Code|Cursor) return 1 ;;
    ps|tee|sed|grep|awk|kill|killall|cat|sleep|sudo|tail|head|sort|tr|cut|wc) return 1 ;;
  esac

  # 1. Background widget extensions (*.appex)
  if [[ "$comm" == *".appex/"* ]]; then
    return 0
  fi

  # 2. Built-in macOS GUI Apps & Viewers
  case "$name" in
    "Activity Monitor"|Calculator|Calendar|Clock|Contacts|AddressBookManager) return 0 ;;
    FaceTime|Freeform|"Font Book"|Grapher|Keynote|Numbers|Pages|Mail|Maps|Messages) return 0 ;;
    Music|News|Notes|Photos|"Photo Booth"|Podcasts|Preview|"QuickTime Player") return 0 ;;
    Reminders|Shortcuts|Stocks|"System Settings"|TV|TextEdit|VoiceMemos|Weather|"App Store"|Books|Chess) return 0 ;;
  esac

  # 3. Auxiliary UI Agents & Screen/Wallpaper Services
  case "$name" in
    WallpaperAgent|AirPlayUIAgent|AirPlayXPCHelper|ContinuityCaptureAgent|AMPDeviceDiscoveryAgent) return 0 ;;
    SoftwareUpdateNotificationManager|"Keychain Circle Notification"|AppSSOAgent) return 0 ;;
    sociallayerd|imagent|identityservicesd|AddressBookSourceSync|UIKitSystem) return 0 ;;
    systemsettingsagent|appstoreagent|TextInputMenuAgent|TextInputSwitcher) return 0 ;;
    CursorUIViewService|"com.apple.dock.extra"|colorsync.useragent|ViewBridgeAuxiliary) return 0 ;;
    LoginUserService|ScreenTimeAgent|UsageTrackingAgent|callservicesd|"com.apple.FaceTime.FTConversationService") return 0 ;;
    mediaremoteagent|usernotificationsd|usernoted|gamecontrolleragentd|gamecontrollerd) return 0 ;;
  esac

  # 4. Siri, Dictation & Text-to-Speech Daemons
  case "$name" in
    siriknowledged|siriinferenced|siriactionsd|assistantd|heard|sirittsd) return 0 ;;
    SiriAUSP|MacinTalkAUSP|WardaSynthesizer_arm64|WardaSynthesizer_x86_64) return 0 ;;
    KonaSynthesizer|MauiAUSP|voicebankingd|corespeechd|corespeechd_system) return 0 ;;
    SiriSuggestionsBookkeepingService|SAExtensionOrchestrator|"com.apple.SiriTTSService.TrialProxy") return 0 ;;
  esac

  # 5. Machine Learning, Intelligence & AI Background Compute
  case "$name" in
    mlhostd|IntelligencePlatformComputeService|ModelCatalogAgent|spotlightknowledged) return 0 ;;
    generativeexperiencesd|mediaanalysisd|photoanalysisd|photolibraryd) return 0 ;;
    suggestd|duetexpertd|knowledge-agent|triald|aneuserd|modelmanagerd) return 0 ;;
  esac

  # 6. Cloud Sync, Accounts, Storage, Cache & Content Services
  case "$name" in
    cloudd|cloudphotod|bird|appleaccountd|accountsd|syncdefaultsd|remindd) return 0 ;;
    contactsd|PasswordBreachAgent|SafariBookmarksSyncAgent|dataaccessd|businessservicesd) return 0 ;;
    MessagesBlastDoorService|storekitagent|weatherd|fudHelperAgent|familycircled|StatusKitAgent) return 0 ;;
    akd|dmd|chronod|replicatord|localizationswitcherd|ManagedSettingsAgent|sharedfilelistd) return 0 ;;
    cdpd|TrustedPeersHelper|homed|"com.apple.geod"|bluetoothuserd|IMDPersistenceAgent) return 0 ;;
    ScopedBookmarkAgent|iCloudNotificationAgent|ProtectedCloudKeySyncing|StocksKitService) return 0 ;;
    seserviced|progressd|AssetCacheLocatorService|AssetCache|iconservicesagent|iconservicesd) return 0 ;;
    "com.apple.quicklook.Thumb"|QuickLookUIService|calaccessd|fileproviderd|deleted) return 0 ;;
    intelligentroutingd|audioaccessoryd|mobiletimerd|replayd|useractivityd|networkserviceproxy) return 0 ;;
    swcd|linkd|MENotificationAgent|lockdownmoded|icloudmailagent|itunescloudd) return 0 ;;
    WiFiCloudAssetsXPCService|backgroundassets.user|MTLAssetUpgraderD) return 0 ;;
    nearbyd|netbiosd|NFStorageServer|nfcd|seld|symptomsd|softwareupdated) return 0 ;;
    accessoryupdaterd|ThunderboltAccessoryUpdaterService|installcoordinationd|UARPUpdaterService*) return 0 ;;
  esac

  # 7. Telemetry, Analytics, Diagnostics & Profiling
  case "$name" in
    spindump|spindump_agent|mobileassetd|tipsd|dprivacyd|metrickitd|feedbackd) return 0 ;;
    betaenrollmentagent|swtransparencyd|adprivacyd|promotedcontentd|analyticsagent|analyticsd) return 0 ;;
    diagnostics_agent|diagnosticextensionsd|ReportCrash|PerfPowerServices|homeenergyd) return 0 ;;
    transparencyd|routined|findmydevice-user-agent|findmylocateagent) return 0 ;;
    searchpartyuseragent|sharingd|rapportd) return 0 ;;
  esac

  # 8. Indexing and Search
  case "$name" in
    corespotlightd|Spotlight) return 0 ;;
  esac

  return 1
}

is_safe_to_kill_app() {
  is_safe_to_kill_process "$@"
}
CURRENT_USER=$(whoami)
CURRENT_UID=$(id -u)
CONSOLE_UID=$(stat -f '%u' /dev/console 2>/dev/null || echo "")
TARGET_UID="${SUDO_UID:-${CONSOLE_UID:-$CURRENT_UID}}"
TARGET_USER="${SUDO_USER:-$(id -nu "$TARGET_UID" 2>/dev/null || echo "$CURRENT_USER")}"
ACTION="cleanup"
LOG_FILE="${FREE_MMM_LOG_FILE:-$SCRIPT_DIR/free_memory.log}"
ENABLE_LOGGING=true
if [[ "${FREE_MMM_NO_LOG:-0}" == "1" || "${FREE_MMM_NO_LOG:-}" == "true" ]]; then
  ENABLE_LOGGING=false
fi
START_EXECUTION_EPOCH=0

# ------------------------------------------------------------------------------
# Logging & Interactive Prompt Helpers
# ------------------------------------------------------------------------------
prompt_confirmation() {
  local prompt_text="$1"
  local answer=""

  if [[ -e /dev/fd/4 ]]; then
    printf "%b" "$prompt_text" >&4
  else
    printf "%b" "$prompt_text" >&2
  fi

  if [[ "$ENABLE_LOGGING" == true && -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    local clean_prompt
    clean_prompt=$(printf "%b" "$prompt_text" | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g')
    printf "%s" "$clean_prompt" >> "$LOG_FILE"
  fi

  if [[ -t 0 ]]; then
    read -r answer
  elif [[ -c /dev/tty ]] && read -r answer < /dev/tty 2>/dev/null; then
    :
  else
    read -r answer || true
  fi

  if [[ "$ENABLE_LOGGING" == true && -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    echo "$answer" >> "$LOG_FILE"
  fi

  echo "$answer"
}

finalize_execution_logging() {
  local exit_code=$?
  trap - EXIT

  if [[ "$ENABLE_LOGGING" == true && -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    if [[ -e /dev/fd/3 ]]; then
      exec 1>&3 2>&4 3>&- 4>&-
    fi
    sleep 0.05

    local end_epoch
    end_epoch=$(date +%s 2>/dev/null | tr -dc '0-9')
    end_epoch="${end_epoch:-0}"
    local start_ep
    start_ep=$(echo "${START_EXECUTION_EPOCH:-$end_epoch}" | tr -dc '0-9')
    start_ep="${start_ep:-$end_epoch}"
    local duration=$(( end_epoch >= start_ep ? end_epoch - start_ep : 0 ))
    local end_date
    end_date=$(date '+%Y-%m-%d %H:%M:%S')

    cat << EOF >> "$LOG_FILE"
--------------------------------------------------------------------------------
[${end_date}] EXECUTION END: Exit Code: ${exit_code} | Duration: ${duration}s
================================================================================

EOF
  fi

  exit "$exit_code"
}

init_execution_logging() {
  if [[ "$ENABLE_LOGGING" != true ]]; then
    return 0
  fi

  if [[ ! -f "$LOG_FILE" ]]; then
    if ! touch "$LOG_FILE" 2>/dev/null; then
      LOG_FILE="/tmp/free_memory.log"
      if ! touch "$LOG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}[WARNING] Could not write to log file. Execution logging disabled.${NC}" >&2
        ENABLE_LOGGING=false
        return 0
      fi
    fi
  fi

  if [[ -n "${SUDO_UID:-}" && -f "$LOG_FILE" ]]; then
    chown "${SUDO_UID}:${SUDO_GID:-$(id -g "$SUDO_UID" 2>/dev/null || echo 20)}" "$LOG_FILE" 2>/dev/null || true
  fi
  chmod 666 "$LOG_FILE" 2>/dev/null || chmod 664 "$LOG_FILE" 2>/dev/null || true

  START_EXECUTION_EPOCH=$(date +%s)
  local start_date
  start_date=$(date '+%Y-%m-%d %H:%M:%S')

  cat << EOF >> "$LOG_FILE"
================================================================================
[${start_date}] EXECUTION START: free_memory.sh
Command:  $0 ${ORIGINAL_ARGS[*]:-}
User:     ${CURRENT_USER} (UID: ${CURRENT_UID}, Console UID: ${CONSOLE_UID:-N/A})
PID:      $$ | PPID: $PPID
Action:   ${ACTION}
================================================================================
EOF

  exec 3>&1 4>&2
  exec > >(tee >(sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE") >&3) 2>&1
  trap finalize_execution_logging EXIT
}

# ------------------------------------------------------------------------------
# Helper Functions: Formatting & Pattern Matching
# ------------------------------------------------------------------------------
format_bytes() {
  local kb=${1:-0}
  awk -v k="$kb" 'BEGIN {
    if (k >= 1048576) {
      printf "%.2f GB", k / 1048576
    } else if (k >= 1024) {
      printf "%.1f MB", k / 1024
    } else {
      printf "%d KB", k
    }
  }'
}

get_free_mem_percent() {
  local free_pct
  free_pct=$(memory_pressure 2>/dev/null | grep -i "System-wide memory free percentage" | awk '{print $NF}' || echo "")
  if [[ -n "$free_pct" ]]; then
    echo "$free_pct"
  else
    echo "N/A"
  fi
}

matches_pattern() {
  local target_base="$1"
  local target_comm="$2"
  local pattern="$3"

  # 1. Exact match against executable basename
  if [[ "$target_base" == "$pattern" ]]; then
    return 0
  fi

  # 2. Glob / path matching (if pattern contains wildcards * or ? or path delimiter /)
  if [[ "$pattern" == *"*"* || "$pattern" == *"?"* || "$pattern" == *"/"* ]]; then
    if [[ "$target_comm" == $pattern || "$target_base" == $pattern || "$target_comm" == "$pattern"/* ]]; then
      return 0
    fi
  fi

  # 3. App bundle component matching (handles AppName and AppName.app)
  local stripped_pattern="${pattern%.app}"
  if [[ "$target_comm" == *"/$stripped_pattern.app/"* || "$target_comm" == *"/$stripped_pattern/"* || "$target_comm" == *"/$pattern/"* ]]; then
    return 0
  fi

  return 1
}

# ------------------------------------------------------------------------------
# Service Target Resolution & Plist Mappings (Bash 3.2 Compatible)
# ------------------------------------------------------------------------------
get_service_entries() {
  local pattern="$1"
  case "$pattern" in
    \**|*\**|*\?*)
      # Wildcards are used for process matching; not literal launchd labels
      ;;
    mds)
      echo "system:com.apple.metadata.mds:/System/Library/LaunchDaemons/com.apple.metadata.mds.plist"
      echo "system:com.apple.metadata.mds.scan:/System/Library/LaunchDaemons/com.apple.metadata.mds.scan.plist"
      ;;
    mds_stores)
      echo "system:com.apple.metadata.mds.index:/System/Library/LaunchDaemons/com.apple.metadata.mds.index.plist"
      ;;
    mdworker|mdworker_shared)
      echo "system:com.apple.metadata.mds.spindump:/System/Library/LaunchDaemons/com.apple.metadata.mds.spindump.plist"
      echo "gui:com.apple.mdworker.shared:/System/Library/LaunchAgents/com.apple.mdworker.shared.plist"
      echo "gui:com.apple.mdworker.mail:/System/Library/LaunchAgents/com.apple.mdworker.mail.plist"
      echo "gui:com.apple.mdworker.single.arm64:/System/Library/LaunchAgents/com.apple.mdworker.single.arm64.plist"
      echo "gui:com.apple.mdworker.single.x86_64:/System/Library/LaunchAgents/com.apple.mdworker.single.x86_64.plist"
      echo "gui:com.apple.mdworker.sizing:/System/Library/LaunchAgents/com.apple.mdworker.sizing.plist"
      ;;
    Spotlight)
      echo "gui:com.apple.Spotlight:/System/Library/LaunchAgents/com.apple.Spotlight.plist"
      ;;
    corespotlightd)
      echo "gui:com.apple.corespotlightd:/System/Library/LaunchAgents/com.apple.corespotlightd.plist"
      echo "gui:com.apple.managedcorespotlightd:/System/Library/LaunchAgents/com.apple.managedcorespotlightd.plist"
      echo "gui:com.apple.corespotlightservice:/System/Library/LaunchAgents/com.apple.corespotlightservice.plist"
      ;;
    spotlightknowledged)
      echo "gui:com.apple.spotlightknowledged:/System/Library/LaunchAgents/com.apple.spotlightknowledged.plist"
      echo "gui:com.apple.spotlightknowledged.importer:/System/Library/LaunchAgents/com.apple.spotlightknowledged.importer.plist"
      echo "gui:com.apple.spotlightknowledged.updater:/System/Library/LaunchAgents/com.apple.spotlightknowledged.updater.plist"
      ;;
    SpotlightNetHelper)
      echo "gui:com.apple.SpotlightNetHelper:/System/Library/LaunchAgents/com.apple.SpotlightNetHelper.plist"
      ;;
    mdflagwriter)
      echo "gui:com.apple.metadata.mdflagwriter:/System/Library/LaunchAgents/com.apple.metadata.mdflagwriter.plist"
      ;;
    wallpaper)
      echo "gui:com.apple.wallpaper.agent:/System/Library/LaunchAgents/com.apple.wallpaper.plist"
      ;;
    wallpaperexportd)
      echo "system:com.apple.wallpaper.export:/System/Library/LaunchDaemons/com.apple.wallpaper.export.plist"
      ;;
    WallpaperVideoExtension|WallpaperDynamicExtension)
      echo "gui:com.apple.WallpaperVideoExtension:"
      echo "gui:com.apple.WallpaperDynamicExtension:"
      ;;
    idleassetsd)
      echo "system:com.apple.idleassetsd:/System/Library/LaunchDaemons/com.apple.idleassetsd.plist"
      ;;
    triald_system)
      echo "system:com.apple.triald.system:/System/Library/LaunchDaemons/com.apple.triald.system.plist"
      ;;
    autofsd)
      echo "system:com.apple.autofsd:/System/Library/LaunchDaemons/com.apple.autofsd.plist"
      ;;
    mediaanalysisd)
      echo "gui:com.apple.mediaanalysisd:/System/Library/LaunchAgents/com.apple.mediaanalysisd.plist"
      ;;
    photoanalysisd)
      echo "gui:com.apple.photoanalysisd:/System/Library/LaunchAgents/com.apple.photoanalysisd.plist"
      ;;
    photolibraryd)
      echo "gui:com.apple.photolibraryd:/System/Library/LaunchAgents/com.apple.photolibraryd.plist"
      ;;
    cloudphotod)
      echo "gui:com.apple.cloudphotod:/System/Library/LaunchAgents/com.apple.cloudphotod.plist"
      ;;
    suggestd|CoreSuggestionsAgent)
      echo "gui:com.apple.suggestd:/System/Library/LaunchAgents/com.apple.suggestd.plist"
      ;;
    knowledge-agent)
      echo "gui:com.apple.knowledge-agent:/System/Library/LaunchAgents/com.apple.knowledge-agent.plist"
      ;;
    knowledgeconstructiond)
      echo "gui:com.apple.knowledgeconstructiond:/System/Library/LaunchAgents/com.apple.knowledgeconstructiond.plist"
      ;;
    siriknowledged)
      echo "gui:com.apple.siriknowledged:/System/Library/LaunchAgents/com.apple.siriknowledged.plist"
      ;;
    triald)
      echo "gui:com.apple.triald:/System/Library/LaunchAgents/com.apple.triald.plist"
      ;;
    parsecd)
      echo "gui:com.apple.parsecd:/System/Library/LaunchAgents/com.apple.parsecd.plist"
      ;;
    intelligenceplatformd)
      echo "gui:com.apple.intelligenceplatformd:/System/Library/LaunchAgents/com.apple.intelligenceplatformd.plist"
      ;;
    intelligencecontextd)
      echo "gui:com.apple.intelligencecontextd:/System/Library/LaunchAgents/com.apple.intelligencecontextd.plist"
      ;;
    intelligenceflowd)
      echo "gui:com.apple.intelligenceflowd:/System/Library/LaunchAgents/com.apple.intelligenceflowd.plist"
      ;;
    generativeexperiencesd)
      echo "gui:com.apple.generativeexperiencesd:/System/Library/LaunchAgents/com.apple.generativeexperiencesd.plist"
      ;;
    modelmanagerd)
      echo "system:com.apple.modelmanagerd:/System/Library/LaunchDaemons/com.apple.modelmanagerd.plist"
      ;;
    ModelCatalogAgent)
      echo "gui:com.apple.ModelCatalogAgent:/System/Library/LaunchAgents/com.apple.ModelCatalogAgent.plist"
      ;;
    modelcatalogd)
      echo "system:com.apple.modelcatalogd:/System/Library/LaunchDaemons/com.apple.modelcatalogd.plist"
      ;;
    ContextStoreAgent)
      echo "gui:com.apple.ContextStoreAgent:/System/Library/LaunchAgents/com.apple.ContextStoreAgent.plist"
      ;;
    coreduetd)
      echo "system:com.apple.coreduetd:/System/Library/LaunchDaemons/com.apple.coreduetd.plist"
      ;;
    duetexpertd)
      echo "gui:com.apple.duetexpertd:/System/Library/LaunchAgents/com.apple.duetexpertd.plist"
      ;;
    biomed)
      echo "system:com.apple.biomed:/System/Library/LaunchDaemons/com.apple.biomed.plist"
      ;;
    BiomeAgent)
      echo "gui:com.apple.BiomeAgent:/System/Library/LaunchAgents/com.apple.BiomeAgent.plist"
      ;;
    biomesyncd)
      echo "gui:com.apple.biomesyncd:/System/Library/LaunchAgents/com.apple.biomesyncd.plist"
      ;;
    naturallanguaged)
      echo "gui:com.apple.naturallanguaged:/System/Library/LaunchAgents/com.apple.naturallanguaged.plist"
      ;;
    SafariBookmarksSyncAgent)
      echo "gui:com.apple.SafariBookmarksSyncAgent:/System/Library/LaunchAgents/com.apple.SafariBookmarksSyncAgent.plist"
      ;;
    ScreenSaver|ScreenSaverEngine|legacyScreenSaver)
      echo "gui:com.apple.ScreenSaverEngine:"
      echo "gui:com.apple.ScreenSaver:"
      ;;
    cloudd)
      echo "gui:com.apple.cloudd:/System/Library/LaunchAgents/com.apple.cloudd.plist"
      echo "system:com.apple.cloudd:/System/Library/LaunchDaemons/com.apple.cloudd.plist"
      ;;
    bird)
      echo "gui:com.apple.bird:/System/Library/LaunchAgents/com.apple.bird.plist"
      ;;
    fileproviderd|FileProvider)
      echo "gui:com.apple.FileProvider:/System/Library/LaunchAgents/com.apple.FileProvider.plist"
      ;;
    ProtectedCloudKeySyncing|protectedcloudkeysyncing)
      echo "gui:com.apple.protectedcloudstorage.protectedcloudkeysyncing:/System/Library/LaunchAgents/com.apple.protectedcloudstorage.protectedcloudkeysyncing.plist"
      ;;
    cloudkeychainproxy3)
      echo "gui:com.apple.security.cloudkeychainproxy3:/System/Library/LaunchAgents/com.apple.security.cloudkeychainproxy3.plist"
      ;;
    CloudSettingsSyncAgent)
      echo "gui:com.apple.CloudSettingsSyncAgent:/System/Library/LaunchAgents/com.apple.CloudSettingsSyncAgent.plist"
      ;;
    swtransparencyd)
      echo "gui:com.apple.swtransparencyd:/System/Library/LaunchAgents/com.apple.swtransparencyd.plist"
      ;;
    transparencyd)
      echo "gui:com.apple.transparencyd:/System/Library/LaunchAgents/com.apple.transparencyd.plist"
      ;;
    contactsd|AddressBookManager)
      echo "gui:com.apple.contactsd:/System/Library/LaunchAgents/com.apple.contactsd.plist"
      echo "gui:com.apple.contacts.donation-agent:/System/Library/LaunchAgents/com.apple.contacts.donation-agent.plist"
      echo "gui:com.apple.AddressBook.SourceSync:/System/Library/LaunchAgents/com.apple.AddressBook.SourceSync.plist"
      echo "gui:com.apple.AddressBook.abd:/System/Library/LaunchAgents/com.apple.AddressBook.abd.plist"
      echo "gui:com.apple.AddressBook.AssistantService:/System/Library/LaunchAgents/com.apple.AddressBook.AssistantService.plist"
      ;;
    calaccessd)
      echo "gui:com.apple.calaccessd:/System/Library/LaunchAgents/com.apple.calaccessd.plist"
      ;;
    CallHistoryPluginHelper)
      echo "gui:com.apple.CallHistoryPluginHelper:/System/Library/LaunchAgents/com.apple.CallHistoryPluginHelper.plist"
      ;;
    CallHistorySyncHelper)
      echo "gui:com.apple.CallHistorySyncHelper:/System/Library/LaunchAgents/com.apple.CallHistorySyncHelper.plist"
      ;;
    maild)
      echo "gui:com.apple.email.maild:/System/Library/LaunchAgents/com.apple.email.maild.plist"
      ;;
    icloudmailagent)
      echo "gui:com.apple.icloudmailagent:/System/Library/LaunchAgents/com.apple.icloudmailagent.plist"
      ;;
    chronod)
      echo "gui:com.apple.chronod:/System/Library/LaunchAgents/com.apple.chronod.plist"
      ;;
    analyticsagent)
      echo "gui:com.apple.analyticsagent:/System/Library/LaunchAgents/com.apple.analyticsagent.plist"
      echo "gui:com.apple.geoanalyticsd:/System/Library/LaunchAgents/com.apple.geoanalyticsd.plist"
      echo "gui:com.apple.inputanalyticsd:/System/Library/LaunchAgents/com.apple.inputanalyticsd.plist"
      echo "system:com.apple.analyticsd:/System/Library/LaunchDaemons/com.apple.analyticsd.plist"
      echo "system:com.apple.ecosystemanalyticsd:/System/Library/LaunchDaemons/com.apple.ecosystemanalyticsd.plist"
      ;;
    analyticsd)
      echo "system:com.apple.analyticsd:/System/Library/LaunchDaemons/com.apple.analyticsd.plist"
      ;;
    ecosystemanalyticsd)
      echo "system:com.apple.ecosystemanalyticsd:/System/Library/LaunchDaemons/com.apple.ecosystemanalyticsd.plist"
      ;;
    audioanalyticsd)
      echo "system:com.apple.audioanalyticsd:/System/Library/LaunchDaemons/com.apple.audioanalyticsd.plist"
      ;;
    wifianalyticsd)
      echo "system:com.apple.wifianalyticsd:/System/Library/LaunchDaemons/com.apple.wifianalyticsd.plist"
      ;;
    inputanalyticsd)
      echo "gui:com.apple.inputanalyticsd:/System/Library/LaunchAgents/com.apple.inputanalyticsd.plist"
      ;;
    geoanalyticsd)
      echo "gui:com.apple.geoanalyticsd:/System/Library/LaunchAgents/com.apple.geoanalyticsd.plist"
      ;;
    usbctelemetryd)
      echo "system:com.apple.usbctelemetryd:/System/Library/LaunchDaemons/com.apple.usbctelemetryd.plist"
      ;;
    CloudTelemetryService)
      echo "gui:com.apple.CloudTelemetryService:"
      echo "system:com.apple.CloudTelemetryService:"
      ;;
    UsageTrackingAgent)
      echo "gui:com.apple.UsageTrackingAgent:/System/Library/LaunchAgents/com.apple.UsageTrackingAgent.plist"
      ;;
    rtcreportingd)
      echo "gui:com.apple.rtcreportingd:/System/Library/LaunchAgents/com.apple.rtcreportingd.plist"
      echo "system:com.apple.rtcreportingd:/System/Library/LaunchDaemons/com.apple.rtcreportingd.plist"
      ;;
    sysmond)
      echo "system:com.apple.sysmond:/System/Library/LaunchDaemons/com.apple.sysmond.plist"
      ;;
    diagnosticextensionsd)
      echo "gui:com.apple.diagnosticextensionsd:/System/Library/LaunchAgents/com.apple.diagnosticextensionsd.plist"
      ;;
    siriinferenced)
      echo "gui:com.apple.siriinferenced:/System/Library/LaunchAgents/com.apple.siriinferenced.plist"
      ;;
    sirittsd)
      echo "gui:com.apple.sirittsd:/System/Library/LaunchAgents/com.apple.sirittsd.plist"
      ;;
    siriactionsd)
      echo "gui:com.apple.siriactionsd:/System/Library/LaunchAgents/com.apple.siriactionsd.plist"
      ;;
    corespeechd)
      echo "gui:com.apple.corespeechd:/System/Library/LaunchAgents/com.apple.corespeechd.plist"
      echo "system:com.apple.corespeechd.system:/System/Library/LaunchDaemons/com.apple.corespeechd.system.plist"
      ;;
    assistantd|assistant_service)
      echo "gui:com.apple.assistantd:/System/Library/LaunchAgents/com.apple.assistantd.plist"
      echo "gui:com.apple.assistant_service:/System/Library/LaunchAgents/com.apple.assistant_service.plist"
      ;;
    assistant_cdmd)
      echo "gui:com.apple.assistant_cdmd:/System/Library/LaunchAgents/com.apple.assistant_cdmd.plist"
      ;;
    localspeechrecognition)
      echo "gui:com.apple.speech.synthesisserver:/System/Library/LaunchAgents/com.apple.speech.synthesisserver.plist"
      echo "gui:com.apple.speech.speechsynthesisd.arm64:/System/Library/LaunchAgents/com.apple.speech.speechsynthesisd.arm64.plist"
      echo "gui:com.apple.speech.speechsynthesisd.x86_64:/System/Library/LaunchAgents/com.apple.speech.speechsynthesisd.x86_64.plist"
      echo "gui:com.apple.speech.speechdatainstallerd:/System/Library/LaunchAgents/com.apple.speech.speechdatainstallerd.plist"
      ;;
    sharingd)
      echo "gui:com.apple.sharingd:/System/Library/LaunchAgents/com.apple.sharingd.plist"
      ;;
    homed)
      echo "gui:com.apple.homed:/System/Library/LaunchAgents/com.apple.homed.plist"
      ;;
    heard)
      echo "gui:com.apple.accessibility.heard:/System/Library/LaunchAgents/com.apple.accessibility.heard.plist"
      ;;
    routined)
      echo "gui:com.apple.routined:/System/Library/LaunchAgents/com.apple.routined.plist"
      ;;
    callservicesd)
      echo "gui:com.apple.telephonyutilities.callservicesd:/System/Library/LaunchAgents/com.apple.telephonyutilities.callservicesd.plist"
      ;;
    familycircled)
      echo "gui:com.apple.familycircled:/System/Library/LaunchAgents/com.apple.familycircled.plist"
      ;;
    financed)
      echo "gui:com.apple.financed:/System/Library/LaunchAgents/com.apple.financed.plist"
      ;;
    remindd)
      echo "gui:com.apple.remindd:/System/Library/LaunchAgents/com.apple.remindd.plist"
      ;;
    itunescloudd)
      echo "gui:com.apple.itunescloudd:/System/Library/LaunchAgents/com.apple.itunescloudd.plist"
      ;;
    replayd)
      echo "gui:com.apple.replayd:/System/Library/LaunchAgents/com.apple.replayd.plist"
      ;;
    AMPDeviceDiscoveryAgent)
      echo "gui:com.apple.AMPDeviceDiscoveryAgent:/System/Library/LaunchAgents/com.apple.AMPDeviceDiscoveryAgent.plist"
      ;;
    sociallayerd)
      echo "gui:com.apple.sociallayerd:/System/Library/LaunchAgents/com.apple.sociallayerd.plist"
      ;;
    findmylocateagent)
      echo "gui:com.apple.findmy.findmylocateagent:/System/Library/LaunchAgents/com.apple.findmy.findmylocateagent.plist"
      ;;
    searchpartyuseragent)
      echo "gui:com.apple.icloud.searchpartyuseragent:/System/Library/LaunchAgents/com.apple.icloud.searchpartyuseragent.plist"
      ;;
    findmydeviced)
      echo "system:com.apple.icloud.findmydeviced:/System/Library/LaunchDaemons/com.apple.icloud.findmydeviced.plist"
      echo "gui:com.apple.icloud.findmydeviced.findmydevice-user-agent:/System/Library/LaunchAgents/com.apple.icloud.findmydeviced.findmydevice-user-agent.plist"
      ;;
    findmybeaconingd)
      echo "system:com.apple.findmy.findmybeaconingd:/System/Library/LaunchDaemons/com.apple.findmy.findmybeaconingd.plist"
      ;;
    findmydevice-user-agent)
      echo "gui:com.apple.icloud.findmydeviced.findmydevice-user-agent:/System/Library/LaunchAgents/com.apple.icloud.findmydeviced.findmydevice-user-agent.plist"
      ;;
    rapportd|rapportd-user)
      echo "system:com.apple.rapportd:/System/Library/LaunchDaemons/com.apple.rapportd.plist"
      echo "gui:com.apple.rapportd-user:/System/Library/LaunchAgents/com.apple.rapportd-user.plist"
      ;;
    sidecar-relay|sidecar-hid-relay)
      echo "gui:com.apple.sidecar-relay:/System/Library/LaunchAgents/com.apple.sidecar-relay.plist"
      echo "gui:com.apple.sidecar-hid-relay:/System/Library/LaunchAgents/com.apple.sidecar-hid-relay.plist"
      ;;
    screensharing)
      echo "system:com.apple.screensharing:/System/Library/LaunchDaemons/com.apple.screensharing.plist"
      echo "gui:com.apple.screensharing.agent:/System/Library/LaunchAgents/com.apple.screensharing.agent.plist"
      ;;
    AirPlayUIAgent)
      echo "gui:com.apple.AirPlayUIAgent:/System/Library/LaunchAgents/com.apple.AirPlayUIAgent.plist"
      ;;
    audioaccessoryd)
      echo "gui:com.apple.audioaccessoryd:"
      ;;
    appstoreagent)
      echo "gui:com.apple.appstoreagent:/System/Library/LaunchAgents/com.apple.appstoreagent.plist"
      ;;
    askpermissiond)
      echo "gui:com.apple.askpermissiond:/System/Library/LaunchAgents/com.apple.askpermissiond.plist"
      ;;
    amsaccountsd)
      echo "gui:com.apple.amsaccountsd:/System/Library/LaunchAgents/com.apple.amsaccountsd.plist"
      ;;
    amsengagementd)
      echo "gui:com.apple.amsengagementd:/System/Library/LaunchAgents/com.apple.amsengagementd.plist"
      ;;
    ScreenTimeAgent)
      echo "gui:com.apple.ScreenTimeAgent:/System/Library/LaunchAgents/com.apple.ScreenTimeAgent.plist"
      ;;
    lockoutagent)
      echo "gui:com.apple.lockoutagent:/System/Library/LaunchAgents/com.apple.lockoutagent.plist"
      ;;
    passd)
      echo "gui:com.apple.passd:/System/Library/LaunchAgents/com.apple.passd.plist"
      ;;
    newsd)
      echo "gui:com.apple.newsd:/System/Library/LaunchAgents/com.apple.newsd.plist"
      ;;
    watchlistd)
      echo "gui:com.apple.watchlistd:/System/Library/LaunchAgents/com.apple.watchlistd.plist"
      ;;
    videosubscriptionsd)
      echo "gui:com.apple.videosubscriptionsd:/System/Library/LaunchAgents/com.apple.videosubscriptionsd.plist"
      ;;
    gamecontrollerd)
      echo "system:com.apple.GameController.gamecontrollerd:/System/Library/LaunchDaemons/com.apple.GameController.gamecontrollerd.plist"
      ;;
    gamecontrolleragentd)
      echo "gui:com.apple.GameController.gamecontrolleragentd:/System/Library/LaunchAgents/com.apple.GameController.gamecontrolleragentd.plist"
      ;;
    gamepolicyd)
      echo "system:com.apple.gamepolicyd:/System/Library/LaunchDaemons/com.apple.gamepolicyd.plist"
      ;;
    accessoryupdaterd)
      echo "system:com.apple.accessoryupdaterd:/System/Library/LaunchDaemons/com.apple.accessoryupdaterd.plist"
      ;;
    promotedcontentd)
      echo "gui:com.apple.ap.promotedcontentd:/System/Library/LaunchAgents/com.apple.ap.promotedcontentd.plist"
      ;;
    adprivacyd)
      echo "gui:com.apple.ap.adprivacyd:/System/Library/LaunchAgents/com.apple.ap.adprivacyd.plist"
      ;;
    AddressBookSourceSync)
      echo "gui:com.apple.AddressBook.SourceSync:/System/Library/LaunchAgents/com.apple.AddressBook.SourceSync.plist"
      ;;
    accountsd)
      echo "gui:com.apple.accountsd:/System/Library/LaunchAgents/com.apple.accountsd.plist"
      ;;
    appleaccountd)
      echo "gui:com.apple.appleaccountd:/System/Library/LaunchAgents/com.apple.appleaccountd.plist"
      ;;
    imagent)
      echo "gui:com.apple.imagent:/System/Library/LaunchAgents/com.apple.imagent.plist"
      ;;
    identityservicesd)
      echo "gui:com.apple.identityservicesd:/System/Library/LaunchAgents/com.apple.identityservicesd.plist"
      ;;
    weatherd)
      echo "gui:com.apple.weatherd:/System/Library/LaunchAgents/com.apple.weatherd.plist"
      ;;
    voicebankingd)
      echo "gui:com.apple.voicebankingd:/System/Library/LaunchAgents/com.apple.voicebankingd.plist"
      ;;
    linkd)
      echo "gui:com.apple.linkd:/System/Library/LaunchAgents/com.apple.linkd.plist"
      ;;
    commerce)
      echo "gui:com.apple.commerce:/System/Library/LaunchAgents/com.apple.commerce.plist"
      ;;
    storekitagent)
      echo "gui:com.apple.storekitagent:/System/Library/LaunchAgents/com.apple.storekitagent.plist"
      ;;
    dataaccessd)
      echo "gui:com.apple.dataaccess.dataaccessd:/System/Library/LaunchAgents/com.apple.dataaccess.dataaccessd.plist"
      ;;
    networkserviceproxy)
      echo "gui:com.apple.networkserviceproxy-osx:/System/Library/LaunchAgents/com.apple.networkserviceproxy-osx.plist"
      ;;
    *)
      if [[ -f "/System/Library/LaunchAgents/com.apple.$pattern.plist" ]]; then
        echo "gui:com.apple.$pattern:/System/Library/LaunchAgents/com.apple.$pattern.plist"
      elif [[ -f "/System/Library/LaunchDaemons/com.apple.$pattern.plist" ]]; then
        echo "system:com.apple.$pattern:/System/Library/LaunchDaemons/com.apple.$pattern.plist"
      elif [[ -f "/System/Library/LaunchDaemons/com.apple.metadata.$pattern.plist" ]]; then
        echo "system:com.apple.metadata.$pattern:/System/Library/LaunchDaemons/com.apple.metadata.$pattern.plist"
      elif [[ "$pattern" != *"*"* && "$pattern" != *"?"* ]]; then
        echo "gui:com.apple.$pattern:"
        echo "gui:$pattern:"
        echo "system:com.apple.$pattern:"
      fi
      ;;
  esac
}

get_all_unique_services() {
  local bname
  for bname in "${BLACKLIST_PATTERNS[@]}"; do
    get_service_entries "$bname"
  done | sort -u
}

# ------------------------------------------------------------------------------
# Service Management Subroutines
# (--disable-services / --enable-services / --freeze-services / --unfreeze-services / --status-services)
# ------------------------------------------------------------------------------
disable_bothering_services() {
  echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║                       CRITICAL WARNING & RISK NOTICE                         ║${NC}"
  echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${RED}${BOLD}║ [PERSISTENT BACKGROUND SERVICE DISABLEMENT]                                  ║${NC}"
  echo -e "${RED}║ You are about to PERSISTENTLY disable macOS background services:            ║${NC}"
  echo -e "${RED}║   • Background file search indexing & metadata coordinators (Spotlight, mds)  ║${NC}"
  echo -e "${RED}║   • Predictive suggestions, heuristics, telemetry, and contextual agents     ║${NC}"
  echo -e "${RED}║   • Automated background media, photo, and library analysis engines          ║${NC}"
  echo -e "${RED}║   • System automounting and synchronization daemons                          ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ PERSISTENCE ACROSS REBOOTS:                                                  ║${NC}"
  echo -e "${RED}║   Services will be marked disabled in the launchd configuration store.       ║${NC}"
  echo -e "${RED}║   They will NOT start automatically when your Mac restarts.                 ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ USER RESPONSIBILITY NOTICE (NO WARRANTY):                                    ║${NC}"
  echo -e "${RED}║ By using this software, you take full and sole responsibility for all        ║${NC}"
  echo -e "${RED}║ consequences, data loss, paused tasks, or system state modifications.        ║${NC}"
  echo -e "${RED}║ In no event shall authors or contributors be liable for any damages.         ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ RESTORATION: All services can be restored at any time with:                  ║${NC}"
  echo -e "${RED}║              $0 --enable-services                                            ║${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"

  if [[ "$FORCE" != true ]]; then
    echo ""
    confirm=$(prompt_confirmation "$(echo -e "${RED}${BOLD}[PROMPT] Do you want to persistently disable these background services? [y/N]: ${NC}")")
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
      echo -e "\n${YELLOW}[CANCELLED] User did not accept the prompt. No services were disabled.${NC}"
      exit 0
    fi
    echo -e "${GREEN}[ACCEPTED] Risk acknowledged by user. Proceeding...${NC}\n"
  fi

  echo -e "\n${CYAN}${BOLD}================================================================${NC}"
  echo -e "${CYAN}${BOLD}    Persistently Disabling macOS Background Daemons & Agents    ${NC}"
  echo -e "${CYAN}${BOLD}================================================================${NC}"

  local uid_val
  uid_val="${SUDO_UID:-${CONSOLE_UID:-$(id -u)}}"

  local has_root=false
  if [[ "$CURRENT_UID" -eq 0 ]]; then
    has_root=true
  elif sudo -n true 2>/dev/null; then
    has_root=true
  elif [[ "$FORCE" != true ]] && sudo -v 2>/dev/null; then
    has_root=true
  fi

  # 1. Turn off Spotlight indexing if root/sudo is available
  if [[ "$has_root" == true ]]; then
    echo -e "Turning off Spotlight disk indexing across all volumes..."
    pkill -CONT -x mds 2>/dev/null || true
    perl -e 'alarm shift; exec @ARGV' 4 sudo mdutil -a -i off 2>/dev/null || sudo mdutil -i off / 2>/dev/null || true
  else
    echo -e "${YELLOW}[NOTE] Spotlight disk indexing and system daemons require sudo.${NC}"
    echo -e "${YELLOW}       Run 'sudo $0 --disable-services' for complete root-level disablement.${NC}"
  fi

  # 2. Persistently disable in launchd database
  echo -e "\nApplying persistent 'launchctl disable' overrides in launchd..."
  while IFS=":" read -r domain label plist; do
    [[ -z "$label" ]] && continue
    if [[ "$domain" == "system" ]]; then
      if [[ "$has_root" == true ]]; then
        sudo launchctl disable "system/$label" 2>/dev/null || true
        sudo launchctl bootout "system/$label" 2>/dev/null || true
        echo -e "  [${GREEN}DISABLED - SYSTEM${NC}] $label"
      fi
    else
      launchctl disable "gui/$uid_val/$label" 2>/dev/null || true
      launchctl disable "user/$uid_val/$label" 2>/dev/null || true
      launchctl bootout "gui/$uid_val/$label" 2>/dev/null || true
      echo -e "  [${GREEN}DISABLED - USER GUI${NC}] $label"
    fi
  done < <(get_all_unique_services)

  for bname in "${BLACKLIST_PATTERNS[@]}"; do
    launchctl disable "gui/$uid_val/com.apple.$bname" 2>/dev/null || true
    launchctl disable "gui/$uid_val/$bname" 2>/dev/null || true
    launchctl disable "user/$uid_val/com.apple.$bname" 2>/dev/null || true
    launchctl disable "user/$uid_val/$bname" 2>/dev/null || true
    if [[ "$has_root" == true ]]; then
      sudo launchctl disable "system/com.apple.metadata.$bname" 2>/dev/null || true
      sudo launchctl disable "system/com.apple.$bname" 2>/dev/null || true
      sudo launchctl disable "system/$bname" 2>/dev/null || true
    fi
  done

  # 3. Stop currently active process instances (terminate cleanly, do NOT freeze)
  echo -e "\nStopping running instances of disabled background services..."
  local stopped_count=0
  while IFS=" " read -r pid p_uid stat comm; do
    [[ -z "$pid" || "$pid" == "PID" ]] && continue
    local clean_comm="${comm#-}"
    local base_name="${clean_comm##*/}"

    local matched=0
    for bname in "${BLACKLIST_PATTERNS[@]}"; do
      if matches_pattern "$base_name" "$comm" "$bname"; then
        matched=1
        break
      fi
    done
    [[ $matched -eq 0 ]] && continue

    # If paused with SIGSTOP, resume so it processes termination
    if [[ "$stat" == T* ]]; then
      kill -CONT "$pid" 2>/dev/null || true
    fi

    if kill -TERM "$pid" 2>/dev/null || ( [[ "$has_root" == true ]] && sudo kill -TERM "$pid" 2>/dev/null ); then
      stopped_count=$((stopped_count + 1))
      echo -e "  [${GREEN}STOPPED${NC}] $base_name (PID $pid)"
    fi
  done < <(ps -eo pid=,uid=,stat=,comm=)

  if [[ $stopped_count -gt 0 ]]; then
    sleep "$GRACE_TIMEOUT"
    while IFS=" " read -r pid p_uid stat comm; do
      [[ -z "$pid" || "$pid" == "PID" ]] && continue
      local clean_comm="${comm#-}"
      local base_name="${clean_comm##*/}"
      local matched=0
      for bname in "${BLACKLIST_PATTERNS[@]}"; do
        if matches_pattern "$base_name" "$comm" "$bname"; then
          matched=1
          break
        fi
      done
      [[ $matched -eq 0 ]] && continue
      kill -KILL "$pid" 2>/dev/null || ( [[ "$has_root" == true ]] && sudo kill -KILL "$pid" 2>/dev/null ) || true
    done < <(ps -eo pid=,uid=,stat=,comm=)
  fi

  echo -e "\n${GREEN}${BOLD}[SUCCESS] Background services have been persistently disabled in launchd!${NC}"
  echo -e "They are marked disabled in launchd's persistent database and will ${BOLD}NOT${NC} come up after restart."
  echo -e "To resume and re-enable services anytime, run: ${BOLD}$0 --enable-services${NC}"
  exit 0
}

enable_bothering_services() {
  echo -e "\n${CYAN}${BOLD}================================================================${NC}"
  echo -e "${CYAN}${BOLD}       Re-Enabling macOS Background Services to Defaults        ${NC}"
  echo -e "${CYAN}${BOLD}================================================================${NC}"
  local uid_val
  uid_val="${SUDO_UID:-${CONSOLE_UID:-$(id -u)}}"

  local has_root=false
  if [[ "$CURRENT_UID" -eq 0 ]]; then
    has_root=true
  elif sudo -n true 2>/dev/null; then
    has_root=true
  elif [[ "$FORCE" != true ]] && sudo -v 2>/dev/null; then
    has_root=true
  fi

  echo -e "Re-enabling background services in launchd database..."
  while IFS=":" read -r domain label plist; do
    [[ -z "$label" ]] && continue
    if [[ "$domain" == "system" ]]; then
      if [[ "$has_root" == true ]]; then
        sudo launchctl enable "system/$label" 2>/dev/null || true
        if [[ -n "$plist" && -f "$plist" ]]; then
          sudo launchctl bootstrap system "$plist" 2>/dev/null || true
        fi
        sudo launchctl kickstart -k "system/$label" 2>/dev/null || true
        echo -e "  [${GREEN}ENABLED - SYSTEM${NC}] $label"
      fi
    else
      launchctl enable "gui/$uid_val/$label" 2>/dev/null || true
      launchctl enable "user/$uid_val/$label" 2>/dev/null || true
      if [[ -n "$plist" && -f "$plist" ]]; then
        launchctl bootstrap "gui/$uid_val" "$plist" 2>/dev/null || true
      fi
      launchctl kickstart -k "gui/$uid_val/$label" 2>/dev/null || true
      echo -e "  [${GREEN}ENABLED - USER GUI${NC}] $label"
    fi
  done < <(get_all_unique_services)

  for bname in "${BLACKLIST_PATTERNS[@]}"; do
    launchctl enable "gui/$uid_val/com.apple.$bname" 2>/dev/null || true
    launchctl enable "gui/$uid_val/$bname" 2>/dev/null || true
    launchctl enable "user/$uid_val/com.apple.$bname" 2>/dev/null || true
    launchctl enable "user/$uid_val/$bname" 2>/dev/null || true
    if [[ "$has_root" == true ]]; then
      sudo launchctl enable "system/com.apple.metadata.$bname" 2>/dev/null || true
      sudo launchctl enable "system/com.apple.$bname" 2>/dev/null || true
      sudo launchctl enable "system/$bname" 2>/dev/null || true
    fi
  done

  echo -e "\nResuming any paused daemon processes (SIGCONT)..."
  while IFS=" " read -r pid p_uid stat comm; do
    [[ -z "$pid" || "$pid" == "PID" ]] && continue
    local clean_comm="${comm#-}"
    local base_name="${clean_comm##*/}"

    local matched=0
    for bname in "${BLACKLIST_PATTERNS[@]}"; do
      if matches_pattern "$base_name" "$comm" "$bname"; then
        matched=1
        break
      fi
    done
    [[ $matched -eq 0 ]] && continue

    if [[ "$stat" == T* ]]; then
      if kill -CONT "$pid" 2>/dev/null || ( [[ "$has_root" == true ]] && sudo kill -CONT "$pid" 2>/dev/null ); then
        echo -e "  [${GREEN}RESUMED${NC}] $base_name (PID $pid)"
      fi
    fi
  done < <(ps -eo pid=,uid=,stat=,comm=)

  if [[ "$has_root" == true ]]; then
    echo -e "\nRe-enabling Spotlight disk indexing..."
    perl -e 'alarm shift; exec @ARGV' 4 sudo mdutil -a -i on 2>/dev/null || sudo mdutil -i on / 2>/dev/null || true
  fi

  echo -e "\n${GREEN}${BOLD}[SUCCESS] Background services have been restored to system defaults.${NC}"
  exit 0
}

freeze_bothering_services() {
  echo -e "\n${CYAN}${BOLD}================================================================${NC}"
  echo -e "${CYAN}${BOLD}       Freezing Active Background Daemons (SIGSTOP)             ${NC}"
  echo -e "${CYAN}${BOLD}================================================================${NC}"
  echo -e "Pausing targeted background daemons in memory (state T, 0% CPU)."
  echo -e "Prevents launchd respawn loops without altering system configuration."

  if [[ "$FORCE" != true ]]; then
    echo ""
    confirm=$(prompt_confirmation "$(echo -e "${RED}${BOLD}[PROMPT] Freeze targeted background daemons in memory? [y/N]: ${NC}")")
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
      echo -e "\n${YELLOW}[CANCELLED] Operation aborted by user. No daemons were frozen.${NC}"
      exit 0
    fi
    echo -e "${GREEN}[ACCEPTED] Freezing daemons...${NC}\n"
  fi

  local uid_val
  uid_val="${SUDO_UID:-${CONSOLE_UID:-$(id -u)}}"

  local has_root=false
  if [[ "$CURRENT_UID" -eq 0 ]] || sudo -n true 2>/dev/null; then
    has_root=true
  fi

  local stopped_count=0
  local already_count=0
  while IFS=" " read -r pid p_uid stat comm; do
    [[ -z "$pid" || "$pid" == "PID" ]] && continue
    local clean_comm="${comm#-}"
    local base_name="${clean_comm##*/}"

    local matched=0
    for bname in "${BLACKLIST_PATTERNS[@]}"; do
      if matches_pattern "$base_name" "$comm" "$bname"; then
        matched=1
        break
      fi
    done
    [[ $matched -eq 0 ]] && continue

    if [[ "$stat" == T* ]]; then
      echo -e "  [${YELLOW}ALREADY PAUSED${NC}] $base_name (PID $pid)"
      already_count=$((already_count + 1))
      continue
    fi

    if kill -STOP "$pid" 2>/dev/null || ( [[ "$has_root" == true ]] && sudo kill -STOP "$pid" 2>/dev/null ); then
      echo -e "  [${GREEN}FROZEN${NC}] $base_name (PID $pid, 0% CPU)"
      stopped_count=$((stopped_count + 1))
    else
      echo -e "  ${YELLOW}[PERMISSION DENIED] PID $pid ($base_name) requires root/sudo to freeze.${NC}"
    fi
  done < <(ps -eo pid=,uid=,stat=,comm=)

  echo -e "\n${GREEN}${BOLD}[SUCCESS] $stopped_count daemon(s) frozen ($already_count already paused).${NC}"
  echo -e "They consume 0% CPU and will not trigger launchd respawn loops."
  echo -e "To resume them anytime, run: ${BOLD}$0 --unfreeze-services${NC}"
  echo -e "To permanently disable them across reboots, run: ${BOLD}$0 --disable-services${NC}"
  exit 0
}

unfreeze_bothering_services() {
  echo -e "\n${CYAN}${BOLD}================================================================${NC}"
  echo -e "${CYAN}${BOLD}       Resuming Paused Background Daemons (SIGCONT)             ${NC}"
  echo -e "${CYAN}${BOLD}================================================================${NC}"

  local has_root=false
  if [[ "$CURRENT_UID" -eq 0 ]] || sudo -n true 2>/dev/null; then
    has_root=true
  fi

  local resumed_count=0
  while IFS=" " read -r pid p_uid stat comm; do
    [[ -z "$pid" || "$pid" == "PID" ]] && continue
    local clean_comm="${comm#-}"
    local base_name="${clean_comm##*/}"

    local matched=0
    for bname in "${BLACKLIST_PATTERNS[@]}"; do
      if matches_pattern "$base_name" "$comm" "$bname"; then
        matched=1
        break
      fi
    done
    [[ $matched -eq 0 ]] && continue

    if [[ "$stat" == T* ]]; then
      if kill -CONT "$pid" 2>/dev/null || ( [[ "$has_root" == true ]] && sudo kill -CONT "$pid" 2>/dev/null ); then
        echo -e "  [${GREEN}RESUMED${NC}] $base_name (PID $pid)"
        resumed_count=$((resumed_count + 1))
      fi
    fi
  done < <(ps -eo pid=,uid=,stat=,comm=)

  echo -e "\n${GREEN}${BOLD}[SUCCESS] $resumed_count paused daemon(s) resumed.${NC}"
  exit 0
}

status_bothering_services() {
  echo -e "\n${CYAN}${BOLD}================================================================${NC}"
  echo -e "${CYAN}${BOLD}          macOS Background Services & Daemons Status            ${NC}"
  echo -e "${CYAN}${BOLD}================================================================${NC}"
  printf "${BOLD}%-26s %-16s %-18s %-10s${NC}\n" "PROCESS / SERVICE" "LAUNCHD CONFIG" "PROCESS STATE" "MEMORY"
  printf "%-26s %-16s %-18s %-10s\n" "--------------------------" "----------------" "------------------" "----------"

  local uid_val
  uid_val="${SUDO_UID:-${CONSOLE_UID:-$(id -u)}}"
  local gui_disabled
  gui_disabled="$(launchctl print-disabled "gui/$uid_val" 2>/dev/null || true) $(launchctl print-disabled "user/$uid_val" 2>/dev/null || true)"
  local sys_disabled
  sys_disabled="$(launchctl print-disabled system 2>/dev/null || true)"

  for pname in "${BLACKLIST_PATTERNS[@]}"; do
    local pinfo
    pinfo=$(ps -c -eo comm,stat,rss 2>/dev/null | awk -v p="$pname" '$1 == p {print; exit}')
    local pstat="GONE (DEAD)"
    local pmalloc="0 KB"
    if [[ -n "$pinfo" ]]; then
      local raw_stat
      raw_stat=$(echo "$pinfo" | awk '{print $(NF-1)}')
      local raw_rss
      raw_rss=$(echo "$pinfo" | awk '{print $NF}')
      pmalloc=$(format_bytes "$raw_rss")
      if [[ "$raw_stat" == T* ]]; then
        pstat="FROZEN (0% CPU)"
      else
        pstat="RUNNING"
      fi
    fi

    local is_disabled=false
    local primary_domain="gui"
    while IFS=":" read -r sdomain slabel splist; do
      [[ "$sdomain" == "system" ]] && primary_domain="system"
      local target_list="$gui_disabled"
      [[ "$sdomain" == "system" ]] && target_list="$sys_disabled"
      if [[ -n "$slabel" ]] && [[ "$target_list" == *"\"$slabel\" => disabled"* ]]; then
        is_disabled=true
        break
      fi
    done < <(get_service_entries "$pname")

    if [[ "$is_disabled" == false ]]; then
      if [[ "$primary_domain" == "system" ]]; then
        if [[ "$sys_disabled" == *"\"com.apple.metadata.$pname\" => disabled"* ]] || \
           [[ "$sys_disabled" == *"\"com.apple.$pname\" => disabled"* ]] || \
           [[ "$sys_disabled" == *"\"$pname\" => disabled"* ]]; then
          is_disabled=true
        fi
      else
        if [[ "$gui_disabled" == *"\"com.apple.$pname\" => disabled"* ]] || \
           [[ "$gui_disabled" == *"\"$pname\" => disabled"* ]]; then
          is_disabled=true
        fi
      fi
    fi

    local lstat="ENABLED"
    if [[ "$is_disabled" == true ]]; then
      lstat="DISABLED"
    fi

    local pstat_colored
    if [[ "$pstat" == "GONE"* ]]; then
      pstat_colored="${GREEN}$pstat${NC}"
    elif [[ "$pstat" == "FROZEN"* ]]; then
      pstat_colored="${YELLOW}$pstat${NC}"
    else
      pstat_colored="${RED}$pstat${NC}"
    fi

    printf "%-26s %-16s %-27b %-10s\n" "${pname:0:26}" "$lstat" "$pstat_colored" "$pmalloc"
  done
  echo -e "${CYAN}================================================================${NC}"
  exit 0
}

# ------------------------------------------------------------------------------
# Help Function
# ------------------------------------------------------------------------------
usage() {
  echo -e "${BOLD}Usage:${NC} $0 [OPTIONS] [path/to/whitelist.txt]

${BOLD}Description:${NC}
  Frees memory on macOS by identifying and closing running applications
  and background processes that are NOT explicitly allowed in the whitelist,
  or that are explicitly targeted in the blacklist (e.g. search indexers,
  screensavers, and background media analyzers).

${BOLD}Service Management Commands:${NC}
  --disable-services       Persistently disable background daemons in launchd
                           (services will NOT start up after restart).
  --enable-services        Re-enable background services back to macOS defaults.
  --freeze-services        Freeze (pause) active background daemons using SIGSTOP (0% CPU).
  --unfreeze-services      Unfreeze (resume) paused background daemons using SIGCONT.
  --status-services        Display current status of background daemons and launchd configuration.

${BOLD}Memory Cleanup Options:${NC}
  -m, --max-free           Maximum memory freeing mode. Overrides broad app whitelisting
                           to terminate safe-to-kill applications (Activity Monitor, Mail,
                           Notes, Weather, etc.), widgets (*.appex), and non-essential background
                           daemons (telemetry, indexing, cloud sync), plus auto-purges cache.
  -w, --whitelist <FILE>   Path to the process whitelist file (default: whitelist.txt).
  -b, --blacklist <FILE>   Path to the process blacklist file (default: blacklist.txt).
  -l, --log <FILE>         Path to log file (default: free_memory.log).
  --no-log                 Disable appending execution logs to file.
  -d, --dry-run            Simulate execution. Displays all processes that would
                           be stopped/frozen and memory reclaimable.
  -f, --force              Force execution without interactive confirmation.
  -a, --all-users          Target processes from all users (recommended with sudo).
                           Default targets user-only processes ($CURRENT_USER).
  -t, --timeout <SECS>     Grace timeout in seconds between SIGTERM and SIGKILL (default: 2).
  -p, --purge              Run macOS 'purge' command after termination to flush disk cache
                           (requires sudo / root privileges).
  -h, --help               Display this help message.

${BOLD}Examples:${NC}
  # 1. Preview which processes would be closed without terminating anything:
  $0 --dry-run

  # 2. Maximum memory freeing preview (including safe-to-kill apps & widgets):
  $0 --max-free --dry-run

  # 3. Maximum memory freeing execution across all users + cache purge (requires sudo):
  sudo $0 --max-free --all-users --force

  # 4. Persistently disable background daemons across reboots:
  $0 --disable-services

  # 3. Check current status of persistent background services:
  $0 --status-services

  # 4. Temporarily freeze background daemons in memory without altering launchd:
  $0 --freeze-services

  # 5. Non-interactive memory cleanup:
  $0 --force

  # 6. Restore background services when finished:
  $0 --enable-services
"
  exit 0
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disable-services)
      ACTION="disable-services"
      shift
      ;;
    --enable-services)
      ACTION="enable-services"
      shift
      ;;
    --freeze-services|--freeze)
      ACTION="freeze-services"
      shift
      ;;
    --unfreeze-services|--unfreeze|--resume-services)
      ACTION="unfreeze-services"
      shift
      ;;
    --status-services)
      ACTION="status-services"
      shift
      ;;
    -w|--whitelist)
      WHITELIST_FILE="$2"
      shift 2
      ;;
    -b|--blacklist)
      BLACKLIST_FILE="$2"
      shift 2
      ;;
    -l|--log|--log-file)
      LOG_FILE="$2"
      ENABLE_LOGGING=true
      shift 2
      ;;
    --no-log)
      ENABLE_LOGGING=false
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -m|--max-free|--max)
      MAX_FREE=true
      PURGE_CACHE=true
      shift
      ;;
    -a|--all-users)
      USER_ONLY=false
      shift
      ;;
    -t|--timeout)
      GRACE_TIMEOUT="$2"
      shift 2
      ;;
    -p|--purge)
      PURGE_CACHE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo -e "${RED}[ERROR] Unknown option: $1${NC}"
      usage
      ;;
    *)
      if [[ -z "$WHITELIST_FILE" ]]; then
        WHITELIST_FILE="$1"
      elif [[ -z "$BLACKLIST_FILE" ]]; then
        BLACKLIST_FILE="$1"
      else
        echo -e "${RED}[ERROR] Unexpected positional argument: $1${NC}"
        usage
      fi
      shift
      ;;
  esac
done

# Resolve Blacklist file (relative to script directory or working directory)
if [[ -z "$BLACKLIST_FILE" ]]; then
  if [[ -f "$SCRIPT_DIR/blacklist.txt" ]]; then
    BLACKLIST_FILE="$SCRIPT_DIR/blacklist.txt"
  elif [[ -f "blacklist.txt" ]]; then
    BLACKLIST_FILE="blacklist.txt"
  fi
fi

# Load Blacklist (if present)
declare -a BLACKLIST_PATTERNS=()
if [[ -n "$BLACKLIST_FILE" && -f "$BLACKLIST_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    clean_line="${line%%#*}"
    clean_line="${clean_line#"${clean_line%%[![:space:]]*}"}"
    clean_line="${clean_line%"${clean_line##*[![:space:]]}"}"
    if [[ -n "$clean_line" ]]; then
      BLACKLIST_PATTERNS+=("$clean_line")
    fi
  done < "$BLACKLIST_FILE"
fi

# Initialize execution logging into .log file
init_execution_logging

# Execute standalone service management action if requested
# (Does NOT require whitelist.txt)
if [[ "$ACTION" == "disable-services" ]]; then
  disable_bothering_services
elif [[ "$ACTION" == "enable-services" ]]; then
  enable_bothering_services
elif [[ "$ACTION" == "freeze-services" ]]; then
  freeze_bothering_services
elif [[ "$ACTION" == "unfreeze-services" ]]; then
  unfreeze_bothering_services
elif [[ "$ACTION" == "status-services" ]]; then
  status_bothering_services
fi

# Resolve Whitelist file (only required for live cleanup and dry-run)
if [[ -z "$WHITELIST_FILE" ]]; then
  if [[ -f "$SCRIPT_DIR/whitelist.txt" ]]; then
    WHITELIST_FILE="$SCRIPT_DIR/whitelist.txt"
  elif [[ -f "whitelist.txt" ]]; then
    WHITELIST_FILE="whitelist.txt"
  else
    echo -e "${RED}[ERROR] Whitelist file (whitelist.txt) not found!${NC}"
    echo -e "Looked in: $SCRIPT_DIR/whitelist.txt and ./whitelist.txt"
    echo -e "Usage: $0 [OPTIONS] [path/to/whitelist.txt]"
    exit 1
  fi
fi

if [[ ! -f "$WHITELIST_FILE" ]]; then
  echo -e "${RED}[ERROR] Whitelist file not found:${NC} $WHITELIST_FILE"
  exit 1
fi

declare -a WHITELIST_PATTERNS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  clean_line="${line%%#*}"
  clean_line="${clean_line#"${clean_line%%[![:space:]]*}"}"
  clean_line="${clean_line%"${clean_line##*[![:space:]]}"}"
  if [[ -n "$clean_line" ]]; then
    if [[ "$MAX_FREE" == true ]]; then
      # In --max-free mode, ignore broad directory wildcards so safe apps & daemons can be cleaned
      if [[ "$clean_line" == "/System/Applications/*" || "$clean_line" == "/System/Library/*" || \
            "$clean_line" == "/usr/libexec/*" || "$clean_line" == "/usr/sbin/*" ]]; then
        continue
      fi
    fi
    WHITELIST_PATTERNS+=("$clean_line")
  fi
done < "$WHITELIST_FILE"

# ------------------------------------------------------------------------------
# Header Banner
# ------------------------------------------------------------------------------
echo -e "${CYAN}${BOLD}================================================================${NC}"
echo -e "${CYAN}${BOLD}          macOS Memory Reclaimer & Optimizer                    ${NC}"
echo -e "${CYAN}${BOLD}================================================================${NC}"
echo -e "User:           ${GREEN}${CURRENT_USER}${NC} (UID: ${CURRENT_UID})"
echo -e "Whitelist File: ${GREEN}${WHITELIST_FILE}${NC}"
if [[ -n "$BLACKLIST_FILE" && -f "$BLACKLIST_FILE" ]]; then
  echo -e "Blacklist File: ${RED}${BLACKLIST_FILE}${NC}"
else
  echo -e "Blacklist File: ${YELLOW}[None]${NC}"
fi
echo -e "Log File:       $([[ "$ENABLE_LOGGING" == true ]] && echo -e "${CYAN}${LOG_FILE}${NC}" || echo -e "${YELLOW}[Disabled]${NC}")"
echo -e "Target Scope:   ${YELLOW}$([[ "$USER_ONLY" == true ]] && echo "Current User Only ($CURRENT_USER)" || echo "All Users / System")${NC}"
if [[ "$MAX_FREE" == true ]]; then
  echo -e "Optimization:   ${MAGENTA}${BOLD}[MAXIMUM MEMORY FREEING (--max-free)]${NC} (Safe apps, widgets & daemons targeted)"
fi
if [[ "$DRY_RUN" == true ]]; then
  echo -e "Mode:           ${MAGENTA}${BOLD}[DRY-RUN / PREVIEW ONLY - NO PROCESSES WILL BE KILLED]${NC}"
else
  echo -e "Mode:           ${RED}${BOLD}[LIVE TERMINATION]${NC}"
fi
echo -e "${CYAN}----------------------------------------------------------------${NC}"

# ------------------------------------------------------------------------------
# Build Protected Ancestor & Kernel PID Shield
# ------------------------------------------------------------------------------
# Dynamic ancestor PID immunity: protects calling shell, terminal emulator, and init
PROTECTED_PIDS=" 0 1 $$ $PPID "
cur_pid=$PPID
while [[ -n "$cur_pid" && "$cur_pid" -gt 1 ]]; do
  parent_pid=$(ps -o ppid= -p "$cur_pid" 2>/dev/null | tr -d ' ' || true)
  [[ -z "$parent_pid" ]] && break
  PROTECTED_PIDS="${PROTECTED_PIDS}${parent_pid} "
  cur_pid=$parent_pid
done

echo -e "Loaded ${GREEN}${#WHITELIST_PATTERNS[@]}${NC} whitelist rules & ${RED}${#BLACKLIST_PATTERNS[@]}${NC} blacklist rules."

INITIAL_FREE_PCT=$(get_free_mem_percent)
echo -e "Initial System Memory Free: ${GREEN}${INITIAL_FREE_PCT}${NC}"
echo -e "${CYAN}----------------------------------------------------------------${NC}"

# ------------------------------------------------------------------------------
# Scan Running Processes
# ------------------------------------------------------------------------------
echo -e "Scanning active processes against allowlist and blacklist..."

declare -a TARGET_PIDS=()
declare -a TARGET_NAMES=()
declare -a TARGET_USERS=()
declare -a TARGET_RSS=()
declare -a TARGET_REASONS=()
declare -a TARGET_IS_FROZEN=()
TOTAL_RECLAIM_KB=0
ALREADY_PAUSED_COUNT=0
ALREADY_PAUSED_KB=0

while IFS=" " read -r pid ppid p_uid rss stat comm; do
  [[ -z "$pid" || "$pid" == "PID" ]] && continue

  # 1. Check Protected Ancestor Immunity Shield (and self/children)
  if [[ " $PROTECTED_PIDS " == *" $pid "* || "$ppid" -eq $$ ]]; then
    continue
  fi

  clean_comm="${comm#-}"            # strip leading dash if login shell
  base_name="${clean_comm##*/}"     # get basename

  # Hardcoded invariant shield: never terminate critical system infrastructure or developer tools
  case "$base_name" in
    kernel_task|launchd|diskarbitrationd|opendirectoryd|securityd|trustd|notifyd) continue ;;
    powerd|kernelmanagerd|amfid|syspolicyd|endpointsecurityd|aslmanager|deviceinterfaced) continue ;;
    fseventsd|logd|syslogd|autofsd|thermalmonitord|watchdogd) continue ;;
    WindowServer|loginwindow|runningboardd|WindowManager|SkyLight) continue ;;
    coreaudiod|bluetoothd|wifid|configd|mDNSResponder|mDNSResponderHelper|usbd|driverkit|AudioComponentRegistrar) continue ;;
    pboard|cfprefsd|distnoted|lsd|tccd|secd|UserEventAgent|fontd|fontworker) continue ;;
    Finder|Dock|SystemUIServer|ControlCenter|NotificationCenter) continue ;;
    Terminal|iTerm2|iTerm|alacritty|kitty|wezterm-gui|wezterm|warp) continue ;;
    bash|zsh|sh|fish|login|sshd|ssh|tmux|screen) continue ;;
    node|java|python*|ruby|git|ollama|chrome-devtools-mcp|"Antigravity IDE"|Code|Cursor) continue ;;
    ps|tee|sed|grep|awk|kill|killall|cat|sleep|sudo|tail|head|sort|tr|cut|wc) continue ;;
  esac

  # Check if process is already frozen (state T)
  is_frozen=0
  if [[ "$stat" == T* ]]; then
    is_frozen=1
  fi

  # Resolve username safely for display
  user=$(id -nu "$p_uid" 2>/dev/null || echo "$p_uid")

  # 2. Check Blacklist Matches (Blacklist overrules general whitelist)
  is_blacklisted=0
  blacklist_match=""
  for bpattern in "${BLACKLIST_PATTERNS[@]}"; do
    if matches_pattern "$base_name" "$comm" "$bpattern"; then
      is_blacklisted=1
      blacklist_match="$bpattern"
      break
    fi
  done

  # Check if process is targeted by MAX-FREE mode (safe-to-kill applications & widgets)
  is_max_free_target=0
  max_free_reason=""
  if [[ "$MAX_FREE" == true && $is_blacklisted -eq 0 ]]; then
    if is_safe_to_kill_app "$base_name" "$comm"; then
      is_max_free_target=1
      if [[ "$comm" == *".appex/"* ]]; then
        max_free_reason="MAX-FREE (Widget: $base_name)"
      elif [[ "$comm" == *".app/"* || "$comm" == *".app" ]]; then
        max_free_reason="MAX-FREE (App: $base_name)"
      else
        max_free_reason="MAX-FREE (Daemon: $base_name)"
      fi
    fi
  fi

  # 3. Evaluate Target Status
  target_reason=""
  if [[ $is_blacklisted -eq 1 ]]; then
    # Blacklisted daemons: root can freeze all; non-root freezes user-owned
    if [[ "$USER_ONLY" == true && "$p_uid" -ne "$CURRENT_UID" && "$p_uid" -ne "$TARGET_UID" && "$CURRENT_UID" -ne 0 ]]; then
      continue
    fi
    if [[ $is_frozen -eq 1 ]]; then
      target_reason="BLACKLIST ($blacklist_match) [PAUSED]"
    else
      target_reason="BLACKLIST ($blacklist_match)"
    fi
  elif [[ $is_max_free_target -eq 1 ]]; then
    # Safe applications & widgets targeted under --max-free: target desktop user by default
    if [[ "$USER_ONLY" == true && "$p_uid" -ne "$TARGET_UID" && "$p_uid" -ne "$CURRENT_UID" && "$CURRENT_UID" -ne 0 ]]; then
      continue
    fi
    if [[ $is_frozen -eq 1 ]]; then
      target_reason="${max_free_reason} [PAUSED]"
    else
      target_reason="${max_free_reason}"
    fi
  else
    # Non-whitelisted applications: target desktop user by default
    if [[ "$USER_ONLY" == true && "$p_uid" -ne "$TARGET_UID" && "$p_uid" -ne "$CURRENT_UID" ]]; then
      continue
    fi

    # Check Whitelist
    is_whitelisted=0
    for wpattern in "${WHITELIST_PATTERNS[@]}"; do
      if matches_pattern "$base_name" "$comm" "$wpattern"; then
        is_whitelisted=1
        break
      fi
    done

    if [[ $is_whitelisted -eq 0 ]]; then
      if [[ $is_frozen -eq 1 ]]; then
        target_reason="NOT-WHITELISTED [PAUSED]"
      else
        target_reason="NOT-WHITELISTED"
      fi
    fi
  fi

  # If a reason exists, mark for termination or freeze
  if [[ -n "$target_reason" ]]; then
    if [[ $is_frozen -eq 1 && "$target_reason" == BLACKLIST* ]]; then
      ALREADY_PAUSED_COUNT=$(( ALREADY_PAUSED_COUNT + 1 ))
      ALREADY_PAUSED_KB=$(( ALREADY_PAUSED_KB + rss ))
    elif [[ $is_frozen -eq 1 && "$target_reason" == MAX-FREE* ]]; then
      ALREADY_PAUSED_COUNT=$(( ALREADY_PAUSED_COUNT + 1 ))
      ALREADY_PAUSED_KB=$(( ALREADY_PAUSED_KB + rss ))
    else
      TARGET_PIDS+=("$pid")
      TARGET_NAMES+=("$base_name")
      TARGET_USERS+=("$user")
      TARGET_RSS+=("$rss")
      TARGET_REASONS+=("$target_reason")
      TARGET_IS_FROZEN+=("$is_frozen")
      TOTAL_RECLAIM_KB=$(( TOTAL_RECLAIM_KB + rss ))
    fi
  fi
done < <(ps -eo pid=,ppid=,uid=,rss=,stat=,comm=)

NUM_TARGETS=${#TARGET_PIDS[@]}

if [[ $ALREADY_PAUSED_COUNT -gt 0 ]]; then
  PAUSED_STR=$(format_bytes "$ALREADY_PAUSED_KB")
  echo -e "${CYAN}>>> $ALREADY_PAUSED_COUNT blacklisted daemon(s) are already paused (state T, 0% CPU, ~$PAUSED_STR held/compressed).${NC}"
fi

if [[ $NUM_TARGETS -eq 0 ]]; then
  echo -e "\n${GREEN}${BOLD}[SUCCESS] All blacklisted daemons are paused and no un-whitelisted processes are running! System is clean.${NC}"
  if [[ "$PURGE_AFTER" == true ]]; then
    echo -e "\n${CYAN}>>> Purging inactive memory and disk cache buffers...${NC}"
    if sudo -n true 2>/dev/null; then
      sudo purge 2>/dev/null && echo -e "${GREEN}Cache purged successfully.${NC}" || echo -e "${YELLOW}Could not run purge command.${NC}"
    else
      purge 2>/dev/null && echo -e "${GREEN}Cache purged successfully.${NC}" || echo -e "${YELLOW}Could not run purge command.${NC}"
    fi
  fi
  exit 0
fi


RECLAIMABLE_STR=$(format_bytes "$TOTAL_RECLAIM_KB")

echo -e "\n${YELLOW}${BOLD}Found $NUM_TARGETS process(es) targeted (~$RECLAIMABLE_STR reclaimable):${NC}\n"
printf "${BOLD}%-7s %-10s %-10s %-28s %-30s${NC}\n" "PID" "USER" "MEMORY" "REASON" "COMMAND"
printf "%-7s %-10s %-10s %-28s %-30s\n" "-------" "----------" "----------" "----------------------------" "------------------------------"

for ((i = 0; i < NUM_TARGETS; i++)); do
  pid="${TARGET_PIDS[$i]}"
  user="${TARGET_USERS[$i]}"
  rss="${TARGET_RSS[$i]}"
  name="${TARGET_NAMES[$i]}"
  reason="${TARGET_REASONS[$i]}"
  mem_str=$(format_bytes "$rss")
  
  if [[ "$reason" == BLACKLIST* ]]; then
    reason_colored="${RED}${reason:0:28}${NC}"
  elif [[ "$reason" == MAX-FREE* ]]; then
    reason_colored="${MAGENTA}${reason:0:28}${NC}"
  else
    reason_colored="${YELLOW}${reason:0:28}${NC}"
  fi
  printf "%-7s %-10s %-10s %-37b %-30s\n" "$pid" "$user" "$mem_str" "$reason_colored" "${name:0:30}"
done

echo -e "\n${BOLD}Total Memory to Reclaim:${NC} ${GREEN}${BOLD}${RECLAIMABLE_STR}${NC}"

# ------------------------------------------------------------------------------
# Dry-Run Exit
# ------------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  echo -e "\n${MAGENTA}${BOLD}[DRY-RUN COMPLETE]${NC} No processes were terminated or modified."
  echo -e "Run without ${BOLD}--dry-run${NC} to execute cleanup."
  exit 0
fi

# ------------------------------------------------------------------------------
# Confirmation Prompt
# ------------------------------------------------------------------------------
if [[ "$FORCE" != true ]]; then
  echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║                       CRITICAL WARNING & RISK NOTICE                         ║${NC}"
  echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${RED}${BOLD}║ [DANGER / POTENTIAL DATA LOSS & WORK INTERRUPTION RISK]                      ║${NC}"
  echo -e "${RED}║ You are about to aggressively terminate/freeze ${BOLD}$NUM_TARGETS running process(es)${RED}:          ║${NC}"
  echo -e "${RED}║   1. UNSAVED WORK & DATA LOSS:                                               ║${NC}"
  echo -e "${RED}║      Targeted applications will close immediately WITHOUT save prompts.      ║${NC}"
  echo -e "${RED}║      Unsaved documents, notes, editor buffers, and projects will be lost.    ║${NC}"
  echo -e "${RED}║   2. ABORTED SESSIONS & TRANSFERS:                                           ║${NC}"
  echo -e "${RED}║      Web browser tabs, form inputs, active downloads, streaming sessions,     ║${NC}"
  echo -e "${RED}║      and remote transfers outside the whitelist will be abruptly closed.     ║${NC}"
  echo -e "${RED}║   3. INTERRUPTED SERVERS & BACKGROUND TASKS:                                 ║${NC}"
  echo -e "${RED}║      Compilers, local dev servers, test suites, or database workers outside   ║${NC}"
  echo -e "${RED}║      the whitelist will receive SIGTERM followed by SIGKILL.                 ║${NC}"
  echo -e "${RED}║   4. SYSTEM DAEMON PAUSE (SIGSTOP):                                          ║${NC}"
  echo -e "${RED}║      Blacklisted daemons will be paused; newly added/renamed files will not  ║${NC}"
  echo -e "${RED}║      be indexed by Spotlight until daemons are resumed.                      ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ USER RESPONSIBILITY NOTICE (NO WARRANTY):                                    ║${NC}"
  echo -e "${RED}║ By using this software, you take full and sole responsibility for all        ║${NC}"
  echo -e "${RED}║ consequences, data loss, terminated tasks, or system state modifications.    ║${NC}"
  echo -e "${RED}║ In no event shall authors or contributors be liable for any damages.         ║${NC}"
  echo -e "${RED}║ YOU ASSUME COMPLETE AND SOLE RESPONSIBILITY FOR ITS EXECUTION.              ║${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"

  echo ""
  confirm=$(prompt_confirmation "$(echo -e "${RED}${BOLD}[PROMPT] Do you understand what you are doing and accept sole responsibility to proceed? [y/N]: ${NC}")")
  if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
    echo -e "\n${YELLOW}[CANCELLED] Operation aborted by user. No processes were terminated.${NC}"
    exit 0
  fi
  echo -e "${GREEN}[ACCEPTED] Risk acknowledged by user. Proceeding with execution...${NC}"
fi

# ------------------------------------------------------------------------------
# Process Execution:
# - Blacklisted persistent background daemons -> Freeze with SIGSTOP
#   (Prevents launchd respawn loops; 0% CPU; memory compressed on demand)
# - Regular applications and loose processes -> Graceful SIGTERM followed by SIGKILL
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}>>> Executing cleanup (freezing persistent daemons, terminating apps)...${NC}"

FROZEN_COUNT=0
TERMINATED_COUNT=0
STUBBORN_COUNT=0

for ((i = 0; i < NUM_TARGETS; i++)); do
  pid="${TARGET_PIDS[$i]}"
  name="${TARGET_NAMES[$i]}"
  reason="${TARGET_REASONS[$i]}"
  already_frozen="${TARGET_IS_FROZEN[$i]}"

  if [[ "$reason" == BLACKLIST* ]]; then
    if [[ "$already_frozen" -eq 1 ]]; then
      FROZEN_COUNT=$((FROZEN_COUNT + 1))
    else
      # Freeze daemon so launchd does not resurrect it
      if kill -STOP "$pid" 2>/dev/null; then
        FROZEN_COUNT=$((FROZEN_COUNT + 1))
      else
        if [[ "$CURRENT_UID" -eq 0 ]]; then
          echo -e "  ${YELLOW}[PROTECTED BY SIP] PID $pid ($name) is protected by Apple System Integrity Protection.${NC}"
        else
          echo -e "  ${YELLOW}[PERMISSION DENIED] Could not pause PID $pid ($name). Requires root/sudo.${NC}"
        fi
      fi
    fi
  else
    # Regular application: Terminate
    if kill -TERM "$pid" 2>/dev/null; then
      TERMINATED_COUNT=$((TERMINATED_COUNT + 1))
    else
      if [[ "$CURRENT_UID" -eq 0 ]]; then
        echo -e "  ${YELLOW}[PROTECTED BY SIP] Could not terminate PID $pid ($name). Protected by macOS.${NC}"
      else
        echo -e "  ${YELLOW}[PERMISSION DENIED] Could not terminate PID $pid ($name). Requires root/sudo.${NC}"
      fi
    fi
  fi
done

if [[ $TERMINATED_COUNT -gt 0 ]]; then
  echo -e "Waiting ${GRACE_TIMEOUT}s for terminated processes to cleanly exit..."
  sleep "$GRACE_TIMEOUT"

  # Forceful termination for stubborn non-daemon processes
  for ((i = 0; i < NUM_TARGETS; i++)); do
    pid="${TARGET_PIDS[$i]}"
    name="${TARGET_NAMES[$i]}"
    reason="${TARGET_REASONS[$i]}"
    if [[ "$reason" != BLACKLIST* ]]; then
      if kill -0 "$pid" 2>/dev/null; then
        echo -e "${YELLOW}Process PID $pid ($name) still active; sending SIGKILL...${NC}"
        if kill -KILL "$pid" 2>/dev/null; then
          STUBBORN_COUNT=$((STUBBORN_COUNT + 1))
        fi
      fi
    fi
  done
fi

# ------------------------------------------------------------------------------
# Optional Purge Cache (if root)
# ------------------------------------------------------------------------------
if [[ "$PURGE_CACHE" == true ]]; then
  echo -e "\n${CYAN}>>> Purging inactive memory and disk cache buffers...${NC}"
  if [[ "$CURRENT_UID" -eq 0 ]]; then
    purge 2>/dev/null && echo -e "${GREEN}Cache purged successfully.${NC}" || echo -e "${YELLOW}Purge command encountered an issue.${NC}"
  else
    echo -e "${YELLOW}[NOTE] 'purge' requires root. Attempting via sudo...${NC}"
    sudo purge 2>/dev/null && echo -e "${GREEN}Cache purged successfully.${NC}" || echo -e "${YELLOW}Unable to run purge without passwordless sudo.${NC}"
  fi
fi

# ------------------------------------------------------------------------------
# Final Memory Report
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}                 Memory Reclaim Summary                         ${NC}"
echo -e "${CYAN}${BOLD}================================================================${NC}"
echo -e "Daemons Frozen (0% CPU):${GREEN}${BOLD} ${FROZEN_COUNT}${NC}"
echo -e "Applications Stopped:   ${GREEN}$(( TERMINATED_COUNT - STUBBORN_COUNT )) graceful, ${STUBBORN_COUNT} forced${NC}"
echo -e "Estimated Memory Freed: ${GREEN}${BOLD}${RECLAIMABLE_STR}${NC}"
FINAL_FREE_PCT=$(get_free_mem_percent)
echo -e "Initial Memory Free:    ${YELLOW}${INITIAL_FREE_PCT}${NC}"
echo -e "Current Memory Free:    ${GREEN}${BOLD}${FINAL_FREE_PCT}${NC}"
echo -e "${CYAN}================================================================${NC}"
