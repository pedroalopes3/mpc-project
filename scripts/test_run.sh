#!/usr/bin/env bash
# Quick test run — executes all 3 parties in parallel, captures each
# party's output in a separate log file, then displays them with headers
# so that print_ln_to(pid, ...) lines are never lost.
set -euo pipefail
cd "$(dirname "$0")/.."

prog="${1:-dark-auction}"
nparties=3

# ── Cleanup stale processes ─────────────────────────────────────────────
for c in party0 party1 party2; do
  docker compose exec -T "$c" bash -c \
    "killall -q mascot-party.x shamir-party.x semi-party.x replicated-ring-party.x 2>/dev/null || true" \
    2>/dev/null
done
sleep 1

# ── Compile (ensures we run the latest .mpc source) ─────────────────────
echo "==> Compiling $prog.mpc ..."
docker compose exec -T party0 bash -lc "
  set -euo pipefail
  mkdir -p /mp-spdz/Programs/Source
  cp -f /workspace/${prog}.mpc /mp-spdz/Programs/Source/${prog}.mpc
  cd /mp-spdz && python3 ./compile.py $prog
"

# ── Temp dir for per-party logs ──────────────────────────────────────────
logdir=$(mktemp -d)
trap 'rm -rf "$logdir"' EXIT

echo "==> Running $prog on mascot ..."
start_ts=$(python3 -c "import time; print(int(time.time()*1000))")

# Party 0 uses `tee` so its output streams live to the terminal AND to
# the log file.  Party 0 carries all the public print_ln() messages
# (clearing prices, "=== Auction for ... ===" headers), so you can
# follow progress in real time.  Parties 1 & 2 go silently to files —
# their private print_ln_to() results are shown at the end.
docker compose exec -T party0 bash -lc \
  "cd /mp-spdz && ./mascot-party.x -N $nparties -p 0 -ip Config/IPs -IF Inputs/Input $prog" \
  2>&1 | tee "$logdir/party0.log" &
p0=$!

docker compose exec -T party1 bash -lc \
  "cd /mp-spdz && ./mascot-party.x -N $nparties -p 1 -ip Config/IPs -IF Inputs/Input $prog" \
  > "$logdir/party1.log" 2>&1 &
p1=$!

docker compose exec -T party2 bash -lc \
  "cd /mp-spdz && ./mascot-party.x -N $nparties -p 2 -ip Config/IPs -IF Inputs/Input $prog" \
  > "$logdir/party2.log" 2>&1 &
p2=$!

# Wait for all three
wait "$p0"; s0=$?
wait "$p1"; s1=$?
wait "$p2"; s2=$?

end_ts=$(python3 -c "import time; print(int(time.time()*1000))")
elapsed=$(( end_ts - start_ts ))

# ── Display each party's output with clear section headers ───────────────
echo ""
echo "════════════════════════════════════════════════════════════"
for i in 0 1 2; do
  echo "──── Party $i output ────"
  cat "$logdir/party${i}.log"
  echo ""
done
echo "════════════════════════════════════════════════════════════"
echo "Exit codes: party0=$s0  party1=$s1  party2=$s2"
echo "Wall-clock: ${elapsed} ms"
