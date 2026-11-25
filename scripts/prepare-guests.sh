#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p evidence
exec > >(tee -a evidence/prepare-guests.log) 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
for node in rac1 rac2; do
    ./scripts/guest-ssh.sh "$node" 'set -e; hostname -f; uname -r; free -h; cat /etc/oracle-release; /sbin/ip -o address; lsblk -o NAME,SIZE,SERIAL,TYPE,MOUNTPOINT'
done
free -h
swapon --show
export ANSIBLE_SSH_COMMON_ARGS="-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$PWD/state/known_hosts"
ansible-playbook -i infra/inventory.ini --private-key "$PWD/state/ssh_ed25519" infra/prepare-guests.yml
