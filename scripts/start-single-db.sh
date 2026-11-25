#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
remote=./scripts/guest-ssh.sh
grid=/u01/app/19c/grid
db=/u01/app/oracle/product/19c/dbhome_1
dbctl() {
    "$remote" rac1 "sudo -iu oracle env ORACLE_HOME=$db $db/bin/srvctl $*"
}
for i in $(seq 120); do
    if result=$(dbctl status database -db RACLAB 2>/dev/null) && "$remote" rac2 true; then break; fi
    sleep 3
done
"$remote" rac1 "sudo $grid/bin/crsctl check crs"
result=$(dbctl status database -db RACLAB)
if ! grep -qi 'Instance RACLAB1 is running' <<<"$result"; then
    dbctl start database -db RACLAB
fi
result=$(dbctl status service -db RACLAB -service racapp.rac.test)
if ! grep -qi '(s) RACLAB1' <<<"$result"; then
    dbctl start service -db RACLAB -service racapp.rac.test
fi
./scripts/cluster-status.sh rac1
