#!/usr/bin/env bash
# Quick test run — executes all 3 parties in parallel, captures each
# party's output in a separate log file, then displays them with headers.
#
# Usage:
#   bash scripts/test_run.sh <program> [protocol]
#
# protocol options: mascot (default), shamir, semi, replicated-ring
#
# Example:
#   bash scripts/test_run.sh auction_improved shamir
#   bash scripts/test_run.sh auction replicated-ring

set -euo pipefail
cd "$(dirname "$0")/.."

prog="${1:-dark-auction}"
protocol="${2:-mascot}"
nparties=3

# ── Map protocol name to binary, -N flag, and compile flags ─────────────
#
#   replicated-ring-party.x operates over Z_{2^k} (a ring mod a power of
#   two), NOT over a prime field. Compiling without -R produces bytecode
#   for a prime field, which the ring binary rejects at startup with:
#     "Program was compiled for a prime field, not a ring modulo a power
#      of two. Use './compile.py -R <size>'."
#   Solution: pass -R 64 to compile.py when the target protocol is
#   replicated-ring. All other protocols use the default prime field.
#
#   replicated-ring is also hardcoded for exactly 3 parties and does NOT
#   accept the -N flag that the other binaries require.
#
case "$protocol" in
  mascot)
    binary="mascot-party.x"
    use_N=true
    compile_flags=""
    ;;
  shamir)
    binary="shamir-party.x"
    use_N=true
    compile_flags=""
    ;;
  semi)
    binary="semi-party.x"
    use_N=true
    compile_flags=""
    ;;
  replicated-ring)
    binary="replicated-ring-party.x"
    use_N=false        # hardcoded 3-party protocol — does NOT accept -N
    compile_flags="-R 64"   # compile for Z_{2^64} ring, not prime field
    ;;
  *)
    echo "ERROR: unknown protocol '$protocol'"
    echo "Choose from: mascot, shamir, semi, replicated-ring"
    exit 1
    ;;
esac

if $use_N; then
  N_FLAG="-N $nparties"
else
  N_FLAG=""
fi

# ── Cleanup stale processes ──────────────────────────────────────────────
# Kill by binary name AND by port. fuser -k releases the socket
# immediately so the new run can bind without "Address already in use".
for c in party0 party1 party2; do
  docker compose exec -T "$c" bash -c "
    killall -q -9 mascot-party.x shamir-party.x semi-party.x replicated-ring-party.x 2>/dev/null || true
    fuser -k 5000/tcp 5001/tcp 5002/tcp 2>/dev/null || true
  " 2>/dev/null || true
done
sleep 3

# ── Compile ──────────────────────────────────────────────────────────────
echo "==> Compiling $prog.mpc (flags: ${compile_flags:-none}) ..."
docker compose exec -T party0 bash -lc "
  set -euo pipefail
  mkdir -p /mp-spdz/Programs/Source
  cp -f /workspace/${prog}.mpc /mp-spdz/Programs/Source/${prog}.mpc
  cd /mp-spdz && python3 ./compile.py $compile_flags $prog
"

# ── Temp dir for per-party logs ──────────────────────────────────────────
logdir=$(mktemp -d)
trap 'rm -rf "$logdir"' EXIT

echo "==> Running $prog on $protocol ($binary) ..."
start_ts=$(python3 -c "import time; print(int(time.time()*1000))")

docker compose exec -T party0 bash -lc \
  "cd /mp-spdz && ./$binary $N_FLAG -p 0 -ip Config/IPs -IF Inputs/Input $prog" \
  2>&1 | tee "$logdir/party0.log" &
p0=$!

docker compose exec -T party1 bash -lc \
  "cd /mp-spdz && ./$binary $N_FLAG -p 1 -ip Config/IPs -IF Inputs/Input $prog" \
  > "$logdir/party1.log" 2>&1 &
p1=$!

docker compose exec -T party2 bash -lc \
  "cd /mp-spdz && ./$binary $N_FLAG -p 2 -ip Config/IPs -IF Inputs/Input $prog" \
  > "$logdir/party2.log" 2>&1 &
p2=$!

wait "$p0"; s0=$?
wait "$p1"; s1=$?
wait "$p2"; s2=$?

end_ts=$(python3 -c "import time; print(int(time.time()*1000))")
elapsed=$(( end_ts - start_ts ))

# ── Display each party's output ──────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
for i in 0 1 2; do
  echo "──── Party $i output ────"
  cat "$logdir/party${i}.log"
  echo ""
done
echo "════════════════════════════════════════════════════════════"
echo "Protocol  : $protocol"
echo "Exit codes: party0=$s0  party1=$s1  party2=$s2"
echo "Wall-clock: ${elapsed} ms"