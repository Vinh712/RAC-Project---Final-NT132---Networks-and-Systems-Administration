"""Tổng hợp CSV và PNG nội bộ từ sáu lần đo đã hoàn tất."""
import csv
import json
import subprocess
import sys
from statistics import mean, median
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt


def filesystem_device(suite):
    dev = subprocess.check_output(["findmnt", "-n", "-o", "MAJ:MIN", "-T", str(suite)],
                                  text=True).strip()
    devices = subprocess.check_output(["lsblk", "-nr", "-o", "MAJ:MIN,KNAME"], text=True)
    return dict(line.split() for line in devices.splitlines())[dev]


def host_metrics(run, device):
    memory = (run / "memory.log").read_text().splitlines()
    available = [int(line.split()[-1]) for line in memory if line.startswith("Mem:")]
    swap = [int(line.split()[2]) for line in memory if line.startswith("Swap:")]
    io = []
    columns = []
    for line in (run / "iostat.log").read_text().splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "Device":
            columns = fields
        elif columns and fields[0] == device:
            io.append(float(fields[columns.index("rkB/s")]) + float(fields[columns.index("wkB/s")]))
    return min(available) / 2**30, max(swap) / 2**20, mean(io) if io else None


def write_internal_report(suite, rows):
    device = filesystem_device(suite)
    lines = [
        "# Kết quả benchmark nội bộ", "",
        "Mỗi lượt sử dụng 12 worker, warm-up 60 giây và đo 180 giây.",
        "RAM, swap và I/O được đọc từ các mẫu host trong toàn bộ lượt chạy.",
        "Chỉ chia sẻ số benchmark khi có sự đồng ý của Oracle theo điều khoản tải phần mềm.", "",
        "| Cấu hình | Lặp | TPS | p50 (ms) | p95 (ms) | Request gặp lỗi | Giao dịch theo instance | RAM available thấp nhất (GiB) | Swap cao nhất (MiB) | I/O trung bình (KiB/s) |",
        "| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |",
    ]
    labels = {"one": "Một instance", "two": "Hai instance"}
    for row in rows:
        ram, swap, io = host_metrics(suite / f"{row['mode']}-{row['trial']}", device)
        instance_counts = ", ".join(f"{name}={count}" for name, count in sorted(row["by_instance"].items()))
        io_text = f"{io:.1f}" if io is not None else "?"
        lines.append(
            f"| {labels[row['mode']]} | {row['trial']} | {row['tps']:.2f} | "
            f"{row['p50_ms']:.2f} | {row['p95_ms']:.2f} | {row['error_rate']:.3%} | "
            f"{instance_counts} | {ram:.2f} | {swap:.1f} | {io_text} |"
        )
    groups = {mode: [row for row in rows if row["mode"] == mode] for mode in labels}
    tps_one, tps_two = (median(row["tps"] for row in groups[mode]) for mode in labels)
    p95_one, p95_two = (median(row["p95_ms"] for row in groups[mode]) for mode in labels)
    lines += [
        "", f"TPS trung vị là {tps_one:.2f} với một instance và {tps_two:.2f} với hai instance.",
        f"Chênh lệch TPS của hai instance so với một instance là {tps_two / tps_one - 1:+.2%}.",
        f"Trung vị p95 của ba lượt là {p95_one:.2f} ms và {p95_two:.2f} ms tương ứng.",
        f"Cột I/O cộng tốc độ đọc và ghi từ thiết bị filesystem {device}.", "",
    ]
    (suite / "BAO-CAO-NOI-BO.md").write_text("\n".join(lines))


def main():
    suite = Path(sys.argv[1])
    rows = []
    for mode in ("one", "two"):
        for trial in (1, 2, 3):
            summary = json.loads((suite / f"{mode}-{trial}" / "summary.json").read_text())
            summary["trial"] = trial
            rows.append(summary)
    fields = ["mode", "trial", "workers", "warmup_s", "duration_s", "tps", "p50_ms",
              "p95_ms", "requests", "inside_window", "error_rate", "final_status", "by_instance"]
    with (suite / "summary.csv").open("x", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    fig, axes = plt.subplots(1, 2, figsize=(10, 4), constrained_layout=True)
    for mode, label, color in (("one", "Một instance", "#255b85"),
                               ("two", "Hai instance", "#39795a")):
        data = [row for row in rows if row["mode"] == mode]
        for axis, field, unit in zip(axes, ("tps", "p95_ms"), ("Giao dịch/giây", "p95 (ms)")):
            axis.plot([row["trial"] for row in data], [row[field] for row in data],
                      "o-", label=label, color=color)
            axis.set(xlabel="Lần lặp", ylabel=unit, xticks=[1, 2, 3])
            axis.grid(axis="y", alpha=0.25)
            axis.legend()
    fig.savefig(suite / "benchmark-noi-bo.png", dpi=180)
    write_internal_report(suite, rows)


if __name__ == "__main__":
    main()
