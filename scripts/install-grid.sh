#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p evidence state
exec 9>state/install-grid.lock
flock -n 9
exec > >(tee -a evidence/install-grid.log) 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
remote=./scripts/guest-ssh.sh
home=/u01/app/19c/grid
inventory=/u01/app/oraInventory
"$remote" rac1 "sudo -iu grid test -x $home/gridSetup.sh; rpm -q cvuqdisk"
if [[ ! -f state/oracle-secrets.json ]]; then
    python3 - <<'PY'
import json
import secrets

with open("state/oracle-secrets.json", "x") as output:
    keys = ("SYSASM", "ASMSNMP", "SYS", "SYSTEM", "PDBADMIN", "RACAPP")
    json.dump({key: "Rx9" + secrets.token_hex(12) for key in keys}, output)
PY
fi
public_if=$("$remote" rac1 '/sbin/ip -o -4 addr show to 192.168.191.11/32' | awk '{print $2}')
private_if=$("$remote" rac1 '/sbin/ip -o -4 addr show to 192.168.192.11/32' | awk '{print $2}')
[[ $public_if =~ ^[a-zA-Z0-9_-]+$ && $private_if =~ ^[a-zA-Z0-9_-]+$ && $public_if != "$private_if" ]]
python3 - "$public_if" "$private_if" <<'PY' |
import json
import sys
from pathlib import Path

values = json.loads(Path("state/oracle-secrets.json").read_text())
values.update(PUBLIC_IF=sys.argv[1], PRIVATE_IF=sys.argv[2])
template = Path("oracle/grid.properties.in").read_text()
for key, value in values.items():
    template = template.replace(f"@{key}@", value)
print(template, end="")
PY
"$remote" rac1 "sudo -iu grid bash -c 'umask 077; cat > /home/grid/rac-grid.rsp'"
"$remote" rac1 "sudo -iu grid $home/runcluvfy.sh stage -pre crsinst -n rac1 -r 19 -orainv oinstall -osdba asmdba -osoper asmoper -asm -presence flex -asmgrp asmadmin -asmdev /dev/rac-asm01 -crshome $home -networks $public_if:192.168.191.0:PUBLIC/$private_if:192.168.192.0:CLUSTER_INTERCONNECT,ASM -verbose" | tee evidence/grid-cvu-pre.log
set +e
"$remote" rac1 "sudo -iu grid $home/gridSetup.sh -silent -responseFile /home/grid/rac-grid.rsp" | tee evidence/grid-oui.log
oui_code=${PIPESTATUS[0]}
set -e
printf 'Grid OUI exit=%s\n' "$oui_code"
if (( oui_code != 0 && oui_code != 6 )); then
    exit "$oui_code"
fi
if ! rg -q '/root\.sh' evidence/grid-oui.log; then
    printf 'Chưa thấy OUI yêu cầu chạy root.sh, xem log Grid.\n'
    exit 1
fi
"$remote" rac1 "if sudo test -x $inventory/orainstRoot.sh; then sudo $inventory/orainstRoot.sh; fi; sudo $home/root.sh" | tee evidence/grid-root.log
"$remote" rac1 "sudo -iu grid $home/gridSetup.sh -silent -executeConfigTools -responseFile /home/grid/rac-grid.rsp" | tee evidence/grid-config-tools.log
"$remote" rac1 "sudo $home/bin/olsnodes -n -s; sudo $home/bin/crsctl stat res -t; sudo $home/bin/crsctl query css votedisk; sudo -iu grid env ORACLE_HOME=$home ORACLE_SID=+ASM1 $home/bin/asmcmd lsdg" | tee evidence/grid-single-node.log
