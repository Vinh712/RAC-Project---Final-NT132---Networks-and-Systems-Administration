#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
virsh=(virsh -c qemu:///system)
mkdir -p evidence
exec > >(tee -a evidence/infra-prepare.log) 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
"${virsh[@]}" list --all
for spec in public private; do
    file="infra/rac-$spec.xml"
    virt-xml-validate "$file" network
    uuid=$(sed -n 's|.*<uuid>\(.*\)</uuid>.*|\1|p' "$file")
    if existing=$("${virsh[@]}" net-uuid "rac-lab-$spec" 2>/dev/null); then
        [[ $existing == "$uuid" ]] || { printf 'UUID mạng xung đột: %s\n' "$existing"; exit 1; }
    else
        case $spec in public) bridge=virbr-racpub ;; private) bridge=virbr-racpriv ;; esac
        if ip link show dev "$bridge" &>/dev/null; then
            printf 'Bridge đã tồn tại: %s\n' "$bridge"; exit 1
        fi
    fi
done
python3 - <<'PY'
from ipaddress import ip_network
from json import loads
from subprocess import check_output

for route in loads(check_output(["ip", "-j", "-4", "route", "show", "table", "all"])):
    destination = route.get("dst", "default")
    if destination == "default":
        continue
    network = ip_network(destination, strict=False)
    public = ip_network("192.168.191.0/24")
    private = ip_network("192.168.192.0/24")
    own_public = route.get("dev") == "virbr-racpub" and network.subnet_of(public)
    if (network.overlaps(public) and not own_public) or network.overlaps(private):
        raise SystemExit(f"Route trùng subnet lab: {route}")
PY
for spec in public private; do
    name="rac-lab-$spec"
    if ! "${virsh[@]}" net-uuid "$name" >/dev/null 2>&1; then
        "${virsh[@]}" net-define "infra/rac-$spec.xml"
    fi
    if ! "${virsh[@]}" net-list --name | grep -Fxq "$name"; then
        "${virsh[@]}" net-start "$name"
    fi
done
virt-xml-validate infra/rac-storage.xml storagepool
pool=rac-lab-storage
if existing=$("${virsh[@]}" pool-uuid "$pool" 2>/dev/null); then
    [[ $existing == a31f4bdf-86f6-4f6a-a85a-27902c210cac ]] || { printf 'UUID pool xung đột: %s\n' "$existing"; exit 1; }
else
    "${virsh[@]}" pool-define infra/rac-storage.xml
fi
if ! "${virsh[@]}" pool-list --name | awk 'NF { print $1 }' | grep -Fxq "$pool"; then
    if ! "${virsh[@]}" pool-start "$pool"; then
        "${virsh[@]}" pool-build "$pool"
        "${virsh[@]}" pool-start "$pool"
    fi
fi
"${virsh[@]}" net-list --all
"${virsh[@]}" pool-info "$pool"
dig @192.168.191.1 rac-scan.rac.test A +short +time=2 +tries=1 | sort >evidence/scan-addresses.txt
cat evidence/scan-addresses.txt
diff -u <(printf '%s\n' 192.168.191.{31,32,33}) evidence/scan-addresses.txt
