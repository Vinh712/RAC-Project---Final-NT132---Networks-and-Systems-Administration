#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
node=${1:?Cần rac1 hoặc rac2}
shift
case $node in
    rac1|rac2) ;;
    *) exit 2 ;;
esac
target=$(awk -v node="$node" '$1 == node { sub(/^ansible_host=/, "", $2); print $2 }' "$root/infra/inventory.ini")
exec ssh -i "$root/state/ssh_ed25519" -o IdentitiesOnly=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$root/state/known_hosts" "racadmin@$target" "$@"
