#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p evidence
exec 9>state/run-demos.lock
flock -n 9
python=.venv/bin/python
add_options=()
if [[ $# == 0 ]]; then
    dir="evidence/demos-$(TZ=Asia/Ho_Chi_Minh date +%Y%m%d-%H%M%S)"
    mkdir "$dir"
    exec > >(tee "$dir/run.log") 2>&1
    ./scripts/cluster-status.sh rac1 | tee "$dir/single-node.log"
    "$python" client/rac_client.py write --log "$dir/single-node.jsonl"
    if [[ ! -s state/single-node-backup ]]; then
        ./scripts/backup-single-node.sh
    fi
    segment="$dir/expansion-stream"
else
    [[ $# == 2 && $1 == --resume-after-grid && $2 =~ ^evidence/demos-[0-9]{8}-[0-9]{6}$ ]]
    dir=$2
    test -s "$dir/single-node.jsonl"
    exec > >(tee -a "$dir/run.log") 2>&1
    add_options=(--resume-after-grid)
    segment="$dir/expansion-resume-$(TZ=Asia/Ho_Chi_Minh date +%H%M%S)"
fi
token="$segment.stop"
"$python" client/rac_client.py stream --count 2700 --stop-file "$token" --log "$segment.jsonl" >"$segment.log" 2>&1 &
stream=$!
trap 'touch "$token"; wait "$stream" || true' EXIT
for i in $(seq 30); do
    if rg -q '"status": "committed"' "$segment.log"; then break; fi
    kill -0 "$stream"
    sleep 1
done
rg -q '"status": "committed"' "$segment.log"
./scripts/add-node.sh "${add_options[@]}"
"$python" client/rac_client.py probe --both-instances --count 48 --log "$dir/two-instance-probe.jsonl"
for i in $(seq 60); do
    if jq -se 'any(.[]; .event=="result" and .status=="committed" and (.instance | ascii_upcase)=="RACLAB2")' "$segment.jsonl" >/dev/null; then break; fi
    kill -0 "$stream"
    sleep 1
done
touch "$token"
wait "$stream"
trap - EXIT
jq -se 'any(.[]; .event=="result" and .status=="committed" and (.instance | ascii_upcase)=="RACLAB2")' "$segment.jsonl"
"$python" client/rac_client.py cross-read --log "$dir/cross-read.jsonl"
./scripts/failover-rejoin.sh "$dir"
