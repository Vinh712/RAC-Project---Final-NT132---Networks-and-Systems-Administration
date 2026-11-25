#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p evidence state
exec 9>state/stage-oracle.lock
flock -n 9
exec > >(tee -a evidence/stage-oracle.log) 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
(cd media && awk '$2 ~ /zip$/ {print}' ../infra/media.sha256 | sha256sum -c -)
remote=./scripts/guest-ssh.sh
grid=/u01/app/19c/grid
db=/u01/app/oracle/product/19c/dbhome_1
"$remote" rac1 'umask 077; mkdir -p "$HOME/stage"'
for home in grid db; do
    name="LINUX.X64_193000_${home}_home.zip"
    digest=$(awk -v name="$name" '$2 == name {print $1}' infra/media.sha256)
    if ! "$remote" rac1 "cd stage && printf '%s  %s\n' '$digest' '$name' | sha256sum -c -"; then
        "$remote" rac1 "umask 077; cat >stage/$name.part" <"media/$name"
        "$remote" rac1 "cd stage && printf '%s  %s\n' '$digest' '$name.part' | sha256sum -c - && mv '$name.part' '$name'"
    fi
    if [[ $home == grid ]]; then owner=grid; target=$grid; installer=gridSetup.sh
    else owner=oracle; target=$db; installer=runInstaller
    fi
    "$remote" rac1 "if ! sudo -u '$owner' test -f '$target/.rac-extracted'; then
        sudo -u '$owner' -H bash -c 'umask 077; cat >\$HOME/$name' <stage/$name &&
        sudo -u '$owner' -H bash -c 'unzip -qo \$HOME/$name -d $target && test -x $target/$installer && touch $target/.rac-extracted && rm \$HOME/$name'
    fi"
done
"$remote" rac1 "sudo test -f '$grid/cv/rpm/cvuqdisk-1.0.10-1.rpm'"
for node in rac1 rac2; do
    "$remote" rac1 "sudo cat '$grid/cv/rpm/cvuqdisk-1.0.10-1.rpm'" |
        "$remote" "$node" 'set -e; umask 077; mkdir -p "$HOME/stage"; cat >stage/cvuqdisk-1.0.10-1.rpm'
    "$remote" "$node" 'if ! rpm -q cvuqdisk; then sudo env CVUQDISK_GRP=oinstall rpm -Uvh "$HOME/stage/cvuqdisk-1.0.10-1.rpm"; fi'
done
