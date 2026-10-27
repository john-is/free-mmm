#!/usr/bin/env bash
# ==============================================================================
# Script: unfreeze_daemons.sh
# Purpose: Resume frozen macOS background daemons using SIGCONT.
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
# full and sole responsibility for any resumed tasks or system state
# modifications resulting from its execution.
# ==============================================================================

set -uo pipefail

ORIGINAL_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

BLACKLIST_FILE=""
LOG_FILE="${FREE_MMM_LOG_FILE:-$SCRIPT_DIR/free_memory.log}"
ENABLE_LOGGING=true
if [[ "${FREE_MMM_NO_LOG:-0}" == "1" || "${FREE_MMM_NO_LOG:-}" == "true" ]]; then
  ENABLE_LOGGING=false
fi
START_EXECUTION_EPOCH=0

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
[${start_date}] EXECUTION START: unfreeze_daemons.sh
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
    -f|--force)
      # Accepted for CLI uniformity
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
    -h|--help)
      echo -e "${BOLD}Usage:${NC} $0 [OPTIONS] [path/to/blacklist.txt]"
      echo -e "Resumes paused background daemons defined in the blacklist using SIGCONT."
      echo -e "Options:"
      echo -e "  -b, --blacklist <FILE>   Path to blacklist file (default: blacklist.txt)."
      echo -e "  -l, --log <FILE>         Path to log file (default: free_memory.log)."
      echo -e "  --no-log                 Disable appending execution logs to file."
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

declare -a BLACKLIST_PATTERNS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  clean_line="${line%%#*}"
  clean_line="${clean_line#"${clean_line%%[![:space:]]*}"}"
  clean_line="${clean_line%"${clean_line##*[![:space:]]}"}"
  if [[ -n "$clean_line" ]]; then
    BLACKLIST_PATTERNS+=("$clean_line")
  fi
done < "$BLACKLIST_FILE"

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

init_execution_logging

echo -e "${CYAN}>>> Scanning and resuming paused background daemons (SIGCONT)...${NC}"
RESUMED_USER=0
RESUMED_ROOT=0
ALREADY_RUNNING=0
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

  # Only resume daemons that are actually paused (state T)
  if [[ "$stat" != T* ]]; then
    ALREADY_RUNNING=$((ALREADY_RUNNING + 1))
    continue
  fi

  if [[ "$CURRENT_UID" -eq 0 ]]; then
    if kill -CONT "$pid" 2>/dev/null; then
      if [[ "$uid" -eq 0 ]]; then
        echo -e "  [${GREEN}RESUMED - ROOT${NC}] $base_name (PID $pid)"
        RESUMED_ROOT=$((RESUMED_ROOT + 1))
      else
        echo -e "  [${GREEN}RESUMED - USER${NC}] $base_name (PID $pid)"
        RESUMED_USER=$((RESUMED_USER + 1))
      fi
    else
      echo -e "  ${YELLOW}[FAILED] Could not resume PID $pid ($base_name).${NC}"
    fi
  else
    if [[ "$uid" -eq "$CURRENT_UID" || "$uid" -eq "$TARGET_UID" ]]; then
      if kill -CONT "$pid" 2>/dev/null; then
        echo -e "  [${GREEN}RESUMED${NC}] $base_name (PID $pid)"
        RESUMED_USER=$((RESUMED_USER + 1))
      else
        echo -e "  ${YELLOW}[PERMISSION DENIED] Could not resume PID $pid ($base_name). Requires root/sudo.${NC}"
      fi
    else
      ROOT_REQUIRED_NAMES+=("$base_name (PID $pid, UID $uid)")
    fi
  fi
done < <(ps -eo pid=,uid=,stat=,comm=)

echo ""
echo -e "${GREEN}${BOLD}>>> Summary: Total $RESUMED_USER user daemon(s) and $RESUMED_ROOT root daemon(s) resumed.${NC}"
if [[ $ALREADY_RUNNING -gt 0 ]]; then
  echo -e ">>> $ALREADY_RUNNING targeted daemon(s) were already active and running."
fi

if [[ ${#ROOT_REQUIRED_NAMES[@]} -gt 0 ]]; then
  echo -e "\n${YELLOW}[NOTE] The following system daemons are paused under system accounts and require sudo to resume:${NC}"
  for rname in "${ROOT_REQUIRED_NAMES[@]}"; do
    echo -e "       - $rname"
  done
  echo -e "       To resume them, run: ${BOLD}sudo $0${NC}"
fi
