#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p evidence
exec 9>state/add-node.lock
flock -n 9
exec > >(tee -a evidence/add-node.log) 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
test -s state/single-node-backup
remote=./scripts/guest-ssh.sh
grid=/u01/app/19c/grid
db=/u01/app/oracle/product/19c/dbhome_1
resume=${1:-}
case $resume in
    '') [[ $("$remote" rac1 "sudo $grid/bin/olsnodes") == rac1 ]] ;;
    --resume-after-grid)
        [[ $("$remote" rac1 "sudo $grid/bin/olsnodes" | sort) == $'rac1\nrac2' ]]
        "$remote" rac2 "sudo $grid/bin/crsctl check crs" | rg 'CRS-4537'
        ;;
    *) exit 2 ;;
esac
trap './scripts/nodeadd-network.sh disable' EXIT
./scripts/nodeadd-network.sh enable
if [[ -z $resume ]]; then
    for node in rac1 rac2; do
        "$remote" "$node" 'set -o pipefail; sudo -u grid dd if=/dev/rac-asm01 bs=4096 count=1 status=none | sha256sum' >"evidence/$node-asm-header.sha256"
    done
    cmp evidence/rac1-asm-header.sha256 evidence/rac2-asm-header.sha256
    "$remote" rac1 "sudo -iu grid $grid/bin/cluvfy stage -pre nodeadd -n rac2 -verbose" | tee evidence/nodeadd-cvu.log
    set +e
    "$remote" rac1 "sudo -iu grid env ORACLE_HOME=$grid $grid/addnode/addnode.sh -silent 'CLUSTER_NEW_NODES={rac2}' 'CLUSTER_NEW_VIRTUAL_HOSTNAMES={rac2-vip}'" | tee evidence/nodeadd-grid-oui.log
    oui_code=${PIPESTATUS[0]}
    set -e
    if (( oui_code != 0 && oui_code != 6 )); then exit "$oui_code"; fi
    rg -q '/root\.sh' evidence/nodeadd-grid-oui.log
    "$remote" rac2 "if sudo test -x /u01/app/oraInventory/orainstRoot.sh; then sudo /u01/app/oraInventory/orainstRoot.sh; fi; sudo $grid/root.sh"
fi
"$remote" rac1 "sudo $grid/bin/olsnodes -n -s; sudo -iu grid $grid/bin/cluvfy stage -post nodeadd -n rac2 -verbose" | tee evidence/nodeadd-post-cvu.log
set +e
"$remote" rac1 "sudo -iu oracle env ORACLE_HOME=$db $db/addnode/addnode.sh -silent 'CLUSTER_NEW_NODES={rac2}'" | tee evidence/nodeadd-db-home.log
oui_code=${PIPESTATUS[0]}
set -e
if (( oui_code != 0 && oui_code != 6 )); then exit "$oui_code"; fi
rg -q '/root\.sh' evidence/nodeadd-db-home.log
"$remote" rac2 "sudo $db/root.sh"
"$remote" rac1 "sudo -iu oracle env ORACLE_HOME=$db ORACLE_SID=RACLAB1 $db/bin/dbca -silent -addInstance -nodeName rac2 -gdbName RACLAB -instanceName RACLAB2" | tee evidence/nodeadd-dbca.log
"$remote" rac2 "sudo -iu oracle env ORACLE_HOME=$db ORACLE_SID=RACLAB2 $db/bin/sqlplus -s / as sysdba" <<'SQL'
whenever sqlerror exit failure
declare
    mode_now varchar2(12);
begin
    select open_mode into mode_now from v$pdbs where name = 'APPPDB';
    if mode_now = 'MOUNTED' then
        execute immediate 'alter pluggable database APPPDB open';
    end if;
end;
/
alter pluggable database APPPDB save state instances=all;
exit
SQL
"$remote" rac1 "sudo -iu oracle env ORACLE_HOME=$db $db/bin/srvctl modify service -db RACLAB -service racapp.rac.test -modifyconfig -preferred RACLAB1,RACLAB2 &&
    sudo -iu oracle env ORACLE_HOME=$db $db/bin/srvctl start service -db RACLAB -service racapp.rac.test -instance RACLAB2"
./scripts/cluster-status.sh rac1 | tee evidence/db-two-nodes.log
