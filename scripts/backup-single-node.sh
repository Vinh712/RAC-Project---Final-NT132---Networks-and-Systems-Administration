#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p evidence state/backups
exec 9>state/backup.lock
flock -n 9
exec > >(tee -a evidence/backup-single-node.log) 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
virsh=(virsh -c qemu:///system)
vm=./scripts/vmctl.sh
ssh=./scripts/guest-ssh.sh
grid=/u01/app/19c/grid
db=/u01/app/oracle/product/19c/dbhome_1
pool=rac-lab-storage
available_kib=$(df -Pk state/backups | awk 'NR == 2 {print $4}')
(( available_kib > 240 * 1024 * 1024 ))
for node in rac1 rac2; do "$vm" state "$node"; done
[[ $("$ssh" rac1 "sudo $grid/bin/olsnodes") == rac1 ]]
backup="state/backups/single-node-$(TZ=Asia/Ho_Chi_Minh date +%Y%m%d-%H%M%S)"
mkdir "$backup"
for node in rac1 rac2; do
    "${virsh[@]}" dumpxml --inactive "$node" >"$backup/$node.xml"
done
for net in rac-lab-public rac-lab-private; do
    "${virsh[@]}" net-dumpxml "$net" >"$backup/$net.xml"
done
"${virsh[@]}" pool-dumpxml "$pool" >"$backup/$pool.xml"
cp state/oracle-secrets.json state/ssh_ed25519 state/known_hosts "$backup/"
"$ssh" rac1 "sudo -iu oracle env ORACLE_HOME=$db $db/bin/srvctl stop database -db RACLAB -stopoption IMMEDIATE && sudo $grid/bin/crsctl stop crs"
for node in rac1 rac2; do "$vm" shutdown "$node"; done
for node in rac1 rac2; do
    for i in $(seq 60); do
        [[ $(LC_ALL=C "$vm" state "$node") == "shut off (shutdown)" ]] && break
        sleep 2
    done
    [[ $(LC_ALL=C "$vm" state "$node") == "shut off (shutdown)" ]]
done
for volume in rac1-os.qcow2 rac2-os.qcow2 rac-asm.raw; do
    "${virsh[@]}" vol-download --pool "$pool" --sparse "$volume" "$backup/$volume"
done
for node in rac1 rac2; do "$vm" start "$node"; done
./scripts/start-single-db.sh
qemu-img check "$backup/rac1-os.qcow2"
qemu-img check "$backup/rac2-os.qcow2"
[[ $(stat -c %s "$backup/rac-asm.raw") == 64424509440 ]]
(cd "$backup" && sha256sum rac1-os.qcow2 rac2-os.qcow2 rac-asm.raw > SHA256SUMS)
printf '%s\n' "$backup" >state/single-node-backup
du -h "$backup"
