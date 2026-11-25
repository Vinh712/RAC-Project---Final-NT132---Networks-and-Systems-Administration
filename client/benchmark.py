"""Benchmark công việc ghi/commit qua SCAN với số worker cố định."""
from __future__ import annotations

import argparse
import csv
import json
import statistics
import subprocess
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from pathlib import Path

from rac_client import Client, Journal


def run_worker(worker_id, journal, schedule):
    client = Client(journal, str(worker_id), table="BENCH_REQUESTS")
    try:
        schedule["ready"].wait(timeout=15)
        target = "rac2" if schedule["mode"] == "two" and worker_id % 2 else "rac1"
        client.open_on(target)
        for phase in ("warmup", "measure"):
            ordinal = 0
            stop_at = schedule[phase]
            while time.monotonic_ns() < stop_at:
                payload = f"bench-worker-{worker_id:03d}-item-{ordinal % 4096:04d}"
                client.write(payload, phase=phase, retries=2)
                ordinal += 1
    finally:
        client.close()


def quantile(samples, p):
    if not samples:
        return None
    return statistics.quantiles(samples, n=100, method="inclusive")[p - 1] if len(samples) > 1 else samples[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workers", type=int, default=12)
    parser.add_argument("--warmup", type=int, default=60)
    parser.add_argument("--duration", type=int, default=180)
    parser.add_argument("--mode", required=True, choices=["one", "two"])
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if min(args.workers, args.warmup, args.duration) < 1:
        parser.error("workers, warmup và duration đều phải dương")
    args.out.mkdir(parents=True)
    schedule = {"ready": threading.Barrier(args.workers + 1), "mode": args.mode}
    with ExitStack() as stack:
        log = stack.enter_context(Journal(args.out / "transactions.jsonl"))
        workers = stack.enter_context(ThreadPoolExecutor(args.workers))
        monitors = []
        for key, command in (("vmstat", ["vmstat", "-w", "-t", "1"]),
                             ("iostat", ["iostat", "-dx", "-y", "-t", "1"]),
                             ("memory", ["free", "-b", "-s", "1"])):
            file = stack.enter_context((args.out / f"{key}.log").open("x"))
            monitor = subprocess.Popen(["stdbuf", "-oL", *command], stdout=file,
                                       stderr=subprocess.STDOUT)
            monitors.append(monitor)
        try:
            tasks = [workers.submit(run_worker, idx, log, schedule) for idx in range(args.workers)]
            start = time.monotonic_ns()
            schedule["warmup"] = start + args.warmup * 10**9
            schedule["measure"] = schedule["warmup"] + args.duration * 10**9
            log.record("benchmark-start", mode=args.mode, workers=args.workers,
                       warmup_end_ns=schedule["warmup"], measure_end_ns=schedule["measure"])
            schedule["ready"].wait(timeout=15)
            for task in tasks:
                task.result()
        finally:
            for monitor in monitors:
                monitor.terminate()
            for monitor in monitors:
                monitor.wait(timeout=5)

    with (args.out / "transactions.jsonl").open() as source:
        rows = [row for line in source if (row := json.loads(line))["event"] == "result"
                and row.get("phase") == "measure"]
    with (args.out / "transactions.csv").open("x", newline="") as csv_file:
        columns = ["timestamp", "monotonic_ns", "event", "status", "request_id", "worker",
                   "phase", "instance", "writer_instance", "retry", "had_error", "latency_ms"]
        writer = csv.DictWriter(csv_file, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)
    completed = [row for row in rows if row["monotonic_ns"] <= schedule["measure"]]
    successes = [row for row in completed if row["status"] in {"committed", "reconciled"}]
    instances = Counter(row["writer_instance"] for row in successes)
    latencies = [row["latency_ms"] for row in successes]
    summary = {"mode": args.mode, "workers": args.workers, "warmup_s": args.warmup,
               "duration_s": args.duration, "tps": len(successes) / args.duration,
               "p50_ms": quantile(latencies, 50), "p95_ms": quantile(latencies, 95),
               "requests": len(rows), "inside_window": len(completed),
               "error_rate": sum(row["had_error"] for row in rows) / len(rows) if rows else None,
               "final_status": Counter(row["status"] for row in rows), "by_instance": instances}
    with (args.out / "summary.json").open("x") as file:
        json.dump(summary, file, indent=2)
        file.write("\n")
    if len(instances) != (1 if args.mode == "one" else 2):
        raise SystemExit("Phân bố instance khác cấu hình phép đo")


if __name__ == "__main__":
    main()
