#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# benchmark.sh — run both int and sfix auction variants across all available
#                protocols and print a comparison table.
#
# Usage:
#   ./scripts/benchmark.sh                # all protocols, default orders
#   ./scripts/benchmark.sh --n-orders 4   # scale up virtual traders
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

n_orders="${1:---n-orders}"
n_orders_val="${2:-2}"

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

nparties=3
programs=(dark-auction dark-auction-sfix)
protocols=(mascot shamir semi)

declare -A proto_bin=(
  [mascot]=mascot-party.x
  [shamir]=shamir-party.x
  [semi]=semi-party.x
  [rep-ring]=replicated-ring-party.x
)

# ── Prerequisites ─────────────────────────────────────────────────────
mkdir -p Config Inputs

cat > Config/IPs <<'EOF'
party0
party1
party2
EOF

echo "==> Starting containers ..."
docker compose up -d --build party0 party1 party2

# ── Results table ─────────────────────────────────────────────────────
results=()

for prog in "${programs[@]}"; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Program: $prog"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Generate inputs for this program
  if [ "$n_orders" = "--n-orders" ]; then
    python3 scripts/generate_inputs.py "$prog" --n-orders "$n_orders_val"
  else
    python3 scripts/generate_inputs.py "$prog"
  fi

  # Compile
  echo "  Compiling $prog ..."
  docker compose exec -T party0 bash -lc "
    set -euo pipefail
    mkdir -p /mp-spdz/Programs/Source
    cp -f /workspace/${prog}.mpc /mp-spdz/Programs/Source/${prog}.mpc
    cd /mp-spdz
    python3 ./compile.py $prog
  "

  for proto in "${protocols[@]}"; do
    # Kill stale processes
    for c in party0 party1 party2; do
      docker compose exec -T "$c" bash -c \
        "killall -q mascot-party.x shamir-party.x semi-party.x replicated-ring-party.x 2>/dev/null || true" 2>/dev/null
    done
    sleep 1
    bin="${proto_bin[$proto]:-${proto}-party.x}"
    echo ""
    echo "  ▸ Running $prog on $proto ..."

    start_ts=$(python3 -c "import time; print(int(time.time()*1000))")

    set +e
    docker compose exec -T party0 bash -lc \
      "cd /mp-spdz && ./$bin -N $nparties -p 0 -ip Config/IPs -IF Inputs/Input -v $prog" \
      > "/tmp/bench_${prog}_${proto}_p0.log" 2>&1 &
    p0=$!
    docker compose exec -T party1 bash -lc \
      "cd /mp-spdz && ./$bin -N $nparties -p 1 -ip Config/IPs -IF Inputs/Input -v $prog" \
      > "/tmp/bench_${prog}_${proto}_p1.log" 2>&1 &
    p1=$!
    docker compose exec -T party2 bash -lc \
      "cd /mp-spdz && ./$bin -N $nparties -p 2 -ip Config/IPs -IF Inputs/Input -v $prog" \
      > "/tmp/bench_${prog}_${proto}_p2.log" 2>&1 &
    p2=$!

    wait "$p0"; s0=$?
    wait "$p1"; s1=$?
    wait "$p2"; s2=$?
    set -e

    end_ts=$(python3 -c "import time; print(int(time.time()*1000))")
    elapsed=$(( end_ts - start_ts ))

    if [ "$s0" -ne 0 ] || [ "$s1" -ne 0 ] || [ "$s2" -ne 0 ]; then
      status="FAIL($s0/$s1/$s2)"
    else
      status="OK"
    fi

    # Extract data-sent from party0's verbose output (MP-SPDZ prints it)
    data_sent=$(grep -oP 'Data sent = [\d.]+ \w+' "/tmp/bench_${prog}_${proto}_p0.log" 2>/dev/null | tail -1 || echo "n/a")

    results+=("$prog|$proto|${elapsed}ms|$status|$data_sent")
    echo "    $status  ${elapsed}ms  $data_sent"
  done
done

# ── Print summary table ──────────────────────────────────────────────
echo ""
echo "╔════════════════════════╦══════════╦══════════╦════════╦═══════════════════╗"
echo "║ Program                ║ Protocol ║ Time     ║ Status ║ Data Sent (P0)    ║"
echo "╠════════════════════════╬══════════╬══════════╬════════╬═══════════════════╣"
for row in "${results[@]}"; do
  IFS='|' read -r rprog rproto rtime rstatus rdata <<< "$row"
  printf "║ %-22s ║ %-8s ║ %8s ║ %-6s ║ %-17s ║\n" "$rprog" "$rproto" "$rtime" "$rstatus" "$rdata"
done
echo "╚════════════════════════╩══════════╩══════════╩════════╩═══════════════════╝"
echo ""
echo "Done.  Detailed logs in /tmp/bench_*.log"
