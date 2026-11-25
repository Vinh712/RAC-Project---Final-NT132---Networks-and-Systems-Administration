#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p results evidence
exec 9>state/benchmark.lock
flock -n 9
suite="results/bench-$(TZ=Asia/Ho_Chi_Minh date +%Y%m%d-%H%M%S)"
mkdir "$suite"
exec > >(tee "$suite/run.log") 2>&1
db=/u01/app/oracle/product/19c/dbhome_1
remote=./scripts/guest-ssh.sh
service=racapp.rac.test
dbctl() {
    "$remote" rac1 "sudo -iu oracle env ORACLE_HOME=$db $db/bin/srvctl $*"
}
instance_status=$(dbctl status database -db RACLAB)
grep -qi 'Instance RACLAB1 is running' <<<"$instance_status"
grep -qi 'Instance RACLAB2 is running' <<<"$instance_status"
set_service_instances() {
    local preferred=$1
    local status
    status=$(dbctl status service -db RACLAB -service "$service")
    if [[ $status == *"is running on instance"* ]]; then
        dbctl stop service -db RACLAB -service "$service"
    fi
    dbctl modify service -db RACLAB -service "$service" -modifyconfig -preferred "$preferred"
    dbctl start service -db RACLAB -service "$service"
}
restore_service() {
    set_service_instances RACLAB1,RACLAB2
}
trap restore_service EXIT
for trial in 1 2 3; do
    # Đảo thứ tự lượt giữa để phân bố ảnh hưởng của thời điểm đo.
    modes=(one two)
    if (( trial == 2 )); then modes=(two one); fi
    for mode in "${modes[@]}"; do
        TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
        if [[ $mode == one ]]; then
            set_service_instances RACLAB1
        else
            restore_service
        fi
        dbctl status service -db RACLAB -service "$service"
        "$remote" rac1 "sudo -iu oracle env ORACLE_HOME=$db ORACLE_SID=RACLAB1 $db/bin/sqlplus -s / as sysdba" <<'SQL'
whenever sqlerror exit failure
alter session set container=APPPDB;
truncate table RACDATA.BENCH_REQUESTS;
exit
SQL
        .venv/bin/python client/benchmark.py --mode "$mode" --out "$suite/$mode-$trial"
    done
done
restore_service
trap - EXIT
.venv/bin/python client/benchmark_chart.py "$suite"
