#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
mkdir -p evidence
log="evidence/host-$(TZ=Asia/Ho_Chi_Minh date +%Y%m%d-%H%M%S)-$$.log"
exec > >(tee "$log") 2>&1
printf 'Log: %s\n' "$log"
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
pwd
cat /etc/os-release
uname -rm
lscpu | awk -F: '/^(CPU\(s\)|Model name|Virtualization):/ {print}'
free -h
df -hT / .
swapon --show
stat -c '%A %U %G %t:%T %n' /dev/kvm
printf '\nNhóm tiến trình: '; id -nG
printf 'Nhóm tài khoản: '; id -nG "$(id -un)"
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' git qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst openssh-client ansible python3-venv dnsutils chrony unzip sysstat xorriso
chronyc tracking
set +e
printf '\n$ virt-host-validate qemu\n'
virt-host-validate qemu
printf 'Mã thoát: %s\n' "$?"
qmp="$(printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"query-kvm"}' '{"execute":"quit"}')"
printf '\n$ qemu-system-x86_64 -machine pc,accel=kvm -cpu host -m 128 -nodefaults -nic none -display none -S -qmp stdio\n'
qemu_output="$(timeout 15s qemu-system-x86_64 -machine pc,accel=kvm -cpu host -m 128 -nodefaults -nic none -display none -S -qmp stdio <<<"$qmp" 2>&1)"
qemu_status=$?
printf '%s\nQEMU thoát: %s\n' "$qemu_output" "$qemu_status"
if (( qemu_status == 0 )) && jq -se 'any(.[]; .return.enabled == true and .return.present == true)' <<<"$qemu_output" >/dev/null; then
    qemu_result=PASS
else
    qemu_result=FAIL
fi
printf '\n$ virsh -c qemu:///system list --all\n'
if virsh -c qemu:///system list --all; then
    libvirt_result=PASS
else
    libvirt_result=FAIL
fi
printf '\nQEMU/KVM=%s libvirt=%s\n' "$qemu_result" "$libvirt_result"
[[ $qemu_result == PASS && $libvirt_result == PASS ]]
