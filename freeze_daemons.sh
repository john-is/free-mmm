#!/usr/bin/env bash
# ==============================================================================
# Script: freeze_daemons.sh
# Purpose: Freeze stubborn macOS background daemons using SIGSTOP.
#          Because processes are paused (state T) rather than terminated,
#          launchd will NOT respawn them. They consume 0% CPU and their RAM
#          is evicted to compressed swap as soon as local LLMs request memory.
#          Targets are read dynamically from the blacklist configuration.
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
BLACKLIST_FILE=""
LOG_FILE="${FREE_MMM_LOG_FILE:-$SCRIPT_DIR/free_memory.log}"
ENABLE_LOGGING=true
if [[ "${FREE_MMM_NO_LOG:-0}" == "1" || "${FREE_MMM_NO_LOG:-}" == "true" ]]; then
  ENABLE_LOGGING=false
fi
START_EXECUTION_EPOCH=0

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
[${start_date}] EXECUTION START: freeze_daemons.sh
Command:  $0 ${ORIGINAL_ARGS[*]:-}
User:     $(whoami) (UID: $(id -u))
PID:      $$ | PPID: $PPID
================================================================================
EOF

  exec 3>&1 4>&2
  exec > >(tee >(sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE") >&3) 2>&1
  trap finalize_execution_logging EXIT
}

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
    --install-autofreeze)
      exec "$SCRIPT_DIR/install_autofreeze.sh"
      ;;
    --uninstall-autofreeze)
      exec "$SCRIPT_DIR/uninstall_autofreeze.sh"
      ;;
    -h|--help)
      echo -e "${BOLD}Usage:${NC} $0 [OPTIONS] [path/to/blacklist.txt]"
      echo -e "Freezes persistent background daemons defined in the blacklist using SIGSTOP."
      echo -e "Options:"
      echo -e "  -d, --dry-run            Preview daemons that would be paused without pausing them."
      echo -e "  -f, --force              Bypass interactive confirmation."
      echo -e "  -b, --blacklist <FILE>   Path to blacklist file (default: blacklist.txt)."
      echo -e "  -l, --log <FILE>         Path to log file (default: free_memory.log)."
      echo -e "  --no-log                 Disable appending execution logs to file."
      echo -e "  --install-autofreeze     Install login LaunchAgent to auto-freeze on boot."
      echo -e "  --uninstall-autofreeze   Remove the boot auto-freeze LaunchAgent."
      echo -e "  -h, --help               Display this help."
      exit 0
      ;;
    -*)
      echo -e "${RED}[ERROR] Unknown option: $1${NC}"
      exit 1
      ;;
    *)
      if [[ -z "$BLACKLIST_FILE" ]]; then
        BLACKLIST_FILE="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$BLACKLIST_FILE" ]]; then
  if [[ -f "$SCRIPT_DIR/blacklist.txt" ]]; then
    BLACKLIST_FILE="$SCRIPT_DIR/blacklist.txt"
  elif [[ -f "blacklist.txt" ]]; then
    BLACKLIST_FILE="blacklist.txt"
  fi
fi

if [[ -z "$BLACKLIST_FILE" || ! -f "$BLACKLIST_FILE" ]]; then
  echo -e "${RED}[ERROR] Blacklist configuration file not found:${NC} ${BLACKLIST_FILE:-blacklist.txt}"
  echo -e "Looked in: $SCRIPT_DIR/blacklist.txt and ./blacklist.txt"
  exit 1
fi

# Load blacklist rules
declare -a BLACKLIST_PATTERNS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  clean_line="${line%%#*}"
  clean_line="${clean_line#"${clean_line%%[![:space:]]*}"}"
  clean_line="${clean_line%"${clean_line##*[![:space:]]}"}"
  if [[ -n "$clean_line" ]]; then
    BLACKLIST_PATTERNS+=("$clean_line")
  fi
done < "$BLACKLIST_FILE"

if [[ ${#BLACKLIST_PATTERNS[@]} -eq 0 ]]; then
  echo -e "${YELLOW}[WARNING] No rules found in $BLACKLIST_FILE. Nothing to freeze.${NC}"
  exit 0
fi

init_execution_logging

matches_pattern() {
  local target_base="$1"
  local target_comm="$2"
  local pattern="$3"

  if [[ "$target_base" == "$pattern" ]]; then
    return 0
  fi
  if [[ "$pattern" == *"*"* || "$pattern" == *"?"* || "$pattern" == *"/"* ]]; then
    if [[ "$target_comm" == $pattern || "$target_base" == $pattern || "$target_comm" == "$pattern"/* ]]; then
      return 0
    fi
  fi
  local stripped_pattern="${pattern%.app}"
  if [[ "$target_comm" == *"/$stripped_pattern.app/"* || "$target_comm" == *"/$stripped_pattern/"* || "$target_comm" == *"/$pattern/"* ]]; then
    return 0
  fi
  return 1
}

CURRENT_UID=$(id -u)
TARGET_UID="${SUDO_UID:-$CURRENT_UID}"

if [[ "$DRY_RUN" == true ]]; then
  echo -e "\n${CYAN}${BOLD}>>> [DRY-RUN PREVIEW] Scanning daemons from $BLACKLIST_FILE...${NC}"
  echo -e "${MAGENTA}${BOLD}No processes will be modified or paused.${NC}\n"
elif [[ "$FORCE" != true ]]; then
  echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║                       CRITICAL WARNING & RISK NOTICE                         ║${NC}"
  echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${RED}${BOLD}║ [BACKGROUND DAEMON SUSPENSION (SIGSTOP)]                                     ║${NC}"
  echo -e "${RED}║ You are about to pause/freeze targeted background services & daemons:        ║${NC}"
  echo -e "${RED}║   • File search indexing, metadata stores, and system coordinators           ║${NC}"
  echo -e "${RED}║   • Background suggestion agents, contextual telemetry, and heuristics       ║${NC}"
  echo -e "${RED}║   • Media indexing, photo analysis, and cloud asset synchronization engines  ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ CONSEQUENCES:                                                                ║${NC}"
  echo -e "${RED}║   • Search indexers will not index newly created files until resumed.        ║${NC}"
  echo -e "${RED}║   • Smart suggestion heuristics in desktop apps will be paused.              ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ USER RESPONSIBILITY NOTICE (NO WARRANTY):                                    ║${NC}"
  echo -e "${RED}║ By downloading, executing, or using this software, you agree that you take   ║${NC}"
  echo -e "${RED}║ full and sole responsibility for all consequences, paused tasks, or system   ║${NC}"
  echo -e "${RED}║ state modifications. In no event shall authors or contributors be liable for ║${NC}"
  echo -e "${RED}║ any damages. YOU ASSUME COMPLETE AND SOLE RESPONSIBILITY FOR ITS EXECUTION. ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ RESTORATION: Resume all daemons anytime with: ./unfreeze_daemons.sh          ║${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"

  echo ""
  confirm=$(prompt_confirmation "$(echo -e "${RED}${BOLD}[PROMPT] Do you understand what you are doing and accept sole responsibility to proceed? [y/N]: ${NC}")")
  if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
    echo -e "\n${YELLOW}[CANCELLED] Operation aborted by user. No daemons were frozen.${NC}"
    exit 0
  fi
  echo -e "${GREEN}[ACCEPTED] Risk acknowledged by user. Freezing daemons...${NC}\n"
else
  echo -e "${CYAN}>>> Scanning and pausing daemons from $BLACKLIST_FILE...${NC}"
fi

FROZEN_USER=0
FROZEN_ROOT=0
ALREADY_FROZEN=0
ROOT_REQUIRED_NAMES=()

while IFS=" " read -r pid uid stat comm; do
  [[ -z "$pid" || "$pid" == "PID" ]] && continue
  clean_comm="${comm#-}"
  base_name="${clean_comm##*/}"

  matched=0
  for bpattern in "${BLACKLIST_PATTERNS[@]}"; do
    if matches_pattern "$base_name" "$comm" "$bpattern"; then
      matched=1
      break
    fi
  done
  [[ $matched -eq 0 ]] && continue

  if [[ "$stat" == T* ]]; then
    echo -e "  [${YELLOW}ALREADY PAUSED${NC}] $base_name (PID $pid)"
    ALREADY_FROZEN=$((ALREADY_FROZEN + 1))
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    if [[ "$uid" -eq "$CURRENT_UID" || "$uid" -eq "$TARGET_UID" || "$CURRENT_UID" -eq 0 ]]; then
      echo -e "  [${MAGENTA}WOULD FREEZE${NC}] $base_name (PID $pid, UID $uid)"
      FROZEN_USER=$((FROZEN_USER + 1))
    else
      echo -e "  [${YELLOW}WOULD FREEZE - ROOT REQUIRED${NC}] $base_name (PID $pid, UID $uid)"
      ROOT_REQUIRED_NAMES+=("$base_name (PID $pid, UID $uid)")
    fi
    continue
  fi

  if [[ "$CURRENT_UID" -eq 0 ]]; then
    if kill -STOP "$pid" 2>/dev/null; then
      if [[ "$uid" -eq 0 ]]; then
        echo -e "  [${GREEN}FROZEN - ROOT${NC}] $base_name (PID $pid, 0% CPU)"
        FROZEN_ROOT=$((FROZEN_ROOT + 1))
      else
        echo -e "  [${GREEN}FROZEN - USER${NC}] $base_name (PID $pid, 0% CPU)"
        FROZEN_USER=$((FROZEN_USER + 1))
      fi
    else
      echo -e "  ${YELLOW}[FAILED] Could not pause PID $pid ($base_name).${NC}"
    fi
  else
    if [[ "$uid" -eq "$CURRENT_UID" || "$uid" -eq "$TARGET_UID" ]]; then
      if kill -STOP "$pid" 2>/dev/null; then
        echo -e "  [${GREEN}FROZEN${NC}] $base_name (PID $pid, 0% CPU)"
        FROZEN_USER=$((FROZEN_USER + 1))
      else
        echo -e "  ${YELLOW}[PERMISSION DENIED] Could not pause PID $pid ($base_name). Requires root/sudo.${NC}"
      fi
    else
      ROOT_REQUIRED_NAMES+=("$base_name (PID $pid, UID $uid)")
    fi
  fi
done < <(ps -eo pid=,uid=,stat=,comm=)

echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo -e "${MAGENTA}${BOLD}>>> [DRY-RUN COMPLETE] $FROZEN_USER daemon(s) would be frozen.${NC}"
else
  echo -e "${GREEN}${BOLD}>>> Summary: $FROZEN_USER user daemon(s) and $FROZEN_ROOT root daemon(s) newly frozen.${NC}"
fi
if [[ $ALREADY_FROZEN -gt 0 ]]; then
  echo -e ">>> $ALREADY_FROZEN daemon(s) were already in a paused state."
fi
echo -e ">>> launchd will NOT respawn them because their processes remain paused."

if [[ ${#ROOT_REQUIRED_NAMES[@]} -gt 0 ]]; then
  echo -e "\n${YELLOW}[NOTE] The following system daemons run under system accounts and require sudo to freeze:${NC}"
  for rname in "${ROOT_REQUIRED_NAMES[@]}"; do
    echo -e "       - $rname"
  done
  echo -e "       To freeze them, run: ${BOLD}sudo $0${NC}"
fi

echo -e "\n>>> To resume them later, run: ${BOLD}./unfreeze_daemons.sh${NC}"
