#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
node=${1:-rac1}
case $node in rac1) sid=RACLAB1 ;; rac2) sid=RACLAB2 ;; *) exit 2 ;; esac
grid=/u01/app/19c/grid
home=/u01/app/oracle/product/19c/dbhome_1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
./scripts/guest-ssh.sh "$node" "set -e
    sudo $grid/bin/olsnodes -n -s
    sudo $grid/bin/crsctl status resource -t
    sudo -iu oracle env ORACLE_HOME=$home $home/bin/srvctl config database -db RACLAB
    sudo -iu oracle env ORACLE_HOME=$home $home/bin/srvctl status database -db RACLAB
    sudo -iu oracle env ORACLE_HOME=$home $home/bin/srvctl status service -db RACLAB -service racapp.rac.test
    sudo -iu oracle env ORACLE_HOME=$home ORACLE_SID=$sid $home/bin/sqlplus -s / as sysdba" <<'SQL'
whenever sqlerror exit failure
set pagesize 60 linesize 140
show parameter cluster_database
select inst_id, instance_name, host_name, status from gv$instance order by inst_id;
select inst_id, name, open_mode from gv$pdbs where name = 'APPPDB' order by inst_id;
exit
SQL
