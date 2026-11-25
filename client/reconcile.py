"""Đối soát request ID trong log client với dữ liệu demo đã commit."""
import argparse
import json
from collections import Counter
from pathlib import Path

from rac_client import connect, timestamp


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    expected = {}
    results = {}
    duplicate_log = []
    for path in args.logs:
        with path.open() as source:
            for line in source:
                event = json.loads(line)
                if event["event"] == "request":
                    request_id = event["request_id"]
                    if request_id in expected:
                        duplicate_log.append(request_id)
                    expected[request_id] = event["payload"]
                elif event["event"] == "result":
                    results[event["request_id"]] = event["status"]

    actual = {}
    duplicate_rows = []
    ids = list(expected)
    with connect() as connection, connection.cursor() as cursor:
        for offset in range(0, len(ids), 100):
            parameters = {f"id{i}": request_id for i, request_id in enumerate(ids[offset:offset + 100])}
            binds = ", ".join(f":{key}" for key in parameters)
            cursor.execute(
                f"select request_id,payload from RACDATA.REQUESTS where request_id in ({binds})",
                parameters,
            )
            for request_id, payload in cursor:
                if request_id in actual:
                    duplicate_rows.append(request_id)
                actual[request_id] = payload
    missing = [request_id for request_id in ids if request_id not in actual]
    mismatched = [request_id for request_id in actual if actual[request_id] != expected[request_id]]
    pending = [request_id for request_id in missing if results.get(request_id) in {None, "unknown"}]
    summary = {
        "timestamp": timestamp(), "requested": len(expected), "found": len(actual),
        "client_status": Counter(results.values()), "missing": missing,
        "mismatched_payload": mismatched, "duplicate_log": duplicate_log,
        "duplicate_rows": duplicate_rows, "unresolved": pending,
    }
    output = json.dumps(summary, indent=2)
    with args.out.open("x") as file:
        file.write(output + "\n")
    print(output)
    if not ids or missing or mismatched or duplicate_log or duplicate_rows:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
