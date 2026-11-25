#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p evidence
exec 9>state/install-db.lock
flock -n 9
exec > >(tee -a evidence/install-db.log) 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
remote=./scripts/guest-ssh.sh
grid=/u01/app/19c/grid
home=/u01/app/oracle/product/19c/dbhome_1
"$remote" rac1 "sudo $grid/bin/crsctl check crs; sudo -iu oracle test -x $home/runInstaller"
"$remote" rac1 "sudo -iu oracle bash -c 'umask 077; cat > /home/oracle/rac-dbhome.rsp'" <oracle/db-home.properties
set +e
"$remote" rac1 "sudo -iu oracle $home/runInstaller -silent -responseFile /home/oracle/rac-dbhome.rsp" | tee evidence/db-oui.log
oui_code=${PIPESTATUS[0]}
set -e
printf 'DB OUI exit=%s\n' "$oui_code"
if (( oui_code != 0 && oui_code != 6 )); then
    exit "$oui_code"
fi
if ! rg -q '/root\.sh' evidence/db-oui.log; then
    printf 'Chưa thấy OUI yêu cầu chạy root.sh, xem log DB.\n'
    exit 1
fi
"$remote" rac1 "sudo $home/root.sh" | tee evidence/db-root.log
./scripts/create-db.sh
