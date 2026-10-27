#!/usr/bin/env bash
# ==============================================================================
# Script: disable_spotlight_cloud.sh
# Purpose: Persistently disables macOS Spotlight file indexing, all cloud accounts
#          (iCloud, Apple Account sync, Google Drive, OneDrive, Dropbox, Box),
#          and fileproviderd across system reboots.
#
#          Spotlight indexing and cloud sync daemons are notorious for 100-300%+
#          CPU thrashing, excessive SSD wear, and multi-gigabyte memory pressure.
#          This utility applies persistent 'launchctl disable' overrides, disables
#          Spotlight disk indexing (mdutil -a -i off), and cleanly terminates
#          active process instances.
#
#          To restore all services and indexing at any time, run with: --enable
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
# CAUTION: By downloading, executing, or using this software, the user takes
# full and sole responsibility for any data loss, paused tasks, or system state
# modifications resulting from its execution.
# ==============================================================================

set -uo pipefail

ORIGINAL_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

FORCE=false
DRY_RUN=false
ACTION="disable"
LOG_FILE="${FREE_MMM_LOG_FILE:-$SCRIPT_DIR/free_memory.log}"
ENABLE_LOGGING=true
if [[ "${FREE_MMM_NO_LOG:-0}" == "1" || "${FREE_MMM_NO_LOG:-}" == "true" ]]; then
  ENABLE_LOGGING=false
fi
START_EXECUTION_EPOCH=0
GRACE_TIMEOUT=1.0

CURRENT_UID=$(id -u)
CURRENT_USER=$(id -un)
CONSOLE_UID=$(stat -f "%u" /dev/console 2>/dev/null || echo "$CURRENT_UID")
TARGET_UID="${SUDO_UID:-${CONSOLE_UID:-$CURRENT_UID}}"

# ------------------------------------------------------------------------------
# Target Service Definitions & Plist Mappings
# ------------------------------------------------------------------------------

# 1. Spotlight & Indexing Services
SPOTLIGHT_SYSTEM_SERVICES=(
  "com.apple.metadata.mds:/System/Library/LaunchDaemons/com.apple.metadata.mds.plist"
  "com.apple.metadata.mds.index:/System/Library/LaunchDaemons/com.apple.metadata.mds.index.plist"
  "com.apple.metadata.mds.scan:/System/Library/LaunchDaemons/com.apple.metadata.mds.scan.plist"
  "com.apple.metadata.mds.spindump:/System/Library/LaunchDaemons/com.apple.metadata.mds.spindump.plist"
)

SPOTLIGHT_USER_SERVICES=(
  "com.apple.Spotlight:/System/Library/LaunchAgents/com.apple.Spotlight.plist"
  "com.apple.corespotlightd:/System/Library/LaunchAgents/com.apple.corespotlightd.plist"
  "com.apple.managedcorespotlightd:/System/Library/LaunchAgents/com.apple.managedcorespotlightd.plist"
  "com.apple.corespotlightservice:/System/Library/LaunchAgents/com.apple.corespotlightservice.plist"
  "com.apple.spotlightknowledged:/System/Library/LaunchAgents/com.apple.spotlightknowledged.plist"
  "com.apple.spotlightknowledged.importer:/System/Library/LaunchAgents/com.apple.spotlightknowledged.importer.plist"
  "com.apple.spotlightknowledged.updater:/System/Library/LaunchAgents/com.apple.spotlightknowledged.updater.plist"
  "com.apple.SpotlightNetHelper:/System/Library/LaunchAgents/com.apple.SpotlightNetHelper.plist"
  "com.apple.metadata.mdflagwriter:/System/Library/LaunchAgents/com.apple.metadata.mdflagwriter.plist"
  "com.apple.mdworker.mail:/System/Library/LaunchAgents/com.apple.mdworker.mail.plist"
  "com.apple.mdworker.sizing:/System/Library/LaunchAgents/com.apple.mdworker.sizing.plist"
  "com.apple.mdworker.shared:/System/Library/LaunchAgents/com.apple.mdworker.shared.plist"
  "com.apple.mdworker.single.arm64:/System/Library/LaunchAgents/com.apple.mdworker.single.arm64.plist"
  "com.apple.mdworker.single.x86_64:/System/Library/LaunchAgents/com.apple.mdworker.single.x86_64.plist"
  "com.apple.CSExattrCryptoService:"
)

SPOTLIGHT_PROCESS_NAMES=(
  "mds"
  "mds_stores"
  "mdworker"
  "mdworker_shared"
  "corespotlightd"
  "spotlightknowledged"
  "Spotlight"
  "SpotlightNetHelper"
  "mdflagwriter"
  "mdbulkimport"
  "mdwrite"
  "CSExattrCryptoService"
)

# 2. fileproviderd Services
FILEPROVIDER_SYSTEM_SERVICES=(
  "com.apple.FileProvider:"
  "com.apple.fileproviderd:"
)

FILEPROVIDER_USER_SERVICES=(
  "com.apple.FileProvider:/System/Library/LaunchAgents/com.apple.FileProvider.plist"
  "com.apple.fileproviderd:"
  "com.apple.CloudDocs.MobileDocumentsFileProvider:"
  "com.apple.FileProvider.daemon:"
)

FILEPROVIDER_PROCESS_NAMES=(
  "fileproviderd"
  "FileProvider"
  "DFSFileProviderExtension"
  "OneDrive File Provider"
  "DropboxFileProvider"
  "Box File Provider"
)

# 3. All Cloud Accounts & Sync Services (Apple & 3rd Party)
CLOUD_SYSTEM_SERVICES=(
  "com.apple.cloudd:/System/Library/LaunchDaemons/com.apple.cloudd.plist"
  "com.apple.icloud.findmydeviced:/System/Library/LaunchDaemons/com.apple.icloud.findmydeviced.plist"
  "com.apple.findmy.findmybeaconingd:/System/Library/LaunchDaemons/com.apple.findmy.findmybeaconingd.plist"
)

CLOUD_USER_SERVICES=(
  "com.apple.accountsd:/System/Library/LaunchAgents/com.apple.accountsd.plist"
  "com.apple.accounts.dom:"
  "com.apple.appleaccountd:/System/Library/LaunchAgents/com.apple.appleaccountd.plist"
  "com.apple.storeaccountd:/System/Library/LaunchAgents/com.apple.storeaccountd.plist"
  "com.apple.amsaccountsd:/System/Library/LaunchAgents/com.apple.amsaccountsd.plist"
  "com.apple.cloudd:/System/Library/LaunchAgents/com.apple.cloudd.plist"
  "com.apple.bird:/System/Library/LaunchAgents/com.apple.bird.plist"
  "com.apple.cloudphotod:/System/Library/LaunchAgents/com.apple.cloudphotod.plist"
  "com.apple.cloudpaird:/System/Library/LaunchAgents/com.apple.cloudpaird.plist"
  "com.apple.cloudsettingssyncagent:"
  "com.apple.CloudSettingsSyncAgent:/System/Library/LaunchAgents/com.apple.CloudSettingsSyncAgent.plist"
  "com.apple.SafariBookmarksSyncAgent:/System/Library/LaunchAgents/com.apple.SafariBookmarksSyncAgent.plist"
  "com.apple.syncdefaultsd:/System/Library/LaunchAgents/com.apple.syncdefaultsd.plist"
  "com.apple.iCloudNotificationAgent:"
  "com.apple.iCloudHelper:"
  "com.apple.icloudmailagent:/System/Library/LaunchAgents/com.apple.icloudmailagent.plist"
  "com.apple.itunescloudd:/System/Library/LaunchAgents/com.apple.itunescloudd.plist"
  "com.apple.protectedcloudstorage.protectedcloudkeysyncing:/System/Library/LaunchAgents/com.apple.protectedcloudstorage.protectedcloudkeysyncing.plist"
  "com.apple.security.cloudkeychainproxy3:/System/Library/LaunchAgents/com.apple.security.cloudkeychainproxy3.plist"
  "com.apple.sbd:"
  "com.apple.familycircled:/System/Library/LaunchAgents/com.apple.familycircled.plist"
  "com.apple.familynotificationd:/System/Library/LaunchAgents/com.apple.familynotificationd.plist"
  "com.apple.homed:/System/Library/LaunchAgents/com.apple.homed.plist"
  "com.apple.dataaccess.dataaccessd:/System/Library/LaunchAgents/com.apple.dataaccess.dataaccessd.plist"
  "com.apple.exchange.exchangesyncd:/System/Library/LaunchAgents/com.apple.exchange.exchangesyncd.plist"
  "com.apple.exchangesyncd:"
  "com.apple.exchangenotesd:"
  "com.apple.networkserviceproxy-osx:/System/Library/LaunchAgents/com.apple.networkserviceproxy-osx.plist"
  "com.apple.transparencyd:/System/Library/LaunchAgents/com.apple.transparencyd.plist"
  "com.apple.swtransparencyd:/System/Library/LaunchAgents/com.apple.swtransparencyd.plist"
  "com.apple.AddressBook.SourceSync:/System/Library/LaunchAgents/com.apple.AddressBook.SourceSync.plist"
  "com.apple.CallHistorySyncHelper:/System/Library/LaunchAgents/com.apple.CallHistorySyncHelper.plist"
  "com.apple.remindd:/System/Library/LaunchAgents/com.apple.remindd.plist"
  "com.apple.icloud.searchpartyuseragent:/System/Library/LaunchAgents/com.apple.icloud.searchpartyuseragent.plist"
  "com.apple.icloud.findmydeviced.findmydevice-user-agent:/System/Library/LaunchAgents/com.apple.icloud.findmydeviced.findmydevice-user-agent.plist"
  "com.apple.privatecloudcomputed:/System/Library/LaunchAgents/com.apple.privatecloudcomputed.plist"
  "com.apple.BTServer.cloudpairing:"
  # 3rd Party Cloud Sync LaunchAgents
  "com.google.GoogleDrive:"
  "com.google.drivefs:"
  "com.google.drivefs.helper:"
  "com.google.GoogleUpdater.wake:"
  "com.google.keystone.agent:"
  "com.microsoft.OneDriveLauncher:"
  "com.microsoft.OneDriveStandaloneUpdater:"
  "com.microsoft.OneDrive.FileProvider:"
  "com.microsoft.OneDrive-mac.FileProvider:"
  "com.microsoft.SyncReporter:"
  "com.getdropbox.dropbox:"
  "com.dropbox.DropboxMacUpdate.agent:"
  "com.getdropbox.dropbox.garcon:"
  "com.box.desktop:"
  "com.box.desktop.ui:"
  "com.box.desktop.helper:"
  "com.nextcloud.desktopclient:"
  "org.owncloud.desktopclient:"
)

CLOUD_PROCESS_NAMES=(
  "accountsd"
  "appleaccountd"
  "storeaccountd"
  "amsaccountsd"
  "cloudd"
  "bird"
  "cloudphotod"
  "cloudpaird"
  "CloudSettingsSyncAgent"
  "cloudsettingssyncagent"
  "SafariBookmarksSyncAgent"
  "syncdefaultsd"
  "iCloudNotificationAgent"
  "icloudmailagent"
  "itunescloudd"
  "ProtectedCloudKeySyncing"
  "protectedcloudkeysyncing"
  "cloudkeychainproxy3"
  "sbd"
  "familycircled"
  "familynotificationd"
  "homed"
  "dataaccessd"
  "exchangesyncd"
  "exchangenotesd"
  "networkserviceproxy"
  "transparencyd"
  "swtransparencyd"
  "AddressBookSourceSync"
  "CallHistorySyncHelper"
  "remindd"
  "searchpartyuseragent"
  "findmydeviced"
  "findmybeaconingd"
  "findmydevice-user-agent"
  "privatecloudcomputed"
  "Google Drive"
  "GoogleDriveFS"
  "OneDrive"
  "OneDriveLauncher"
  "Dropbox"
  "Box"
  "nextcloud"
  "owncloud"
)

# ------------------------------------------------------------------------------
# Build Protected Ancestor & Kernel PID Shield
# ------------------------------------------------------------------------------
PROTECTED_PIDS=" 0 1 $$ $PPID "
cur_pid=$PPID
while [[ -n "$cur_pid" && "$cur_pid" -gt 1 ]]; do
  parent_pid=$(ps -o ppid= -p "$cur_pid" 2>/dev/null | tr -d ' ' || true)
  [[ -z "$parent_pid" ]] && break
  PROTECTED_PIDS="${PROTECTED_PIDS}${parent_pid} "
  cur_pid=$parent_pid
done

# ------------------------------------------------------------------------------
# Logging & User Interaction Subroutines
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
    end_epoch=$(date +%s)
    local duration=$((end_epoch - ${START_EXECUTION_EPOCH:-$end_epoch}))
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
[${start_date}] EXECUTION START: disable_spotlight_cloud.sh
Command:  $0 ${ORIGINAL_ARGS[*]:-}
User:     ${CURRENT_USER} (UID: ${CURRENT_UID}, Target UID: ${TARGET_UID})
PID:      $$ | PPID: $PPID
Action:   ${ACTION}
================================================================================
EOF

  exec 3>&1 4>&2
  exec > >(tee >(sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE") >&3) 2>&1
  trap finalize_execution_logging EXIT
}

# ------------------------------------------------------------------------------
# Check Root/Sudo Privileges
# ------------------------------------------------------------------------------
has_root_privileges() {
  if [[ "$CURRENT_UID" -eq 0 ]]; then
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# Action: Status Inspection (--status)
# ------------------------------------------------------------------------------
show_status() {
  echo -e "\n${CYAN}${BOLD}================================================================${NC}"
  echo -e "${CYAN}${BOLD}   Spotlight, Cloud Accounts & FileProvider Status Overview     ${NC}"
  echo -e "${CYAN}${BOLD}================================================================${NC}"

  # 1. Spotlight Indexing Status
  echo -e "\n${BOLD}[1] SPOTLIGHT DISK INDEXING STATUS:${NC}"
  if [[ "$CURRENT_UID" -eq 0 ]]; then
    pkill -CONT -x mds 2>/dev/null || true
    local md_out
    md_out=$(perl -e 'alarm shift; exec @ARGV' 2 mdutil -s / 2>/dev/null || echo "Unable to query mdutil")
    echo -e "  Root Volume (/): ${CYAN}${md_out}${NC}"
  else
    echo -e "  Root Volume (/): ${YELLOW}[NOTE] Volume indexing query requires root (Run: sudo $0 --status)${NC}"
  fi

  # 2. Check Launchd Disabled Overrides
  echo -e "\n${BOLD}[2] PERSISTENT LAUNCHD SERVICE OVERRIDES (gui/${TARGET_UID}):${NC}"
  local disabled_gui
  disabled_gui=$(launchctl print-disabled "gui/${TARGET_UID}" 2>/dev/null || echo "")

  check_service_state() {
    local label="$1"
    local disabled_list="$2"
    if echo "$disabled_list" | grep -q "\"$label\" => disabled"; then
      echo -e "${RED}DISABLED${NC}"
    elif echo "$disabled_list" | grep -q "\"$label\" => enabled"; then
      echo -e "${GREEN}ENABLED${NC}"
    else
      echo -e "${YELLOW}DEFAULT${NC}"
    fi
  }

  echo -n "  • Spotlight GUI (com.apple.Spotlight): "; check_service_state "com.apple.Spotlight" "$disabled_gui"
  echo -n "  • CoreSpotlight (com.apple.corespotlightd): "; check_service_state "com.apple.corespotlightd" "$disabled_gui"
  echo -n "  • FileProvider (com.apple.FileProvider): "; check_service_state "com.apple.FileProvider" "$disabled_gui"
  echo -n "  • Internet Accounts (com.apple.accountsd): "; check_service_state "com.apple.accountsd" "$disabled_gui"
  echo -n "  • CloudKit Sync (com.apple.cloudd): "; check_service_state "com.apple.cloudd" "$disabled_gui"
  echo -n "  • iCloud Drive (com.apple.bird): "; check_service_state "com.apple.bird" "$disabled_gui"
  echo -n "  • iCloud Photos (com.apple.cloudphotod): "; check_service_state "com.apple.cloudphotod" "$disabled_gui"

  # 3. Active Process Instances
  echo -e "\n${BOLD}[3] CURRENTLY RUNNING TARGET PROCESSES:${NC}"
  local found_count=0
  local all_targets=("${SPOTLIGHT_PROCESS_NAMES[@]}" "${FILEPROVIDER_PROCESS_NAMES[@]}" "${CLOUD_PROCESS_NAMES[@]}")

  while IFS=" " read -r pid p_uid stat comm; do
    [[ -z "$pid" || "$pid" == "PID" ]] && continue
    local clean_comm="${comm#-}"
    local base_name="${clean_comm##*/}"

    for tname in "${all_targets[@]}"; do
      if [[ "$base_name" == "$tname" ]]; then
        found_count=$((found_count + 1))
        local state_desc="RUNNING"
        if [[ "$stat" == T* ]]; then
          state_desc="PAUSED (SIGSTOP)"
        fi
        printf "  PID %-7s %-25s User: %-10s State: %s\n" "$pid" "$base_name" "$p_uid" "$state_desc"
        break
      fi
    done
  done < <(ps -eo pid=,user=,stat=,comm=)

  if [[ $found_count -eq 0 ]]; then
    echo -e "  ${GREEN}No targeted Spotlight, Cloud, or FileProvider processes are currently running.${NC}"
  fi

  echo -e "\n${CYAN}================================================================${NC}"
}

# ------------------------------------------------------------------------------
# Action: Persistently Disable Services & Terminate
# ------------------------------------------------------------------------------
disable_all_targets() {
  echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║                       CRITICAL WARNING & RISK NOTICE                         ║${NC}"
  echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${RED}║ You are about to PERSISTENTLY disable:                                       ║${NC}"
  echo -e "${RED}║   1. Spotlight File & Metadata Indexing (mds, mdutil, corespotlightd)        ║${NC}"
  echo -e "${RED}║   2. All Cloud Accounts & Sync (iCloud, Apple Accounts, accountsd, cloudd,   ║${NC}"
  echo -e "${RED}║      bird, Google Drive, OneDrive, Dropbox, Box)                             ║${NC}"
  echo -e "${RED}║   3. macOS FileProvider Daemon (fileproviderd)                               ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ OPERATIONAL CONSEQUENCES:                                                    ║${NC}"
  echo -e "${RED}║   • Newly created/modified files will NOT be indexed by Spotlight.           ║${NC}"
  echo -e "${RED}║   • Automatic cloud syncing (iCloud Drive, Photos, Contacts) will STOP.     ║${NC}"
  echo -e "${RED}║   • FileProvider cloud volume integration will be suspended.                 ║${NC}"
  echo -e "${RED}║   • Changes are PERSISTENT and remain across system reboots.                 ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ RESTORATION:                                                                 ║${NC}"
  echo -e "${RED}║   You can restore all services anytime by running:                           ║${NC}"
  echo -e "${RED}║   $0 --enable                                                                ║${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"

  if [[ "$FORCE" != true && "$DRY_RUN" != true ]]; then
    echo ""
    confirm=$(prompt_confirmation "$(echo -e "${RED}${BOLD}[PROMPT] Persistently disable Spotlight indexing, cloud accounts, and fileproviderd? [y/N]: ${NC}")")
    if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
      echo -e "\n${YELLOW}[CANCELLED] Operation aborted by user. No system changes were made.${NC}"
      exit 0
    fi
    echo -e "${GREEN}[ACCEPTED] Risk acknowledged. Proceeding...${NC}\n"
  fi

  local has_root=false
  if has_root_privileges; then
    has_root=true
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}${BOLD}[DRY-RUN] Previewing actions without applying modifications:${NC}"
  else
    echo -e "\n${CYAN}${BOLD}>>> Applying persistent service disablements...${NC}"
  fi

  # 1. Turn off Spotlight disk indexing across all volumes
  if [[ "$has_root" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo -e "  [DRY-RUN] Would execute: sudo mdutil -a -i off && sudo mdutil -d /"
    else
      echo -e "Turning off Spotlight disk indexing across all volumes..."
      sudo pkill -CONT -x mds 2>/dev/null || true
      perl -e 'alarm shift; exec @ARGV' 4 sudo mdutil -a -i off 2>/dev/null || sudo mdutil -i off / 2>/dev/null || true
      perl -e 'alarm shift; exec @ARGV' 4 sudo mdutil -d / 2>/dev/null || true
      echo -e "  [${GREEN}DISABLED${NC}] Spotlight disk indexing (mdutil -a -i off)"
    fi
  else
    echo -e "${YELLOW}[NOTE] Spotlight volume disk indexing (mdutil) requires sudo.${NC}"
    echo -e "${YELLOW}       Run with 'sudo $0' for complete root-level indexing disablement.${NC}"
  fi

  # Helper subroutine to disable services in launchd
  disable_service_entry() {
    local domain="$1"
    local entry="$2"
    local label="${entry%%:*}"
    [[ -z "$label" ]] && continue

    if [[ "$domain" == "system" ]]; then
      if [[ "$has_root" == true ]]; then
        if [[ "$DRY_RUN" == true ]]; then
          echo -e "  [DRY-RUN] Would disable system service: system/$label"
        else
          sudo launchctl disable "system/$label" 2>/dev/null || true
          sudo launchctl bootout "system/$label" 2>/dev/null || true
          echo -e "  [${GREEN}DISABLED - SYSTEM${NC}] $label"
        fi
      fi
    else
      if [[ "$DRY_RUN" == true ]]; then
        echo -e "  [DRY-RUN] Would disable user service: gui/${TARGET_UID}/$label"
      else
        launchctl disable "gui/${TARGET_UID}/$label" 2>/dev/null || true
        launchctl disable "user/${TARGET_UID}/$label" 2>/dev/null || true
        launchctl bootout "gui/${TARGET_UID}/$label" 2>/dev/null || true
        echo -e "  [${GREEN}DISABLED - USER GUI${NC}] $label"
      fi
    fi
  }

  # 2. Disable Spotlight Services
  echo -e "\nDisabling Spotlight Launchd Services..."
  for s in "${SPOTLIGHT_SYSTEM_SERVICES[@]}"; do
    disable_service_entry "system" "$s"
  done
  for s in "${SPOTLIGHT_USER_SERVICES[@]}"; do
    disable_service_entry "gui" "$s"
  done

  # 3. Disable fileproviderd Services
  echo -e "\nDisabling fileproviderd Launchd Services..."
  for s in "${FILEPROVIDER_SYSTEM_SERVICES[@]}"; do
    disable_service_entry "system" "$s"
  done
  for s in "${FILEPROVIDER_USER_SERVICES[@]}"; do
    disable_service_entry "gui" "$s"
  done

  # 4. Disable Cloud Accounts & Sync Services
  echo -e "\nDisabling Cloud Accounts & Sync Launchd Services..."
  for s in "${CLOUD_SYSTEM_SERVICES[@]}"; do
    disable_service_entry "system" "$s"
  done
  for s in "${CLOUD_USER_SERVICES[@]}"; do
    disable_service_entry "gui" "$s"
  done

  # 5. Terminate Active Running Instances Cleanly
  echo -e "\nStopping running instances of disabled daemons..."
  local all_targets=("${SPOTLIGHT_PROCESS_NAMES[@]}" "${FILEPROVIDER_PROCESS_NAMES[@]}" "${CLOUD_PROCESS_NAMES[@]}")
  local stopped_count=0

  while IFS=" " read -r pid p_uid stat comm; do
    [[ -z "$pid" || "$pid" == "PID" ]] && continue
    local clean_comm="${comm#-}"
    local base_name="${clean_comm##*/}"

    # Protect ancestor / current shell PID
    if [[ " $PROTECTED_PIDS " == *" $pid "* ]]; then
      continue
    fi

    local matched=0
    for tname in "${all_targets[@]}"; do
      if [[ "$base_name" == "$tname" ]]; then
        matched=1
        break
      fi
    done
    [[ $matched -eq 0 ]] && continue

    if [[ "$DRY_RUN" == true ]]; then
      echo -e "  [DRY-RUN] Would terminate: $base_name (PID $pid, User: $p_uid)"
      stopped_count=$((stopped_count + 1))
      continue
    fi

    # If paused with SIGSTOP, wake it with SIGCONT so it handles SIGTERM
    if [[ "$stat" == T* ]]; then
      kill -CONT "$pid" 2>/dev/null || ( [[ "$has_root" == true ]] && sudo kill -CONT "$pid" 2>/dev/null ) || true
    fi

    if kill -TERM "$pid" 2>/dev/null || ( [[ "$has_root" == true ]] && sudo kill -TERM "$pid" 2>/dev/null ); then
      stopped_count=$((stopped_count + 1))
      echo -e "  [${GREEN}STOPPED${NC}] $base_name (PID $pid)"
    fi
  done < <(ps -eo pid=,user=,stat=,comm=)

  # Follow up with SIGKILL if any processes fail to terminate within grace period
  if [[ "$DRY_RUN" != true && $stopped_count -gt 0 ]]; then
    sleep "$GRACE_TIMEOUT"
    while IFS=" " read -r pid p_uid stat comm; do
      [[ -z "$pid" || "$pid" == "PID" ]] && continue
      local clean_comm="${comm#-}"
      local base_name="${clean_comm##*/}"

      if [[ " $PROTECTED_PIDS " == *" $pid "* ]]; then
        continue
      fi

      local matched=0
      for tname in "${all_targets[@]}"; do
        if [[ "$base_name" == "$tname" ]]; then
          matched=1
          break
        fi
      done
      [[ $matched -eq 0 ]] && continue

      kill -KILL "$pid" 2>/dev/null || ( [[ "$has_root" == true ]] && sudo kill -KILL "$pid" 2>/dev/null ) || true
    done < <(ps -eo pid=,user=,stat=,comm=)
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}${BOLD}[DRY-RUN COMPLETE] No modifications were committed to disk or launchd.${NC}"
  else
    echo -e "\n${GREEN}${BOLD}[SUCCESS] Spotlight indexing, cloud accounts, and fileproviderd disabled!${NC}"
    echo -e "They are marked disabled in launchd's persistent store and will ${BOLD}NOT${NC} restart after reboot."
    echo -e "To re-enable and restore defaults anytime, run: ${BOLD}$0 --enable${NC}\n"
  fi
}

# ------------------------------------------------------------------------------
# Action: Re-Enable Services & Restore Defaults (--enable)
# ------------------------------------------------------------------------------
enable_all_targets() {
  echo -e "\n${CYAN}${BOLD}================================================================${NC}"
  echo -e "${CYAN}${BOLD}  Restoring Spotlight, Cloud Accounts & fileproviderd Services   ${NC}"
  echo -e "${CYAN}${BOLD}================================================================${NC}"

  local has_root=false
  if has_root_privileges; then
    has_root=true
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}${BOLD}[DRY-RUN] Previewing restoration without applying modifications:${NC}"
  else
    echo -e "\nRe-enabling services in launchd and bootstrapping..."
  fi

  enable_service_entry() {
    local domain="$1"
    local entry="$2"
    local label="${entry%%:*}"
    local plist="${entry#*:}"
    [[ -z "$label" ]] && continue

    if [[ "$domain" == "system" ]]; then
      if [[ "$has_root" == true ]]; then
        if [[ "$DRY_RUN" == true ]]; then
          echo -e "  [DRY-RUN] Would re-enable system service: system/$label"
        else
          sudo launchctl enable "system/$label" 2>/dev/null || true
          if [[ -n "$plist" && -f "$plist" ]]; then
            sudo launchctl bootstrap system "$plist" 2>/dev/null || true
          fi
          sudo launchctl kickstart -k "system/$label" 2>/dev/null || true
          echo -e "  [${GREEN}ENABLED - SYSTEM${NC}] $label"
        fi
      fi
    else
      if [[ "$DRY_RUN" == true ]]; then
        echo -e "  [DRY-RUN] Would re-enable user service: gui/${TARGET_UID}/$label"
      else
        launchctl enable "gui/${TARGET_UID}/$label" 2>/dev/null || true
        launchctl enable "user/${TARGET_UID}/$label" 2>/dev/null || true
        if [[ -n "$plist" && -f "$plist" ]]; then
          launchctl bootstrap "gui/${TARGET_UID}" "$plist" 2>/dev/null || true
        fi
        launchctl kickstart -k "gui/${TARGET_UID}/$label" 2>/dev/null || true
        echo -e "  [${GREEN}ENABLED - USER GUI${NC}] $label"
      fi
    fi
  }

  # 1. Re-enable Spotlight
  for s in "${SPOTLIGHT_SYSTEM_SERVICES[@]}"; do
    enable_service_entry "system" "$s"
  done
  for s in "${SPOTLIGHT_USER_SERVICES[@]}"; do
    enable_service_entry "gui" "$s"
  done

  # 2. Re-enable fileproviderd
  for s in "${FILEPROVIDER_SYSTEM_SERVICES[@]}"; do
    enable_service_entry "system" "$s"
  done
  for s in "${FILEPROVIDER_USER_SERVICES[@]}"; do
    enable_service_entry "gui" "$s"
  done

  # 3. Re-enable Cloud Accounts & Sync
  for s in "${CLOUD_SYSTEM_SERVICES[@]}"; do
    enable_service_entry "system" "$s"
  done
  for s in "${CLOUD_USER_SERVICES[@]}"; do
    enable_service_entry "gui" "$s"
  done

  # 4. Turn Spotlight disk indexing back on
  if [[ "$has_root" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo -e "  [DRY-RUN] Would execute: sudo mdutil -a -i on"
    else
      echo -e "\nRe-enabling Spotlight disk indexing across all volumes..."
      perl -e 'alarm shift; exec @ARGV' 4 sudo mdutil -a -i on 2>/dev/null || sudo mdutil -i on / 2>/dev/null || true
      echo -e "  [${GREEN}ENABLED${NC}] Spotlight disk indexing restored (mdutil -a -i on)"
    fi
  fi

  # 5. Resume any paused processes (SIGCONT)
  echo -e "\nResuming any paused processes (SIGCONT)..."
  local all_targets=("${SPOTLIGHT_PROCESS_NAMES[@]}" "${FILEPROVIDER_PROCESS_NAMES[@]}" "${CLOUD_PROCESS_NAMES[@]}")
  while IFS=" " read -r pid p_uid stat comm; do
    [[ -z "$pid" || "$pid" == "PID" ]] && continue
    local clean_comm="${comm#-}"
    local base_name="${clean_comm##*/}"

    local matched=0
    for tname in "${all_targets[@]}"; do
      if [[ "$base_name" == "$tname" ]]; then
        matched=1
        break
      fi
    done
    [[ $matched -eq 0 ]] && continue

    if [[ "$stat" == T* ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        echo -e "  [DRY-RUN] Would resume (SIGCONT): $base_name (PID $pid)"
      else
        if kill -CONT "$pid" 2>/dev/null || ( [[ "$has_root" == true ]] && sudo kill -CONT "$pid" 2>/dev/null ); then
          echo -e "  [${GREEN}RESUMED${NC}] $base_name (PID $pid)"
        fi
      fi
    fi
  done < <(ps -eo pid=,user=,stat=,comm=)

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}${BOLD}[DRY-RUN COMPLETE] Restoration preview finished.${NC}"
  else
    echo -e "\n${GREEN}${BOLD}[SUCCESS] Spotlight indexing, cloud accounts, and fileproviderd have been restored!${NC}\n"
  fi
}

# ------------------------------------------------------------------------------
# Command-Line Option Parsing
# ------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -s|--status)
      ACTION="status"
      shift
      ;;
    -e|--enable|--restore)
      ACTION="enable"
      shift
      ;;
    --disable)
      ACTION="disable"
      shift
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
    -h|--help)
      echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
      echo -e "Disables macOS Spotlight indexing, all cloud accounts (iCloud, Apple Accounts, 3rd party), and fileproviderd.\n"
      echo -e "Options:"
      echo -e "  --disable                (Default) Persistently disable Spotlight indexing, cloud accounts, and fileproviderd."
      echo -e "  -e, --enable, --restore  Re-enable services, bootstrap plists, kickstart daemons, and restore indexing."
      echo -e "  -s, --status             Display current service and indexing status across system and user domains."
      echo -e "  -d, --dry-run            Preview changes without modifying launchd configuration or stopping processes."
      echo -e "  -f, --force              Bypass interactive confirmation prompt (ideal for automated CI/CD scripts)."
      echo -e "  -l, --log <FILE>         Path to log file (default: free_memory.log)."
      echo -e "  --no-log                 Disable appending execution logs to file."
      echo -e "  -h, --help               Display this help message.\n"
      echo -e "Examples:"
      echo -e "  $0                       # Interactive prompt to disable indexing, cloud accounts, and fileproviderd"
      echo -e "  sudo $0                  # Full root-level disablement including mdutil volume indexing"
      echo -e "  $0 --status              # Check status of Spotlight, fileproviderd, and cloud services"
      echo -e "  sudo $0 --enable         # Restore services to system defaults and turn indexing back on"
      exit 0
      ;;
    -*)
      echo -e "${RED}[ERROR] Unknown option: $1${NC}" >&2
      echo -e "Run '$0 --help' for available options." >&2
      exit 1
      ;;
    *)
      shift
      ;;
  esac
done

# Initialize audit execution logging
init_execution_logging

# Route to specified action
case "$ACTION" in
  status)
    show_status
    ;;
  enable)
    enable_all_targets
    ;;
  disable)
    disable_all_targets
    ;;
esac
