#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# run_auction.sh — compile, generate inputs, and run a dark-auction program
#                  across one or more MP-SPDZ protocols.
#
# Usage:
#   ./scripts/run_auction.sh                          # defaults
#   ./scripts/run_auction.sh dark-auction-sfix         # sfix variant
#   ./scripts/run_auction.sh dark-auction mascot shamir semi  # specific protocols
#
# The script:
#   1. Brings Docker containers up (builds if needed).
#   2. Compiles the .mpc program inside party0.
#   3. Generates deterministic input files (or uses existing ones).
#   4. Runs all 3 parties in parallel for each requested protocol.
#   5. Prints per-protocol wall-clock time for comparison.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

prog="${1:-dark-auction}"
shift 2>/dev/null || true                    # remaining args are protocols
protocols=("${@:-mascot}")
if [ "${#protocols[@]}" -eq 0 ]; then
  protocols=(mascot)
fi

nparties=3
root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

# ── Derived binary names ──────────────────────────────────────────────
declare -A proto_bin=(
  [mascot]=mascot-party.x
  [shamir]=shamir-party.x
  [semi]=semi-party.x
  [rep-ring]=replicated-ring-party.x
)

# ── Setup ─────────────────────────────────────────────────────────────
mkdir -p Config Inputs

cat > Config/IPs <<'EOF'
party0
party1
party2
EOF

# ── Generate inputs if they are stale / missing ──────────────────────
# Each party submits N_ORDERS=2 orders × 3 assets × 4 values = 24 ints
# (or for sfix: prices as floats, quantities as ints)
if [ ! -f Inputs/.generated ] || [ "$prog" != "$(cat Inputs/.generated 2>/dev/null)" ]; then
  echo "Generating sample inputs for $prog ..."
  python3 scripts/generate_inputs.py "$prog"
  echo "$prog" > Inputs/.generated
fi

# ── Bring containers up ──────────────────────────────────────────────
echo "==> Starting containers ..."
docker compose up -d --build party0 party1 party2

# ── Compile ───────────────────────────────────────────────────────────
echo "==> Compiling $prog.mpc ..."
docker compose exec -T party0 bash -lc "
  set -euo pipefail
  mkdir -p /mp-spdz/Programs/Source
  cp -f /workspace/${prog}.mpc /mp-spdz/Programs/Source/${prog}.mpc
  cd /mp-spdz
  python3 ./compile.py $prog
"

# ── Helper: kill stale party processes ────────────────────────────────
cleanup_parties() {
  for c in party0 party1 party2; do
    docker compose exec -T "$c" bash -c \
      "killall -q mascot-party.x shamir-party.x semi-party.x replicated-ring-party.x 2>/dev/null || true" 2>/dev/null
  done
  sleep 1
}

# ── Run each protocol ────────────────────────────────────────────────
for proto in "${protocols[@]}"; do
  cleanup_parties
  bin="${proto_bin[$proto]:-${proto}-party.x}"
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Protocol: $proto  ($bin)"
  echo "╚══════════════════════════════════════════════════════════════╝"

  start_ts=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")

  set +e
  docker compose exec -T party0 bash -lc \
    "cd /mp-spdz && ./$bin -N $nparties -p 0 -ip Config/IPs -IF Inputs/Input -v $prog" &
  p0=$!
  docker compose exec -T party1 bash -lc \
    "cd /mp-spdz && ./$bin -N $nparties -p 1 -ip Config/IPs -IF Inputs/Input -v $prog" &
  p1=$!
  docker compose exec -T party2 bash -lc \
    "cd /mp-spdz && ./$bin -N $nparties -p 2 -ip Config/IPs -IF Inputs/Input -v $prog" &
  p2=$!

  wait "$p0"; s0=$?
  wait "$p1"; s1=$?
  wait "$p2"; s2=$?
  set -e

  end_ts=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")
  elapsed=$(( end_ts - start_ts ))

  if [ "$s0" -ne 0 ] || [ "$s1" -ne 0 ] || [ "$s2" -ne 0 ]; then
    echo "  ✗ FAILED — exit codes: party0=$s0 party1=$s1 party2=$s2"
  else
    echo "  ✓ OK — wall-clock ${elapsed} ms"
  fi
done

echo ""
echo "Done."
