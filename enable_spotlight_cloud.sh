#!/usr/bin/env bash
# ==============================================================================
# Script: enable_spotlight_cloud.sh
# Purpose: Companion script to re-enable and restore macOS Spotlight file indexing,
#          all cloud accounts, and fileproviderd back to default settings.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/disable_spotlight_cloud.sh" --enable "$@"
