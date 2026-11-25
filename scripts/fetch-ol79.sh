#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
mkdir -p media evidence state
exec 9>state/fetch-ol79.lock
flock -n 9
exec >>evidence/fetch-ol79.log 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
name=OracleLinux-R7-U9-Server-x86_64-dvd.iso
expected=$(awk -v name="$name" '$2 == name {print $1}' infra/media.sha256)
cd media
if [[ ! -f $name ]]; then
    curl --fail --location --retry 4 --retry-delay 2 --connect-timeout 15 --continue-at - --no-progress-meter --show-error --output "$name.part" \
        "https://yum.oracle.com/ISOS/OracleLinux/OL7/u9/x86_64/$name"
    printf '%s  %s\n' "$expected" "$name.part" | sha256sum -c -
    mv -- "$name.part" "$name"
else
    printf '%s  %s\n' "$expected" "$name" | sha256sum -c -
fi
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
