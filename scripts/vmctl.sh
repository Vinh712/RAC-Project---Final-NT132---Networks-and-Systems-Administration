#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
action=${1:?Cần start, shutdown, state hoặc console}
node=${2:?Cần rac1 hoặc rac2}
case $node in rac1|rac2) ;; *) exit 2 ;; esac
uuid=$(awk -v node="$node" '$1 == node { sub(/^vm_uuid=/, "", $6); print $6 }' infra/inventory.ini)
virsh=(virsh -c qemu:///system)
actual=$("${virsh[@]}" domuuid "$node")
[[ -n $uuid && $actual == "$uuid" ]] || { printf 'UUID xung đột: %s\n' "$actual"; exit 1; }
case $action in
    start|shutdown|console) exec "${virsh[@]}" "$action" "$uuid" ;;
    state) exec "${virsh[@]}" domstate "$uuid" --reason ;;
    *) exit 2 ;;
esac
