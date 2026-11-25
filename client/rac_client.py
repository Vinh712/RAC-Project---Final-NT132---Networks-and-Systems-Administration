"""Client Thin Oracle 19c cho service RAC trong mạng lab."""
from __future__ import annotations

import argparse
import ipaddress
import json
import random
import subprocess
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import oracledb

ROOT = Path(__file__).resolve().parents[1]
SERVICE = "racapp.rac.test"
SCAN = "rac-scan.rac.test"
DNS = "192.168.191.1"
ZONE = ZoneInfo("Asia/Ho_Chi_Minh")
RETRYABLE = {
    "DPY-1001", "DPY-4011", "DPY-4024", "DPY-6005", "DPY-6010",
    "ORA-00028", "ORA-01012", "ORA-01033", "ORA-03113", "ORA-03114",
    "ORA-03135", "ORA-12514", "ORA-12516", "ORA-12537", "ORA-12541",
    "ORA-12543", "ORA-12545", "ORA-12170",
}


def timestamp() -> str:
    return datetime.now(ZONE).isoformat(timespec="milliseconds")


class Journal:
    def __init__(self, path: Path, *, show_errors=False):
        self.show_errors = show_errors
        path.parent.mkdir(parents=True, exist_ok=True)
        self.file = path.open("x", encoding="utf-8", buffering=1)
        self.lock = threading.Lock()

    def record(self, event: str, **fields):
        row = {"timestamp": timestamp(), "monotonic_ns": time.monotonic_ns(),
               "event": event, **fields}
        with self.lock:
            line = json.dumps(row, ensure_ascii=False)
            self.file.write(line + "\n")
            if self.show_errors and event == "error":
                print(line, flush=True)
        return row

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.file.close()


def scan_addresses():
    answer = subprocess.check_output(
        ["dig", "@" + DNS, SCAN, "A", "+short", "+time=2", "+tries=1"],
        text=True, timeout=4,
    )
    addresses = [str(ipaddress.IPv4Address(line)) for line in answer.splitlines()]
    if not addresses or any(ipaddress.IPv4Address(addr) not in ipaddress.IPv4Network("192.168.191.0/24")
                            for addr in addresses):
        raise RuntimeError(f"Địa chỉ SCAN không hợp lệ: {addresses}")
    random.shuffle(addresses)
    return addresses


def connect(instance=None):
    if instance not in {None, "RACLAB1", "RACLAB2"}:
        raise ValueError(instance)
    addresses = "".join(f"(ADDRESS=(PROTOCOL=TCP)(HOST={ip})(PORT=1521))"
                        for ip in scan_addresses())
    instance_filter = f"(INSTANCE_NAME={instance})" if instance else ""
    dsn = ("(DESCRIPTION=(CONNECT_TIMEOUT=5)(TRANSPORT_CONNECT_TIMEOUT=2)"
           "(ADDRESS_LIST=(LOAD_BALANCE=OFF)(FAILOVER=ON)" + addresses
           + f")(CONNECT_DATA=(SERVICE_NAME={SERVICE}){instance_filter}))")
    password = json.loads((ROOT / "state/oracle-secrets.json").read_text())["RACAPP"]
    connection = oracledb.connect(user="RACAPP", password=password, dsn=dsn)
    connection.call_timeout = 5000
    return connection


class Client:
    def __init__(self, journal: Journal, worker: str, table="REQUESTS"):
        if table not in {"REQUESTS", "BENCH_REQUESTS"}:
            raise ValueError(table)
        self.journal = journal
        self.worker = worker
        self.table = table
        self.conn = None
        self.instance = None
        self.host = None

    def open(self, instance=None):
        if self.conn is None:
            self.conn = connect(instance) if instance else connect()
            try:
                with self.conn.cursor() as cursor:
                    cursor.execute(
                        "select sys_context('USERENV','INSTANCE_NAME'), "
                        "sys_context('USERENV','SERVER_HOST') from dual"
                    )
                    self.instance, server_host = cursor.fetchone()
                    self.host = server_host.lower().split(".")[0]
            except oracledb.Error:
                self.close()
                raise
        return self.instance

    def close(self):
        if self.conn is not None:
            try:
                self.conn.close()
            except oracledb.Error:
                pass
        self.conn = None
        self.instance = None
        self.host = None

    def open_on(self, target: str):
        instance = {"rac1": "RACLAB1", "rac2": "RACLAB2"}[target]
        self.close()
        self.open(instance)
        if self.host != target:
            raise RuntimeError(f"SCAN đã trả phiên trên {self.host} khi yêu cầu {target}")

    def read(self, request_id: str):
        self.open()
        with self.conn.cursor() as cursor:
            cursor.execute(
                f"select payload,writer_instance from RACDATA.{self.table} where request_id=:r",
                r=request_id,
            )
            return cursor.fetchone()

    def write(self, payload: str, phase="demo", retries=15, request_id=None):
        request_id = str(uuid.UUID(request_id)) if request_id else str(uuid.uuid4())
        started = time.monotonic_ns()
        pending_commit = False
        observed_error = False
        self.journal.record("request", request_id=request_id, worker=self.worker, phase=phase,
                            payload=payload, instance=self.instance)
        for attempt in range(retries + 1):
            step = "connect"
            try:
                self.open()
                if attempt:
                    step = "reconcile"
                    row = self.read(request_id)
                    if row is not None:
                        if row[0] != payload:
                            raise RuntimeError(f"Payload xung đột cho {request_id}")
                        return self._result("reconciled", request_id, started, phase, attempt,
                                            observed_error, row[1])
                step = "insert"
                with self.conn.cursor() as cursor:
                    cursor.execute(
                        f"insert into RACDATA.{self.table} "
                        "(request_id,payload,writer_instance) values (:r,:p,:i)",
                        r=request_id, p=payload, i=self.instance,
                    )
                step = "commit"
                pending_commit = True
                self.conn.commit()
                return self._result("committed", request_id, started, phase, attempt,
                                    observed_error, self.instance)
            except oracledb.Error as exc:
                error = exc.args[0]
                observed_error = True
                self.journal.record(
                    "error", request_id=request_id, worker=self.worker, phase=phase,
                    instance=self.instance, retry=attempt, step=step,
                    code=error.full_code, message=str(error).splitlines()[0],
                )
                self.close()
                can_retry = (error.full_code in RETRYABLE or error.isrecoverable
                             or step == "commit" or error.full_code == "ORA-00001")
                if attempt == retries or not can_retry:
                    unresolved = pending_commit or error.full_code == "ORA-00001"
                    return self._result("unknown" if unresolved else "failed",
                                        request_id, started, phase, attempt, observed_error)
                time.sleep(min(0.25 * (attempt + 1), 2.0))
        raise AssertionError("Mọi nhánh phải có kết quả")

    def _result(self, status, request_id, started, phase, attempt, observed_error, writer=None):
        return self.journal.record(
            "result", status=status, request_id=request_id, worker=self.worker, phase=phase,
            instance=self.instance, writer_instance=writer, retry=attempt,
            had_error=observed_error, latency_ms=(time.monotonic_ns() - started) / 1e6,
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["write", "probe", "cross-read", "stream"])
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--count", type=int, default=30)
    parser.add_argument("--stop-file", type=Path)
    parser.add_argument("--both-instances", action="store_true")
    args = parser.parse_args()
    with Journal(args.log) as journal:
        client = Client(journal, "demo")
        try:
            if args.mode == "probe":
                by_instance = {}
                for index in range(args.count):
                    if args.both_instances:
                        client.open_on(("rac1", "rac2")[index % 2])
                    instance = client.open()
                    by_instance[instance] = by_instance.get(instance, 0) + 1
                    journal.record("connected", instance=instance, host=client.host)
                    client.close()
                print(json.dumps(by_instance))
            elif args.mode == "cross-read":
                client.open_on("rac1")
                result = client.write("demo-read-across-instances")
                if result["status"] != "committed":
                    raise RuntimeError(result)
                client.close()
                client.open_on("rac2")
                row = client.read(result["request_id"])
                if row != ("demo-read-across-instances", result["instance"]):
                    raise RuntimeError(f"Bản ghi khác dự kiến: {row}")
                print(json.dumps(journal.record(
                    "cross-read", request_id=result["request_id"],
                    reader=client.instance, writer=row[1], payload=row[0],
                )))
            else:
                count = 1 if args.mode == "write" else args.count
                for idx in range(count):
                    if args.stop_file and args.stop_file.exists():
                        break
                    result = client.write(f"rac-lab-request-{idx:05d}")
                    print(json.dumps(result, ensure_ascii=False), flush=True)
                    if result["status"] not in {"committed", "reconciled"}:
                        raise RuntimeError(result)
                    if args.mode == "stream":
                        client.close()
                        time.sleep(1)
        finally:
            client.close()


if __name__ == "__main__":
    main()
