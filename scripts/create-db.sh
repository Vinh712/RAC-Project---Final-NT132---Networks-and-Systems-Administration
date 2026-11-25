#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077
mkdir -p evidence
exec 9>state/create-db.lock
flock -n 9
exec > >(tee -a evidence/create-db.log) 2>&1
TZ=Asia/Ho_Chi_Minh date --iso-8601=seconds
remote=./scripts/guest-ssh.sh
grid=/u01/app/19c/grid
home=/u01/app/oracle/product/19c/dbhome_1
python3 - <<'PY' |
import json
from pathlib import Path
from secrets import token_hex

template = Path("oracle/dbca.properties.in").read_text()
secrets_path = Path("state/oracle-secrets.json")
values = json.loads(secrets_path.read_text())
if "DBSNMP" not in values:
    values["DBSNMP"] = "Rx9" + token_hex(12)
    pending = secrets_path.with_suffix(".tmp")
    pending.write_text(json.dumps(values))
    pending.replace(secrets_path)
for key, value in values.items():
    template = template.replace(f"@{key}@", value)
print(template, end="")
PY
"$remote" rac1 "sudo -iu oracle bash -c 'umask 077; cat > /home/oracle/rac-dbca.rsp'"
"$remote" rac1 "sudo -iu oracle env ORACLE_HOME=$home $home/bin/dbca -silent -createDatabase -responseFile /home/oracle/rac-dbca.rsp" | tee evidence/dbca-create.log
python3 - <<'PY' |
import json
from pathlib import Path

template = Path("oracle/schema.sql.in").read_text()
password = json.loads(Path("state/oracle-secrets.json").read_text())["RACAPP"]
print(template.replace("@RACAPP@", password), end="")
PY
"$remote" rac1 "sudo -iu oracle env ORACLE_HOME=$home ORACLE_SID=RACLAB1 $home/bin/sqlplus -s / as sysdba" |
python3 -u -c 'import json,sys; from pathlib import Path; secret=json.loads(Path("state/oracle-secrets.json").read_text())["RACAPP"]; [sys.stdout.write(line.replace(secret, "<ẩn>")) for line in sys.stdin]'
"$remote" rac1 "sudo -iu oracle env ORACLE_HOME=$home $home/bin/srvctl add service -db RACLAB -service racapp.rac.test -pdb APPPDB -preferred RACLAB1 &&
    sudo -iu oracle env ORACLE_HOME=$home $home/bin/srvctl start service -db RACLAB -service racapp.rac.test"
./scripts/cluster-status.sh rac1 | tee evidence/db-single-node.log
