#!/usr/bin/env python3
"""
Generate dark-auction input files — human-readable AND MP-SPDZ format.

Two outputs per party:

  inputs/party{pid}.txt     Human-readable: 4 values per line, #-comments.
  Inputs/Input-P{pid}-0     MP-SPDZ format: one integer per line.

The readable file can be hand-edited — run this script with --convert-only
to re-generate MP-SPDZ files from edited readable files.

Usage examples:

  # Generate random inputs and convert:
  python3 scripts/generate_inputs.py --n-orders 10 --seed 42

  # Convert hand-edited readable files to MP-SPDZ format:
  python3 scripts/generate_inputs.py --convert-only

  # Generate sfix (fixed-point) inputs:
  python3 scripts/generate_inputs.py --sfix --n-orders 10 --seed 42
"""
import argparse
import os
import random

N_PARTIES   = 3
ASSET_NAMES = ["BTC", "ETH", "SOL"]
BASE_PRICES = {"BTC": 100, "ETH": 200, "SOL": 50}

READABLE_DIR = "inputs"
MPSPDZ_DIR   = "Inputs"


# ── Generation ───────────────────────────────────────────────────────────

def generate_readable(n_orders: int, use_sfix: bool, seed: int):
    """Generate human-readable input files in inputs/party{pid}.txt."""
    rng = random.Random(seed)
    os.makedirs(READABLE_DIR, exist_ok=True)

    for pid in range(N_PARTIES):
        path = os.path.join(READABLE_DIR, f"party{pid}.txt")
        with open(path, "w") as f:
            f.write(f"# Party {pid} — dark-auction orders\n")
            f.write(f"# Each line: bid_price  bid_qty  ask_price  ask_qty\n")
            f.write(f"# A zero price means 'no order on that side'.\n")
            f.write(f"#\n")

            for asset in ASSET_NAMES:
                base = BASE_PRICES[asset]
                f.write(f"\n# ── {asset} orders ──\n")
                f.write(f"# bid_price  bid_qty  ask_price  ask_qty\n")

                for k in range(n_orders):
                    has_bid = rng.random() < 0.6
                    has_ask = rng.random() < 0.6

                    if has_bid:
                        bp = base + rng.randint(-15, 10)
                        bq = rng.randint(1, 5)
                    else:
                        bp, bq = 0, 0

                    if has_ask:
                        ap = base + rng.randint(-5, 20)
                        aq = rng.randint(1, 5)
                    else:
                        ap, aq = 0, 0

                    if use_sfix:
                        bp_f = bp + rng.randint(0, 99) / 100.0 if has_bid else 0.0
                        ap_f = ap + rng.randint(0, 99) / 100.0 if has_ask else 0.0
                        f.write(f"  {bp_f:10.2f}  {bq:8d}  {ap_f:10.2f}  {aq:8d}\n")
                    else:
                        f.write(f"  {bp:10d}  {bq:8d}  {ap:10d}  {aq:8d}\n")

        print(f"  Wrote {path}")


# ── Conversion ───────────────────────────────────────────────────────────

def parse_readable(pid: int, use_sfix: bool):
    """
    Parse a human-readable input file and return a flat list of values
    in MP-SPDZ reading order:  for each asset, for each order: bp bq ap aq.
    """
    path = os.path.join(READABLE_DIR, f"party{pid}.txt")
    values = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) != 4:
                raise ValueError(
                    f"{path}: expected 4 values per data line, got {len(parts)}: {line!r}"
                )
            if use_sfix:
                values.extend(float(x) for x in parts)
            else:
                values.extend(int(x) for x in parts)
    return values


def convert_to_mpspdz(use_sfix: bool):
    """Read inputs/party{pid}.txt → write Inputs/Input-P{pid}-0."""
    os.makedirs(MPSPDZ_DIR, exist_ok=True)
    for pid in range(N_PARTIES):
        values = parse_readable(pid, use_sfix)
        path = os.path.join(MPSPDZ_DIR, f"Input-P{pid}-0")
        with open(path, "w") as f:
            for v in values:
                if use_sfix and isinstance(v, float):
                    f.write(f"{v:.6f}\n")
                else:
                    f.write(f"{int(v)}\n")
        n_orders = len(values) // (len(ASSET_NAMES) * 4)
        print(f"  Wrote {path}  ({len(values)} values, "
              f"{len(ASSET_NAMES)} assets × {n_orders} orders × 4)")


# ── Summary ──────────────────────────────────────────────────────────────

def print_summary(use_sfix: bool):
    """Print a human-readable summary of all party inputs."""
    for pid in range(N_PARTIES):
        values = parse_readable(pid, use_sfix)
        n_orders = len(values) // (len(ASSET_NAMES) * 4)
        print(f"\n  Party {pid} ({n_orders} orders/asset):")
        idx = 0
        for asset in ASSET_NAMES:
            print(f"    {asset}:")
            for k in range(n_orders):
                bp, bq, ap, aq = values[idx:idx + 4]
                idx += 4
                bid_str = f"bid({bp}×{bq})" if bp else "no bid"
                ask_str = f"ask({ap}×{aq})" if ap else "no ask"
                print(f"      order {k:2d}: {bid_str:20s}  {ask_str}")


# ── Main ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Generate / convert dark-auction input files"
    )
    parser.add_argument("--n-orders", type=int, default=10,
                        help="Orders per party per asset (default: 10)")
    parser.add_argument("--seed", type=int, default=42,
                        help="Random seed (default: 42)")
    parser.add_argument("--sfix", action="store_true",
                        help="Use fixed-point prices")
    parser.add_argument("--convert-only", action="store_true",
                        help="Only convert existing readable files to MP-SPDZ")
    parser.add_argument("--summary", action="store_true",
                        help="Print summary of inputs after generation")
    args = parser.parse_args()

    if args.convert_only:
        print("Converting readable files → MP-SPDZ format:")
        convert_to_mpspdz(args.sfix)
    else:
        print(f"Generating inputs: n_orders={args.n_orders}, "
              f"sfix={args.sfix}, seed={args.seed}")
        generate_readable(args.n_orders, args.sfix, args.seed)
        print("\nConverting → MP-SPDZ format:")
        convert_to_mpspdz(args.sfix)

    if args.summary or not args.convert_only:
        print_summary(args.sfix)


if __name__ == "__main__":
    main()
