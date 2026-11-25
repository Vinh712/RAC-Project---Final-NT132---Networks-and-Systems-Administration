"""Cắt nguồn đúng VM sau khi chứng minh session đang phục vụ trên VM đó."""
from __future__ import annotations

import argparse
import json
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from rac_client import Client, Journal, ROOT


def virsh(*args):
    return subprocess.check_output(["virsh", "-c", "qemu:///system", *args],
                                   text=True, timeout=30, cwd=ROOT).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", default="rac1", choices=["rac1", "rac2"])
    parser.add_argument("--cut-power", action="store_true", required=True)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    inventory = {}
    for line in (ROOT / "infra/inventory.ini").read_text().splitlines():
        if line.startswith(("rac1 ", "rac2 ")):
            name, *fields = line.split()
            inventory[name] = dict(field.split("=", 1) for field in fields)["vm_uuid"]
    for node, expected_uuid in inventory.items():
        if virsh("domuuid", node) != expected_uuid:
            raise RuntimeError(f"UUID đối chiếu sai cho {node}")
        if virsh("domstate", expected_uuid) != "running":
            raise RuntimeError(f"VM {node} phải chạy trước khi thử cắt nguồn")
        xml = virsh("dumpxml", "--inactive", expected_uuid)
        domain = ET.fromstring(xml)
        name = domain.findtext("name")
        asm = next((disk for disk in domain.findall("devices/disk")
                    if disk.findtext("serial") == "RAC_ASM01"), None)
        if name != node or asm is None or asm.find("source").get("file") !=                 "/var/lib/libvirt/images/rac-lab/rac-asm.raw":
            raise RuntimeError(f"XML libvirt không khớp với lab cho {node}")

    with Journal(args.log, show_errors=True) as journal:
        client = Client(journal, "client-bi-anh-huong")
        powered_off = False
        try:
            peer = "rac2" if args.target == "rac1" else "rac1"
            client.open_on(peer)
            journal.record("peer-confirmed", node=peer, instance=client.instance)
            client.close()
            client.open_on(args.target)
            before = client.write("failover-before-cut")
            if before["status"] != "committed" or client.host != args.target or before["had_error"]:
                raise RuntimeError(before)
            target_uuid = inventory[args.target]
            print(json.dumps(journal.record(
                "target-confirmed", node=client.host, instance=client.instance,
                uuid=target_uuid, request_id=before["request_id"],
            )), flush=True)
            start_ns = time.monotonic_ns()
            powered_off = True
            output = virsh("destroy", target_uuid)
            cut_ack_ns = time.monotonic_ns()
            print(json.dumps(journal.record(
                "power-cut", node=args.target, uuid=target_uuid, result=output,
                command_start_ns=start_ns, command_ack_ns=cut_ack_ns,
            )), flush=True)
            impacted = client.write("failover-reconnect", retries=24)
            print(json.dumps(impacted), flush=True)
            if not impacted["had_error"]:
                raise RuntimeError("Chưa quan sát được lỗi trên phiên client mục tiêu")
            after = impacted
            if after["status"] == "reconciled":
                after = client.write("failover-new-commit", retries=24)
            if after["status"] != "committed" or client.host == args.target:
                raise RuntimeError(after)
            print(json.dumps(journal.record(
                "recovery", request_id=after["request_id"], instance=after["instance"],
                elapsed_from_ack_ms=(after["monotonic_ns"] - cut_ack_ns) / 1e6,
                command_interval_ms=(cut_ack_ns - start_ns) / 1e6,
            )), flush=True)
            for result in (before, impacted, after):
                row = client.read(result["request_id"])
                if row is None or row[1] != result["writer_instance"]:
                    raise RuntimeError(f"Không đối soát được {result['request_id']}")
            print(json.dumps(journal.record("reconciled-after-cut",
                                            requests=len({r["request_id"] for r in (before, impacted, after)}))),
                  flush=True)
        finally:
            client.close()
            if powered_off and virsh("domstate", inventory[args.target]) == "shut off":
                print(virsh("start", inventory[args.target]), flush=True)


if __name__ == "__main__":
    main()
