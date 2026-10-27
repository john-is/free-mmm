#!/usr/bin/env bash
# ==============================================================================
# Script: kill_non_user_apps.sh
# Purpose: Loop over all running processes and terminate (or freeze) everything
#          that is NOT a genuine user application.
#          Essential system infrastructure (kernel, WindowServer, audio,
#          networking, security, login session, terminals, IDEs, and allowlist
#          items) is strictly blocked and shielded from termination.
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
# full and sole responsibility for any data loss, terminated tasks, or system
# state modifications resulting from its execution.
# ==============================================================================

set -uo pipefail

ORIGINAL_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Default Configuration
DRY_RUN=false
FORCE=false
MODE="kill"              # "kill" (SIGTERM + SIGKILL) or "freeze" (SIGSTOP)
PURGE_AFTER=false
VERBOSE=false
GRACE_TIMEOUT=1.5
WHITELIST_FILE=""
TARGET_USER_ARG=""
ALL_USERS=false
CURRENT_USER=$(whoami)
CURRENT_UID=$(id -u)
CONSOLE_UID=$(stat -f '%u' /dev/console 2>/dev/null || echo "")
TARGET_UID="${SUDO_UID:-${CONSOLE_UID:-$CURRENT_UID}}"
TARGET_USER="${SUDO_USER:-$(id -nu "$TARGET_UID" 2>/dev/null || echo "$CURRENT_USER")}"

LOG_FILE="${FREE_MMM_LOG_FILE:-$SCRIPT_DIR/free_memory.log}"
ENABLE_LOGGING=true
if [[ "${FREE_MMM_NO_LOG:-0}" == "1" || "${FREE_MMM_NO_LOG:-}" == "true" ]]; then
  ENABLE_LOGGING=false
fi
START_EXECUTION_EPOCH=0

# ------------------------------------------------------------------------------
# Logging & Prompting Helpers
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
    end_epoch=$(date +%s 2>/dev/null || perl -e 'print time' 2>/dev/null || python3 -c 'import time; print(int(time.time()))' 2>/dev/null || echo 0)
    local duration=$(( end_epoch - START_EXECUTION_EPOCH ))
    if [[ $duration -lt 0 ]]; then duration=0; fi

    {
      echo "--------------------------------------------------------------------------------"
      echo "Finished Execution: $(date '+%Y-%m-%d %H:%M:%S %Z') | Duration: ${duration}s | Exit Code: $exit_code"
      echo "================================================================================"
      echo ""
    } >> "$LOG_FILE"
  fi

  exit "$exit_code"
}

# ------------------------------------------------------------------------------
# System Memory Helper
# ------------------------------------------------------------------------------
format_bytes() {
  local kb=$1
  if [[ -z "$kb" || "$kb" -lt 0 ]]; then
    echo "0 B"
    return
  fi
  if [[ $kb -ge 1048576 ]]; then
    awk "BEGIN {printf \"%.2f GB\", $kb / 1048576}"
  elif [[ $kb -ge 1024 ]]; then
    awk "BEGIN {printf \"%.1f MB\", $kb / 1024}"
  else
    echo "${kb} KB"
  fi
}

get_free_mem_percent() {
  local page_size free_pages speculative_pages total_ram_bytes free_ram_bytes free_pct
  page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/[^0-9]/,"",$3); print $3}')
  speculative_pages=$(vm_stat 2>/dev/null | awk '/Pages speculative/ {gsub(/[^0-9]/,"",$3); print $3}')
  total_ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)

  if [[ -n "$free_pages" && -n "$speculative_pages" && -n "$total_ram_bytes" && "$total_ram_bytes" -gt 0 ]]; then
    free_ram_bytes=$(( (free_pages + speculative_pages) * page_size ))
    free_pct=$(awk "BEGIN {printf \"%.1f%%\", ($free_ram_bytes / $total_ram_bytes) * 100}")
    echo "$free_pct"
  else
    echo "N/A"
  fi
}

matches_pattern() {
  local name="$1"
  local path="$2"
  local pattern="$3"

  # Exact name match
  if [[ "$name" == "$pattern" ]]; then
    return 0
  fi

  # Path wildcard or prefix match
  if [[ "$path" == $pattern ]]; then
    return 0
  fi

  # Substring or glob match on base name
  if [[ "$name" == $pattern ]]; then
    return 0
  fi

  return 1
}

# ------------------------------------------------------------------------------
# Built-In Critical System Invariants (Hardcoded Safety Net)
# ------------------------------------------------------------------------------
# Returns 0 (true) if the process base name is a non-negotiable system component
# that must NEVER be terminated or frozen.
is_critical_invariant() {
  case "$1" in
    # Core Darwin Mach Microkernel & Init
    kernel_task|launchd|diskarbitrationd|opendirectoryd|securityd|trustd|notifyd|\
    powerd|kernelmanagerd|amfid|syspolicyd|endpointsecurityd|aslmanager|deviceinterfaced|\
    fseventsd|logd|syslogd|autofsd|systemstats|thermalmonitord|watchdogd)
      return 0
      ;;

    # Quartz Display Compositor & Aqua Session
    WindowServer|loginwindow|runningboardd|WindowManager|SkyLight)
      return 0
      ;;

    # Essential Hardware, Audio & Networking
    coreaudiod|bluetoothd|wifid|configd|mDNSResponder|mDNSResponderHelper|usbd|driverkit|AudioComponentRegistrar)
      return 0
      ;;

    # Essential GUI Session Services & Clipboard (Cmd+C/Cmd+V, Preferences, TCC, LaunchServices, Fonts)
    pboard|cfprefsd|distnoted|lsd|tccd|secd|UserEventAgent|fontd|fontworker)
      return 0
      ;;

    # Core Desktop UI
    Finder|Dock|SystemUIServer|ControlCenter|NotificationCenter)
      return 0
      ;;

    # Active Terminals, Shells & Multiplexers
    Terminal|iTerm2|iTerm|alacritty|kitty|wezterm-gui|wezterm|warp|\
    bash|zsh|sh|fish|login|sshd|ssh|tmux|screen)
      return 0
      ;;

    # Standard CLI and Script Utilities
    ps|tee|sed|grep|awk|kill|killall|cat|sleep|sudo)
      return 0
      ;;

    *)
      return 1
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Help Documentation
# ------------------------------------------------------------------------------
show_help() {
  echo -e "================================================================================
         macOS User-App Isolation & Non-Essential Daemon Eliminator
                        kill_non_user_apps.sh
================================================================================
${BOLD}Usage:${NC} $0 [OPTIONS]

Iterates through ALL active processes on macOS and terminates (or freezes)
everything that is NOT a genuine user application. Essential system
infrastructure (kernel, WindowServer, audio, networking, security, login session,
terminals, IDEs, and allowlist items) is strictly blocked and shielded from termination.

${BOLD}OPTIONS:${NC}
  -d, --dry-run             Preview all processes (blocked, preserved, and targeted)
                            without killing anything.
  -f, --force               Skip interactive confirmation prompt.
  -m, --mode <kill|freeze>  Termination mode (default: kill):
                              kill   - Sends SIGTERM, waits grace timeout, then SIGKILL.
                              freeze - Sends SIGSTOP to pause background daemons
                                       without triggering launchd respawn.
  -z, --freeze              Shortcut for --mode freeze.
  -p, --purge               Purge inactive RAM and disk cache buffers after execution.
  -a, --all-users           Target non-app processes across all users (requires sudo).
  -u, --user <USERNAME>     Target non-app processes owned by a specific user.
  -w, --whitelist <FILE>    Path to process allowlist file (default: whitelist.txt).
  -t, --timeout <SEC>       Grace period in seconds between SIGTERM and SIGKILL (default: 1.5).
  -v, --verbose             Display comprehensive per-process details.
  -l, --log <FILE>          Path to execution log file (default: free_memory.log).
      --no-log              Disable file logging.
  -h, --help                Display this help documentation.

${BOLD}EXAMPLES:${NC}
  # Dry-run preview of what would be killed vs preserved
  ./kill_non_user_apps.sh --dry-run

  # Terminate all user-level non-app daemons
  ./kill_non_user_apps.sh

  # Terminate non-app background processes system-wide (requires sudo) and purge RAM
  sudo ./kill_non_user_apps.sh --all-users --force --purge

  # Freeze stubborn background daemons (SIGSTOP) so launchd will not respawn them
  sudo ./kill_non_user_apps.sh --all-users --mode freeze"
}

# ------------------------------------------------------------------------------
# Parse Command-Line Arguments
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
    -m|--mode)
      if [[ $# -lt 2 ]]; then
        echo -e "${RED}[ERROR] Option $1 requires an argument (kill or freeze).${NC}" >&2
        exit 1
      fi
      MODE=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      if [[ "$MODE" != "kill" && "$MODE" != "freeze" ]]; then
        echo -e "${RED}[ERROR] Invalid mode '$2'. Must be 'kill' or 'freeze'.${NC}" >&2
        exit 1
      fi
      shift 2
      ;;
    -z|--freeze)
      MODE="freeze"
      shift
      ;;
    -p|--purge)
      PURGE_AFTER=true
      shift
      ;;
    -a|--all-users)
      ALL_USERS=true
      shift
      ;;
    -u|--user)
      if [[ $# -lt 2 ]]; then
        echo -e "${RED}[ERROR] Option $1 requires a username argument.${NC}" >&2
        exit 1
      fi
      TARGET_USER_ARG="$2"
      shift 2
      ;;
    -w|--whitelist)
      if [[ $# -lt 2 ]]; then
        echo -e "${RED}[ERROR] Option $1 requires a file path argument.${NC}" >&2
        exit 1
      fi
      WHITELIST_FILE="$2"
      shift 2
      ;;
    -t|--timeout)
      if [[ $# -lt 2 ]]; then
        echo -e "${RED}[ERROR] Option $1 requires a timeout argument in seconds.${NC}" >&2
        exit 1
      fi
      GRACE_TIMEOUT="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -l|--log)
      if [[ $# -lt 2 ]]; then
        echo -e "${RED}[ERROR] Option $1 requires a log file path.${NC}" >&2
        exit 1
      fi
      LOG_FILE="$2"
      ENABLE_LOGGING=true
      shift 2
      ;;
    --no-log)
      ENABLE_LOGGING=false
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo -e "${RED}[ERROR] Unknown option: $1${NC}" >&2
      show_help
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# Initialize Execution Logging
# ------------------------------------------------------------------------------
if [[ "$ENABLE_LOGGING" == true && -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || ENABLE_LOGGING=false

  if [[ "$ENABLE_LOGGING" == true ]]; then
    exec 3>&1 4>&2
    START_EXECUTION_EPOCH=$(date +%s 2>/dev/null || perl -e 'print time' 2>/dev/null || python3 -c 'import time; print(int(time.time()))' 2>/dev/null || echo 0)

    {
      echo "================================================================================"
      echo "macOS User-App Isolation Execution Log"
      echo "Script:     kill_non_user_apps.sh"
      echo "Timestamp:  $(date '+%Y-%m-%d %H:%M:%S %Z')"
      echo "Command:    $0 ${ORIGINAL_ARGS[*]}"
      echo "User/UID:   $CURRENT_USER ($CURRENT_UID) | Target User: $TARGET_USER ($TARGET_UID)"
      echo "Mode:       $MODE | All Users: $ALL_USERS | Dry Run: $DRY_RUN"
      echo "--------------------------------------------------------------------------------"
    } >> "$LOG_FILE"

    exec > >(sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g' | tee -a "$LOG_FILE") 2>&1
    trap finalize_execution_logging EXIT
  fi
fi

# ------------------------------------------------------------------------------
# Banner & Scope Display
# ------------------------------------------------------------------------------
MODE_UPPER=$(echo "$MODE" | tr '[:lower:]' '[:upper:]')
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}${BOLD}       macOS User-App Isolation & Process Eliminator            ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "Invoked As:     ${BOLD}${CURRENT_USER}${NC} (UID: $CURRENT_UID)"

if [[ "$ALL_USERS" == true ]]; then
  if [[ "$CURRENT_UID" -ne 0 ]]; then
    echo -e "${YELLOW}[WARNING] --all-users requested without root privileges.${NC}"
    echo -e "${YELLOW}Non-root users can only terminate their own processes.${NC}"
  fi
  echo -e "Target Scope:   ${RED}${BOLD}System-wide (All Users / Daemons)${NC}"
elif [[ -n "$TARGET_USER_ARG" ]]; then
  echo -e "Target Scope:   User: ${BOLD}${TARGET_USER_ARG}${NC}"
else
  echo -e "Target Scope:   Desktop User: ${BOLD}${TARGET_USER}${NC} (UID: $TARGET_UID)"
fi

echo -e "Action Mode:    ${BOLD}${MODE_UPPER}${NC} $([[ "$MODE" == "freeze" ]] && echo "[SIGSTOP Pause]" || echo "[SIGTERM + SIGKILL]")"
if [[ "$DRY_RUN" == true ]]; then
  echo -e "Execution Mode: ${MAGENTA}${BOLD}[DRY-RUN / PREVIEW ONLY - NO PROCESSES TERMINATED]${NC}"
else
  echo -e "Execution Mode: ${RED}${BOLD}[LIVE EXECUTION]${NC}"
fi

# ------------------------------------------------------------------------------
# Resolve Allowlist / Whitelist
# ------------------------------------------------------------------------------
if [[ -z "$WHITELIST_FILE" ]]; then
  if [[ -f "$SCRIPT_DIR/whitelist.txt" ]]; then
    WHITELIST_FILE="$SCRIPT_DIR/whitelist.txt"
  elif [[ -f "whitelist.txt" ]]; then
    WHITELIST_FILE="whitelist.txt"
  fi
fi

declare -a WHITELIST_PATTERNS=()
if [[ -n "$WHITELIST_FILE" && -f "$WHITELIST_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    clean_line=$(echo "$line" | sed 's/#.*//' | tr -d '\r' | xargs)
    [[ -z "$clean_line" ]] && continue
    # Exclude broad directory wildcards that would blanket-protect all background daemons
    if [[ "$clean_line" == "/System/Library/*" || "$clean_line" == "/System/Applications/*" || \
          "$clean_line" == "/usr/libexec/*" || "$clean_line" == "/usr/sbin/*" ]]; then
      continue
    fi
    WHITELIST_PATTERNS+=("$clean_line")
  done < "$WHITELIST_FILE"
  echo -e "Allowlist:      ${GREEN}${WHITELIST_FILE}${NC} (${#WHITELIST_PATTERNS[@]} rules loaded)"
else
  echo -e "Allowlist:      ${YELLOW}None (Using built-in system safety invariants)${NC}"
fi

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

INITIAL_FREE_PCT=$(get_free_mem_percent)
echo -e "Initial Free Memory: ${GREEN}${INITIAL_FREE_PCT}${NC}"
echo -e "${CYAN}----------------------------------------------------------------${NC}"
echo -e "Scanning and classifying all active system processes..."

# ------------------------------------------------------------------------------
# Process Table Scanning & Classification
# ------------------------------------------------------------------------------
declare -a RAW_PIDS=()
declare -a RAW_PPIDS=()
declare -a RAW_UIDS=()
declare -a RAW_TTYS=()
declare -a RAW_RSS=()
declare -a RAW_STATS=()
declare -a RAW_COMMS=()
declare -a RAW_BASES=()

USER_APP_ROOT_PIDS=" "
APP_DESCENDANT_PIDS=" "

# First Pass: Read all active processes into indexed arrays
while IFS=" " read -r pid ppid p_uid p_tty rss stat comm; do
  [[ -z "$pid" || "$pid" == "PID" ]] && continue
  
  clean_comm="${comm#-}"
  base_name="${clean_comm##*/}"

  RAW_PIDS+=("$pid")
  RAW_PPIDS+=("$ppid")
  RAW_UIDS+=("$p_uid")
  RAW_TTYS+=("$p_tty")
  RAW_RSS+=("$rss")
  RAW_STATS+=("$stat")
  RAW_COMMS+=("$comm")
  RAW_BASES+=("$base_name")

  # Identify User Application bundle roots:
  # Must be located in standard Application directories
  # AND must NOT be a widget extension (*.appex)
  if [[ "$comm" != *".appex/"* ]]; then
    if [[ "$comm" == "/Applications/"* || \
          "$comm" == "/System/Applications/"* || \
          "$comm" == "/System/Volumes/Preboot/Cryptexes/App/System/Applications/"* || \
          "$comm" == "/Users/"*"/Applications/"* ]]; then
      if [[ "$comm" == *".app/"* || "$comm" == *".app" ]]; then
        USER_APP_ROOT_PIDS="${USER_APP_ROOT_PIDS}${pid} "
      fi
    fi
  fi
done < <(ps -eo pid=,ppid=,uid=,tty=,rss=,stat=,comm=)

TOTAL_PROCS=${#RAW_PIDS[@]}

# Second Pass: Identify all child and descendant processes belonging to User Apps
# (e.g. Electron Helpers, Chrome Renderer/GPU processes, Language Servers)
# Iteratively trace descendants until no new children are added.
has_new_descendants=1
while [[ $has_new_descendants -eq 1 ]]; do
  has_new_descendants=0
  for ((j = 0; j < TOTAL_PROCS; j++)); do
    c_pid="${RAW_PIDS[$j]}"
    c_ppid="${RAW_PPIDS[$j]}"
    if [[ "$USER_APP_ROOT_PIDS" == *" $c_ppid "* || "$APP_DESCENDANT_PIDS" == *" $c_ppid "* ]]; then
      if [[ "$APP_DESCENDANT_PIDS" != *" $c_pid "* && "$USER_APP_ROOT_PIDS" != *" $c_pid "* ]]; then
        APP_DESCENDANT_PIDS="${APP_DESCENDANT_PIDS}${c_pid} "
        has_new_descendants=1
      fi
    fi
  done
done

# Third Pass: Classify each process into BLOCKED, USER_APP, or TARGET
declare -a BLOCKED_PIDS=()
declare -a BLOCKED_NAMES=()
declare -a BLOCKED_REASONS=()
declare -a BLOCKED_RSS=()
BLOCKED_TOTAL_KB=0

declare -a APP_PIDS=()
declare -a APP_NAMES=()
declare -a APP_PATHS=()
declare -a APP_RSS=()
APP_TOTAL_KB=0

declare -a TARGET_PIDS=()
declare -a TARGET_NAMES=()
declare -a TARGET_USERS=()
declare -a TARGET_REASONS=()
declare -a TARGET_RSS=()
declare -a TARGET_IS_FROZEN=()
TARGET_TOTAL_KB=0
ALREADY_PAUSED_COUNT=0
ALREADY_PAUSED_KB=0

for ((i = 0; i < TOTAL_PROCS; i++)); do
  pid="${RAW_PIDS[$i]}"
  ppid="${RAW_PPIDS[$i]}"
  p_uid="${RAW_UIDS[$i]}"
  p_tty="${RAW_TTYS[$i]}"
  rss="${RAW_RSS[$i]}"
  stat="${RAW_STATS[$i]}"
  comm="${RAW_COMMS[$i]}"
  base="${RAW_BASES[$i]}"

  is_frozen=0
  if [[ "$stat" == T* ]]; then
    is_frozen=1
  fi

  # ----------------------------------------------------------------------------
  # CATEGORY 1: BLOCKED (Important System Invariants, TTYs, & Allowlist)
  # ----------------------------------------------------------------------------
  block_reason=""

  # 1.1 Self, Script Children, and Ancestor Chain Shield
  if [[ " $PROTECTED_PIDS " == *" $pid "* ]]; then
    block_reason="Ancestor / Calling Session"
  elif [[ "$ppid" -eq $$ ]]; then
    block_reason="Script Helper"
  # 1.2 Critical Hardcoded System Invariants
  elif is_critical_invariant "$base"; then
    block_reason="Critical System Invariant"
  # 1.3 Active Interactive Terminal Sessions (controlling TTY attached)
  elif [[ "$p_tty" != "??" && "$p_tty" != "-" && ("$p_tty" == ttys* || "$p_tty" == "console") ]]; then
    block_reason="Active Terminal Session ($p_tty)"
  fi

  # 1.4 Allowlist / Whitelist Pattern Matching
  if [[ -z "$block_reason" && ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
    for wpat in "${WHITELIST_PATTERNS[@]}"; do
      if matches_pattern "$base" "$comm" "$wpat"; then
        block_reason="Allowlist Rule ($wpat)"
        break
      fi
    done
  fi

  if [[ -n "$block_reason" ]]; then
    BLOCKED_PIDS+=("$pid")
    BLOCKED_NAMES+=("$base")
    BLOCKED_REASONS+=("$block_reason")
    BLOCKED_RSS+=("$rss")
    BLOCKED_TOTAL_KB=$(( BLOCKED_TOTAL_KB + rss ))
    continue
  fi

  # ----------------------------------------------------------------------------
  # CATEGORY 2: USER APPLICATION (Preserved)
  # ----------------------------------------------------------------------------
  if [[ "$USER_APP_ROOT_PIDS" == *" $pid "* ]]; then
    APP_PIDS+=("$pid")
    APP_NAMES+=("$base")
    APP_PATHS+=("$comm")
    APP_RSS+=("$rss")
    APP_TOTAL_KB=$(( APP_TOTAL_KB + rss ))
    continue
  fi

  if [[ "$APP_DESCENDANT_PIDS" == *" $pid "* ]]; then
    APP_PIDS+=("$pid")
    APP_NAMES+=("$base (Helper)")
    APP_PATHS+=("$comm")
    APP_RSS+=("$rss")
    APP_TOTAL_KB=$(( APP_TOTAL_KB + rss ))
    continue
  fi

  # ----------------------------------------------------------------------------
  # CATEGORY 3: TARGET FOR TERMINATION (Non-App Background Daemons)
  # ----------------------------------------------------------------------------
  # Check User Filter Scope
  user_name=$(id -nu "$p_uid" 2>/dev/null || echo "$p_uid")

  if [[ "$ALL_USERS" != true ]]; then
    if [[ -n "$TARGET_USER_ARG" ]]; then
      if [[ "$user_name" != "$TARGET_USER_ARG" && "$p_uid" != "$TARGET_USER_ARG" ]]; then
        continue
      fi
    else
      # Default: target desktop user processes (or current user)
      if [[ "$p_uid" -ne "$TARGET_UID" && "$p_uid" -ne "$CURRENT_UID" && "$CURRENT_UID" -ne 0 ]]; then
        continue
      fi
    fi
  fi

  # Determine target reason
  target_reason=""
  if [[ "$comm" == *".appex/"* ]]; then
    target_reason="Widget / Background Extension"
  elif [[ "$comm" == "/System/Library/"* ]]; then
    target_reason="System Framework Daemon"
  elif [[ "$comm" == "/usr/libexec/"* ]]; then
    target_reason="System Helper Daemon"
  elif [[ "$comm" == "/usr/sbin/"* ]]; then
    target_reason="System Service"
  else
    target_reason="Non-App Background Process"
  fi

  if [[ $is_frozen -eq 1 ]]; then
    ALREADY_PAUSED_COUNT=$(( ALREADY_PAUSED_COUNT + 1 ))
    ALREADY_PAUSED_KB=$(( ALREADY_PAUSED_KB + rss ))
    if [[ "$MODE" == "freeze" ]]; then
      target_reason="${target_reason} [ALREADY PAUSED]"
    fi
  fi

  TARGET_PIDS+=("$pid")
  TARGET_NAMES+=("$base")
  TARGET_USERS+=("$user_name")
  TARGET_REASONS+=("$target_reason")
  TARGET_RSS+=("$rss")
  TARGET_IS_FROZEN+=("$is_frozen")
  TARGET_TOTAL_KB=$(( TARGET_TOTAL_KB + rss ))

done

NUM_BLOCKED=${#BLOCKED_PIDS[@]}
NUM_APPS=${#APP_PIDS[@]}
NUM_TARGETS=${#TARGET_PIDS[@]}

BLOCKED_STR=$(format_bytes "$BLOCKED_TOTAL_KB")
APP_STR=$(format_bytes "$APP_TOTAL_KB")
TARGET_STR=$(format_bytes "$TARGET_TOTAL_KB")

# ------------------------------------------------------------------------------
# Print Classification Summary
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}Classification Results across $TOTAL_PROCS running processes:${NC}"
echo -e "  1. ${GREEN}${BOLD}Important / Blocked Infrastructure:${NC}   $NUM_BLOCKED processes  (~${BLOCKED_STR} protected)"
echo -e "  2. ${CYAN}${BOLD}Preserved User Applications:${NC}          $NUM_APPS processes  (~${APP_STR} preserved)"
echo -e "  3. ${RED}${BOLD}Targeted Non-App Background Daemons:${NC}  $NUM_TARGETS processes  (~${TARGET_STR} reclaimable)"

if [[ $ALREADY_PAUSED_COUNT -gt 0 ]]; then
  PAUSED_STR=$(format_bytes "$ALREADY_PAUSED_KB")
  echo -e "     ${CYAN}>>> ($ALREADY_PAUSED_COUNT of these are already paused in state T, ~$PAUSED_STR held/compressed)${NC}"
fi

# Print User Applications Breakdown
echo -e "\n${CYAN}${BOLD}=== Preserved User Applications ($NUM_APPS processes) ===${NC}"
printf "${BOLD}%-7s %-25s %-12s %-45s${NC}\n" "PID" "APPLICATION" "MEMORY" "EXECUTABLE PATH"
printf "%-7s %-25s %-12s %-45s\n" "-------" "-------------------------" "------------" "---------------------------------------------"

for ((i = 0; i < NUM_APPS; i++)); do
  pid="${APP_PIDS[$i]}"
  name="${APP_NAMES[$i]}"
  path="${APP_PATHS[$i]}"
  rss="${APP_RSS[$i]}"
  mem_str=$(format_bytes "$rss")
  printf "%-7s %-25s %-12s %-45s\n" "$pid" "${name:0:25}" "$mem_str" "${path:0:45}"
done

# If verbose, display blocked processes
if [[ "$VERBOSE" == true ]]; then
  echo -e "\n${GREEN}${BOLD}=== Blocked System Invariants & Whitelist ($NUM_BLOCKED processes) ===${NC}"
  printf "${BOLD}%-7s %-25s %-12s %-35s${NC}\n" "PID" "PROCESS" "MEMORY" "PROTECTION REASON"
  printf "%-7s %-25s %-12s %-35s\n" "-------" "-------------------------" "------------" "-----------------------------------"
  for ((i = 0; i < NUM_BLOCKED; i++)); do
    pid="${BLOCKED_PIDS[$i]}"
    name="${BLOCKED_NAMES[$i]}"
    reason="${BLOCKED_REASONS[$i]}"
    rss="${BLOCKED_RSS[$i]}"
    mem_str=$(format_bytes "$rss")
    printf "%-7s %-25s %-12s %-35s\n" "$pid" "${name:0:25}" "$mem_str" "${reason:0:35}"
  done
fi

# Print Targeted Non-App Daemons
if [[ $NUM_TARGETS -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}=== Targeted Non-App Daemons to $([[ "$MODE" == "freeze" ]] && echo "Freeze" || echo "Terminate") ($NUM_TARGETS processes, ~$TARGET_STR) ===${NC}"
  printf "${BOLD}%-7s %-10s %-12s %-32s %-25s${NC}\n" "PID" "USER" "MEMORY" "CLASSIFICATION" "COMMAND"
  printf "%-7s %-10s %-12s %-32s %-25s\n" "-------" "----------" "------------" "--------------------------------" "-------------------------"

  # Display up to 50 items or all if verbose
  display_limit=$NUM_TARGETS
  if [[ "$VERBOSE" != true && $NUM_TARGETS -gt 60 ]]; then
    display_limit=50
  fi

  for ((i = 0; i < display_limit; i++)); do
    pid="${TARGET_PIDS[$i]}"
    user="${TARGET_USERS[$i]}"
    rss="${TARGET_RSS[$i]}"
    name="${TARGET_NAMES[$i]}"
    reason="${TARGET_REASONS[$i]}"
    mem_str=$(format_bytes "$rss")
    printf "%-7s %-10s %-12s %-32s %-25s\n" "$pid" "$user" "$mem_str" "${reason:0:32}" "${name:0:25}"
  done

  if [[ $display_limit -lt $NUM_TARGETS ]]; then
    remaining=$(( NUM_TARGETS - display_limit ))
    echo -e "${YELLOW}... and $remaining more background daemon(s). (Use -v or --verbose to view all).${NC}"
  fi
fi

# ------------------------------------------------------------------------------
# Check for Zero Targets
# ------------------------------------------------------------------------------
if [[ $NUM_TARGETS -eq 0 ]]; then
  echo -e "\n${GREEN}${BOLD}[CLEAN] No non-app background processes found matching criteria.${NC}"
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

# ------------------------------------------------------------------------------
# Dry-Run Exit
# ------------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  echo -e "\n${MAGENTA}${BOLD}[DRY-RUN COMPLETE]${NC} Evaluated $NUM_TARGETS target processes (~$TARGET_STR reclaimable)."
  echo -e "No processes were terminated or modified. Run without ${BOLD}--dry-run${NC} to execute."
  exit 0
fi

# ------------------------------------------------------------------------------
# Interactive Risk Warning & Confirmation Prompt
# ------------------------------------------------------------------------------
if [[ "$FORCE" != true ]]; then
  echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║                       CRITICAL WARNING & RISK NOTICE                         ║${NC}"
  echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${RED}║ You are about to aggressively $([[ "$MODE" == "freeze" ]] && echo "freeze" || echo "terminate") ${BOLD}$NUM_TARGETS non-app background process(es)${RED}:  ║${NC}"
  echo -e "${RED}║   1. ACTION TYPE:                                                            ║${NC}"
  if [[ "$MODE" == "freeze" ]]; then
    echo -e "${RED}║      Daemons will receive ${BOLD}SIGSTOP${RED} (paused at 0% CPU; memory can page out).   ║${NC}"
    echo -e "${RED}║      Launchd will not restart them. Run unfreeze_daemons.sh to restore.      ║${NC}"
  else
    echo -e "${RED}║      Daemons will receive ${BOLD}SIGTERM${RED} followed by ${BOLD}SIGKILL${RED}.                          ║${NC}"
    echo -e "${RED}║      Background tasks, sync helpers, and workers will exit immediately.      ║${NC}"
  fi
  echo -e "${RED}║   2. PRESERVED COMPONENTS:                                                   ║${NC}"
  echo -e "${RED}║      Your open GUI apps (${CYAN}${NUM_APPS} apps${RED}) and system infrastructure are immune.  ║${NC}"
  echo -e "${RED}║                                                                              ║${NC}"
  echo -e "${RED}║ USER RESPONSIBILITY NOTICE (NO WARRANTY):                                    ║${NC}"
  echo -e "${RED}║ By using this software, you accept full and sole responsibility for all      ║${NC}"
  echo -e "${RED}║ system state changes, interrupted background tasks, or data modifications.   ║${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"

  echo ""
  confirm=$(prompt_confirmation "$(echo -e "${RED}${BOLD}[PROMPT] Do you want to proceed and $([[ "$MODE" == "freeze" ]] && echo "freeze" || echo "kill") these $NUM_TARGETS process(es)? [y/N]: ${NC}")")
  if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
    echo -e "\n${YELLOW}[CANCELLED] Operation aborted by user. No processes were modified.${NC}"
    exit 0
  fi
fi

# ------------------------------------------------------------------------------
# Execute Termination / Freezing
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}>>> Executing $MODE action on $NUM_TARGETS target process(es)...${NC}"

SUCCESS_COUNT=0
SIP_COUNT=0
FAIL_COUNT=0

if [[ "$MODE" == "freeze" ]]; then
  # ----------------------------------------------------------------------------
  # FREEZE MODE (SIGSTOP)
  # ----------------------------------------------------------------------------
  for ((i = 0; i < NUM_TARGETS; i++)); do
    pid="${TARGET_PIDS[$i]}"
    name="${TARGET_NAMES[$i]}"
    is_frz="${TARGET_IS_FROZEN[$i]}"

    if [[ "$is_frz" -eq 1 ]]; then
      SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
      continue
    fi

    if kill -0 "$pid" 2>/dev/null; then
      freeze_err=$(kill -STOP "$pid" 2>&1 || true)
      if [[ -z "$freeze_err" ]]; then
        SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
        if [[ "$VERBOSE" == true ]]; then
          echo -e "  ${GREEN}[FROZEN]${NC} PID $pid ($name) paused via SIGSTOP."
        fi
      elif [[ "$freeze_err" == *"Operation not permitted"* ]]; then
        SIP_COUNT=$(( SIP_COUNT + 1 ))
        if [[ "$VERBOSE" == true ]]; then
          echo -e "  ${YELLOW}[PROTECTED BY SIP]${NC} PID $pid ($name) could not be paused."
        fi
      else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        if [[ "$VERBOSE" == true ]]; then
          echo -e "  ${RED}[FAILED]${NC} PID $pid ($name): $freeze_err"
        fi
      fi
    fi
  done

else
  # ----------------------------------------------------------------------------
  # KILL MODE (SIGTERM -> GRACE TIMEOUT -> SIGKILL)
  # ----------------------------------------------------------------------------
  declare -a PIDS_TO_SIGKILL=()
  declare -a NAMES_TO_SIGKILL=()

  # Phase 1: Graceful SIGTERM
  for ((i = 0; i < NUM_TARGETS; i++)); do
    pid="${TARGET_PIDS[$i]}"
    name="${TARGET_NAMES[$i]}"

    if kill -0 "$pid" 2>/dev/null; then
      term_err=$(kill -15 "$pid" 2>&1 || true)
      if [[ -n "$term_err" && "$term_err" == *"Operation not permitted"* ]]; then
        SIP_COUNT=$(( SIP_COUNT + 1 ))
        if [[ "$VERBOSE" == true ]]; then
          echo -e "  ${YELLOW}[PROTECTED BY SIP]${NC} PID $pid ($name) cannot be signalled."
        fi
      else
        PIDS_TO_SIGKILL+=("$pid")
        NAMES_TO_SIGKILL+=("$name")
      fi
    fi
  done

  # Phase 2: Await grace period
  if [[ ${#PIDS_TO_SIGKILL[@]} -gt 0 ]]; then
    sleep "$GRACE_TIMEOUT"

    # Phase 3: Forceful SIGKILL for stubborn processes
    for ((k = 0; k < ${#PIDS_TO_SIGKILL[@]}; k++)); do
      pid="${PIDS_TO_SIGKILL[$k]}"
      name="${NAMES_TO_SIGKILL[$k]}"

      if kill -0 "$pid" 2>/dev/null; then
        kill_err=$(kill -9 "$pid" 2>&1 || true)
        if [[ -z "$kill_err" ]]; then
          SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
          if [[ "$VERBOSE" == true ]]; then
            echo -e "  ${GREEN}[KILLED -9]${NC} PID $pid ($name) forcefully terminated."
          fi
        elif [[ "$kill_err" == *"No such process"* ]]; then
          SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
        else
          FAIL_COUNT=$(( FAIL_COUNT + 1 ))
          if [[ "$VERBOSE" == true ]]; then
            echo -e "  ${RED}[FAILED -9]${NC} PID $pid ($name): $kill_err"
          fi
        fi
      else
        SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
        if [[ "$VERBOSE" == true ]]; then
          echo -e "  ${GREEN}[TERMINATED]${NC} PID $pid ($name) exited gracefully."
        fi
      fi
    done
  fi
fi

# ------------------------------------------------------------------------------
# Cache Purge (Optional)
# ------------------------------------------------------------------------------
if [[ "$PURGE_AFTER" == true ]]; then
  echo -e "\n${CYAN}>>> Purging inactive memory and disk cache buffers...${NC}"
  if sudo -n true 2>/dev/null; then
    sudo purge 2>/dev/null && echo -e "${GREEN}Cache purged successfully.${NC}" || echo -e "${YELLOW}Could not run purge command.${NC}"
  else
    purge 2>/dev/null && echo -e "${GREEN}Cache purged successfully.${NC}" || echo -e "${YELLOW}Could not run purge command.${NC}"
  fi
fi

# ------------------------------------------------------------------------------
# Final Execution Statistics
# ------------------------------------------------------------------------------
FINAL_FREE_PCT=$(get_free_mem_percent)
echo -e "\n${CYAN}================================================================${NC}"
echo -e "${GREEN}${BOLD}                   Execution Complete                           ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "Mode:                       ${BOLD}${MODE_UPPER}${NC}"
echo -e "Target Processes Evaluated: ${BOLD}$NUM_TARGETS${NC}"
echo -e "Successfully Processed:     ${GREEN}${BOLD}$SUCCESS_COUNT${NC}"
if [[ $SIP_COUNT -gt 0 ]]; then
  echo -e "Protected by macOS SIP:     ${YELLOW}${BOLD}$SIP_COUNT${NC} (Apple system protected)"
fi
if [[ $FAIL_COUNT -gt 0 ]]; then
  echo -e "Permission / Signal Errors: ${RED}${BOLD}$FAIL_COUNT${NC} (Run with sudo for system daemons)"
fi
echo -e "User Applications Kept:     ${CYAN}${BOLD}$NUM_APPS${NC}"
echo -e "System Invariants Blocked:  ${GREEN}${BOLD}$NUM_BLOCKED${NC}"
echo -e "Initial Free Memory:        $INITIAL_FREE_PCT"
echo -e "Final Free Memory:          ${GREEN}${BOLD}$FINAL_FREE_PCT${NC}"
echo -e "${CYAN}================================================================${NC}"

exit 0
