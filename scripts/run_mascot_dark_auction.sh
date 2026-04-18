#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# run_mascot_dark_auction.sh — legacy convenience wrapper
#
# Now delegates to run_auction.sh with mascot protocol.
# For multi-protocol runs, use ./scripts/run_auction.sh directly.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

prog="${1:-dark-auction}"
root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

exec "$root_dir/scripts/run_auction.sh" "$prog" mascot
