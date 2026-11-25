#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p evidence state
exec 9>state/install-guests.lock
flock -n 9
exec > >(tee -a evidence/install-guests.log) 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
export LIBVIRT_DEFAULT_URI=qemu:///system
pool=rac-lab-storage
iso=OracleLinux-R7-U9-Server-x86_64-dvd.iso
./scripts/infra-prepare.sh
(cd media && awk -v name="$iso" '$2 == name' ../infra/media.sha256 | sha256sum -c -)

expected_pool=/var/lib/libvirt/images/rac-lab
[[ $(virsh pool-uuid "$pool") == a31f4bdf-86f6-4f6a-a85a-27902c210cac ]]
[[ $(virsh pool-dumpxml "$pool" | sed -n 's|.*<path>\(.*\)</path>.*|\1|p') == "$expected_pool" ]]
if [[ ! -s state/ssh_ed25519 ]]; then
    ssh-keygen -q -t ed25519 -N '' -C rac-lab-host -f state/ssh_ed25519
fi
ssh_key=$(ssh-keygen -y -f state/ssh_ed25519)
mkdir -p state/install
for boot_file in vmlinuz initrd.img; do
    xorriso -osirrox on -indev "$PWD/media/$iso" \
        -extract "/images/pxeboot/$boot_file" "$PWD/state/install/$boot_file"
done

if [[ ! -e state/iso-uploaded ]] || ! virsh vol-info --pool "$pool" "$iso" >/dev/null 2>&1; then
    if ! virsh vol-info --pool "$pool" "$iso" >/dev/null 2>&1; then
        virsh vol-create-as --pool "$pool" "$iso" "$(stat -c %s "media/$iso")" --format raw
    fi
    virsh vol-upload --pool "$pool" "$iso" "media/$iso"
    touch state/iso-uploaded
fi
if ! virsh vol-info --pool "$pool" rac-asm.raw >/dev/null 2>&1; then
    virsh vol-create-as --pool "$pool" rac-asm.raw 60G --allocation 0 --format raw
fi
asm_path=$(virsh vol-path --pool "$pool" rac-asm.raw)
[[ $asm_path == "$expected_pool/rac-asm.raw" ]]

new_nodes=()
for node in rac1 rac2; do
    read -r _ public private public_mac private_mac uuid < <(awk -v node="$node" '$1 == node' infra/inventory.ini)
    public=${public#ansible_host=} private=${private#private_ip=}
    public_mac=${public_mac#public_mac=} private_mac=${private_mac#private_mac=} uuid=${uuid#vm_uuid=}
    if actual=$(virsh domuuid "$node" 2>/dev/null); then
        [[ $actual == "$uuid" ]] || { printf 'UUID VM xung đột: %s\n' "$actual"; exit 1; }
        virsh dominfo "$node"
        continue
    fi
    available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    if (( available_kib < 13 * 1024 * 1024 )); then
        printf 'MemAvailable hiện tại thấp hơn 13 GiB trước khi cấp thêm 9 GiB.\n'
        exit 1
    fi
    os_volume="$node-os.qcow2"
    if ! virsh vol-info --pool "$pool" "$os_volume" >/dev/null 2>&1; then
        virsh vol-create-as --pool "$pool" "$os_volume" 80G --allocation 0 --format qcow2
    fi
    ks="$PWD/state/install/$node/ks.cfg"
    mkdir -p "$(dirname "$ks")"
    sed -e "s|@SSH_KEY@|$ssh_key|" -e "s|@NODE@|$node|" \
        -e "s|@PUBLIC_MAC@|$public_mac|" -e "s|@PRIVATE_MAC@|$private_mac|" \
        -e "s|@PUBLIC_IP@|$public|" -e "s|@PRIVATE_IP@|$private|" infra/ks.cfg.in >"$ks"

    # Các ổ cùng pool chỉ chứa volume của lab. Kickstart chỉ khởi tạo vda.
    virt-install --connect qemu:///system --name "$node" --uuid "$uuid" \
        --virt-type kvm --osinfo ol7.9 --memory 9216 --vcpus 4 --cpu host-passthrough \
        --memballoon model=none --graphics none --console pty,target_type=serial \
        --disk "vol=$pool/$os_volume,bus=virtio,target.dev=vda,serial=RAC_OS_${node^^},cache=none" \
        --disk "path=$asm_path,format=raw,bus=virtio,target.dev=vdb,serial=RAC_ASM01,cache=none,io=native,shareable=on" \
        --disk "vol=$pool/$iso,device=cdrom,readonly=on" \
        --network "network=rac-lab-public,model=virtio,mac=$public_mac" \
        --network "network=rac-lab-private,model=virtio,mac=$private_mac" \
        --install "kernel=$PWD/state/install/vmlinuz,initrd=$PWD/state/install/initrd.img,kernel_args=inst.ks=file:/ks.cfg inst.stage2=cdrom inst.repo=cdrom console=ttyS0" \
        --initrd-inject "$ks" --noautoconsole
    new_nodes+=("$node")
done
for node in "${new_nodes[@]}"; do
    deadline=$(( SECONDS + 1200 ))
    while [[ $(LC_ALL=C virsh domstate "$node") != "shut off" ]]; do
        if (( SECONDS >= deadline )); then
            printf 'Hết thời gian chờ Kickstart %s. Kiểm tra console VM.\n' "$node"
            exit 1
        fi
        sleep 5
    done
    [[ $(LC_ALL=C virsh domstate "$node" --reason) == "shut off (shutdown)" ]]
    virsh start "$node"
done
virsh list --all
free -h
swapon --show
