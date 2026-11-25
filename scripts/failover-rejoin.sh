#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
dir=${1:?Cần thư mục log demo}
[[ $dir =~ ^evidence/demos-[0-9]{8}-[0-9]{6}$ ]]
cross_read=${2:-$dir/cross-read.jsonl}
[[ $cross_read == "$dir"/cross-read*.jsonl ]]
test -s "$cross_read"
exec > >(tee -a "$dir/run.log") 2>&1
python=.venv/bin/python
"$python" client/failover.py --target rac1 --cut-power --log "$dir/failover.jsonl"
for i in $(seq 120); do
    if ./scripts/cluster-status.sh rac1 >"$dir/rejoin-current.log" 2>&1 &&
        rg -qi 'rac1[[:space:]]+1[[:space:]]+Active' "$dir/rejoin-current.log" &&
        rg -qi 'Instance RACLAB1 is running|running on instance\(s\) RACLAB1' "$dir/rejoin-current.log"; then
        break
    fi
    sleep 3
done
rg -qi 'rac1[[:space:]]+1[[:space:]]+Active' "$dir/rejoin-current.log"
rg -qi 'Instance RACLAB1 is running|running on instance\(s\) RACLAB1' "$dir/rejoin-current.log"
"$python" client/rac_client.py probe --both-instances --count 48 --log "$dir/rejoin-probe.jsonl"
jq -se '[.[]|select(.event=="connected")|.host] | unique == ["rac1","rac2"]' "$dir/rejoin-probe.jsonl"
"$python" client/reconcile.py "$dir/single-node.jsonl" "$dir"/expansion-*.jsonl \
    "$cross_read" "$dir/failover.jsonl" --out "$dir/reconciliation.json"
