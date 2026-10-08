#!/usr/bin/env python3
"""Measure real CLI startup + address collection; optional local regression gate."""
import argparse
import statistics
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', nargs='?', default='.build/release/macip')
parser.add_argument('--runs', type=int, default=20)
parser.add_argument('--max-ms', type=float, help='Fail if median exceeds this local limit')
args = parser.parse_args()
if args.runs < 1:
    parser.error('--runs must be positive')
binary = str(Path(args.binary).resolve())
subprocess.run([binary, '--version'], check=True, timeout=5)
samples = []
for _ in range(args.runs):
    start = time.perf_counter()
    subprocess.run([binary, '-c', 'a'], stdout=subprocess.DEVNULL, check=True, timeout=5)
    samples.append((time.perf_counter() - start) * 1000)
median = statistics.median(samples)
print(f'{args.runs} runs: median {median:.1f} ms, min {min(samples):.1f} ms, max {max(samples):.1f} ms')
if args.max_ms is not None and median > args.max_ms:
    raise SystemExit(f'Median exceeds {args.max_ms:g} ms')
