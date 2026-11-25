#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
action=${1:?Cần enable hoặc disable}
case $action in enable|disable) ;; *) exit 2 ;; esac
remote=./scripts/guest-ssh.sh
for node in rac1 rac2; do
    if [[ $node == rac1 ]]; then
        sources=(192.168.191.12/32 192.168.191.22/32 192.168.191.31/32 192.168.191.32/31)
    else
        sources=(192.168.191.11/32 192.168.191.21/32 192.168.191.31/32 192.168.191.32/31)
    fi
    for source in "${sources[@]}"; do
        rule="rule family=\"ipv4\" source address=\"$source\" protocol value=\"tcp\" accept"
        if [[ $action == enable ]]; then
            "$remote" "$node" "if ! sudo firewall-cmd --zone=public --query-rich-rule='$rule' >/dev/null; then sudo firewall-cmd --zone=public --add-rich-rule='$rule' --timeout=5400; fi"
        else
            "$remote" "$node" "if sudo firewall-cmd --zone=public --query-rich-rule='$rule' >/dev/null; then sudo firewall-cmd --zone=public --remove-rich-rule='$rule'; fi"
        fi
    done
done
