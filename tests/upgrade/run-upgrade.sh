#!/usr/bin/env bash
# =============================================================================
# tests/upgrade/run-upgrade.sh
# -----------------------------------------------------------------------------
# Upgrade-path validation (D-038, forward-only schema). For each prior release
# it installs the OLD artifact, seeds data, installs the CURRENT (working-tree)
# artifact over it, and asserts the upgrade is non-destructive:
#
#   * install-over succeeds (idempotent, D-038);
#   * SchemaVersion stays 0.4.0 before and after — i.e. NO persisted DDL
#     migration is required;
#   * pre-existing FR_* tables are all still present (none dropped);
#   * pre-existing rows survive (FR_Snapshot count does not shrink);
#   * every config key the current artifact seeds is present afterwards
#     (new keys added by the IF NOT EXISTS seed, none lost);
#   * Report still runs against the upgraded repository.
#
# Old artifacts come from git tags (extracted at their historical path). A
# version with no tag is reported UNAVAILABLE — never faked — and can be
# supplied manually as tests/upgrade/artifacts/v<version>.sql.
#
# Self-contained: one SQL Server container, one database per source version.
# Docker/local-dev and release-validation only (D-148); never runs on a user's
# server.
#
# Usage:  ./tests/upgrade/run-upgrade.sh [image]
# Exit:   0 = every AVAILABLE source upgraded cleanly (UNAVAILABLE does not
#         fail the run); 1 = an available upgrade failed a check.
# =============================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1

IMAGE="${1:-mcr.microsoft.com/mssql/server:2022-latest}"
SOURCES="0.4.0 0.4.1 0.4.2 0.4.3"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
CURRENT_SQL="${REPO_ROOT}/sp_SQLFlightRecorder.sql"
[ -n "$(command -v cygpath 2>/dev/null)" ] && CURRENT_HOST="$(cygpath -m "${CURRENT_SQL}")" || CURRENT_HOST="${CURRENT_SQL}"
# git needs a native path on Windows: MSYS_NO_PATHCONV=1 (set above so docker
# exec sees /tmp and /opt literally) also stops MSYS translating the /c/...
# argument to git.exe, which would then reject it. No-op on Linux/CI.
[ -n "$(command -v cygpath 2>/dev/null)" ] && GIT_ROOT="$(cygpath -m "${REPO_ROOT}")" || GIT_ROOT="${REPO_ROOT}"
PW='FlightRecorder!Upgrade'
C="fr-upgrade"
PASS=0; FAIL=0; UNAVAIL=0

# Preflight — fail loudly if a tool is missing, so a missing git/docker can
# never masquerade as "every source version is unavailable".
command -v git    >/dev/null 2>&1 || { echo "::error::git not found in PATH."; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "::error::docker not found in PATH."; exit 2; }
git -C "${GIT_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "::error::${REPO_ROOT} is not a git work tree (old artifacts come from tags)."; exit 2; }

docker rm -f "${C}" >/dev/null 2>&1 || true
trap 'docker rm -f "${C}" >/dev/null 2>&1 || true' EXIT

echo "Upgrade validation -> current artifact; image=${IMAGE}"
docker run -d --name "${C}" -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=${PW}" -e MSSQL_PID=Developer "${IMAGE}" >/dev/null
SQLTOOL=""; CFLAG=""
for _ in $(seq 1 40); do
  if docker exec "${C}" ls /opt/mssql-tools18/bin/sqlcmd >/dev/null 2>&1; then SQLTOOL=/opt/mssql-tools18/bin/sqlcmd; CFLAG="-C"; break
  elif docker exec "${C}" ls /opt/mssql-tools/bin/sqlcmd >/dev/null 2>&1; then SQLTOOL=/opt/mssql-tools/bin/sqlcmd; CFLAG=""; break; fi
  sleep 1
done
for _ in $(seq 1 60); do docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -Q "SELECT 1" -l 5 >/dev/null 2>&1 && break; sleep 2; done

master(){ docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -b -Q "$1"; }
db(){ local d="$1"; shift; docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -d "$d" -b "$@"; }
scalar(){ local d="$1"; shift; db "$d" -h -1 -W -Q "SET NOCOUNT ON; $1" | tr -d ' \r' | grep -E '^[-A-Za-z0-9._]+$' | head -1; }
assert(){ if [ "$2" = "$3" ]; then echo "    PASS  $1"; PASS=$((PASS+1)); else echo "    FAIL  $1 (got '$2', want '$3')"; FAIL=$((FAIL+1)); fi; }
assert_ge(){ if [ -n "$2" ] && [ -n "$3" ] && [ "$2" -ge "$3" ] 2>/dev/null; then echo "    PASS  $1 ($2 >= $3)"; PASS=$((PASS+1)); else echo "    FAIL  $1 ($2 not >= $3)"; FAIL=$((FAIL+1)); fi; }
config_keys(){ db "$1" -h -1 -W -Q "SET NOCOUNT ON; SELECT ConfigKey FROM dbo.FR_Config;" | tr -d '\r' | sed 's/[[:space:]]*$//' | grep -E '^[A-Za-z0-9_]+$' | sort -u; }

# Reference config-key set = what a FRESH install of the CURRENT artifact
# actually creates. This is the honest "current config keys" baseline: keys
# written only at agent-job creation (@CreateAgentJob=1) are absent from a plain
# install, so they are correctly not expected after a plain upgrade either.
master "IF DB_ID('FRUP_REF') IS NOT NULL BEGIN ALTER DATABASE FRUP_REF SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE FRUP_REF; END; CREATE DATABASE FRUP_REF;" >/dev/null
docker cp "${CURRENT_HOST}" "${C}:/tmp/current.sql" >/dev/null
db "FRUP_REF" -i /tmp/current.sql >/dev/null 2>&1
db "FRUP_REF" -Q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Install';" >/dev/null 2>&1
config_keys "FRUP_REF" > /tmp/ref_keys.txt
echo "Reference: a fresh current install seeds $(wc -l < /tmp/ref_keys.txt | tr -d ' ') config keys."

# Resolve an old artifact into $1 (out path). Echoes:
#   AVAILABLE    extracted from the tag (or a manual artifacts/ file)
#   UNAVAILABLE  no such tag and no manual artifact (honest skip)
#   ERROR        the tag exists but the artifact could not be extracted
resolve_old(){
  local v="$1" out="$2"; rm -f "${out}"
  if git -C "${GIT_ROOT}" rev-parse -q --verify "refs/tags/v${v}" >/dev/null 2>&1; then
    if git -C "${GIT_ROOT}" show "v${v}:sp_SQLFlightRecorder.sql"      > "${out}" 2>/dev/null && [ -s "${out}" ]; then echo AVAILABLE; return; fi
    if git -C "${GIT_ROOT}" show "v${v}:src/sp_SQLFlightRecorder.sql"  > "${out}" 2>/dev/null && [ -s "${out}" ]; then echo AVAILABLE; return; fi
    echo ERROR; return
  fi
  if [ -f "${SCRIPT_DIR}/artifacts/v${v}.sql" ]; then cp "${SCRIPT_DIR}/artifacts/v${v}.sql" "${out}"; echo AVAILABLE; return; fi
  echo UNAVAILABLE
}

for v in ${SOURCES}; do
  echo ""
  echo "== source v${v} =="
  OLD="/tmp/fr_old_${v}.sql"
  st=$(resolve_old "${v}" "${OLD}")
  if [ "${st}" = "UNAVAILABLE" ]; then
    echo "    UNAVAILABLE  no v${v} tag and no tests/upgrade/artifacts/v${v}.sql — pending historical artifact (not tested, not faked)."
    UNAVAIL=$((UNAVAIL+1)); continue
  elif [ "${st}" = "ERROR" ]; then
    echo "    ERROR  tag v${v} exists but sp_SQLFlightRecorder.sql could not be extracted from it."
    FAIL=$((FAIL+1)); continue
  fi
  DBN="FRUP_$(echo "${v}" | tr -d '.')"
  [ -n "$(command -v cygpath 2>/dev/null)" ] && OLD_HOST="$(cygpath -m "${OLD}")" || OLD_HOST="${OLD}"

  master "IF DB_ID('${DBN}') IS NOT NULL BEGIN ALTER DATABASE ${DBN} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ${DBN}; END; CREATE DATABASE ${DBN};" >/dev/null

  # Install OLD, seed data via a Collect (present in every release).
  docker cp "${OLD_HOST}" "${C}:/tmp/old.sql" >/dev/null
  db "${DBN}" -i /tmp/old.sql >/dev/null 2>&1
  db "${DBN}" -Q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Install';" >/dev/null 2>&1
  db "${DBN}" -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode=N'Collect';" >/dev/null 2>&1

  sv_pre=$(scalar "${DBN}" "SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey=N'SchemaVersion';")
  snap_pre=$(scalar "${DBN}" "SELECT COUNT(*) FROM dbo.FR_Snapshot;")
  tables_pre=$(scalar "${DBN}" "SELECT COUNT(*) FROM sys.tables WHERE name LIKE N'FR[_]%';")
  echo "    old installed: SchemaVersion=${sv_pre} FR_tables=${tables_pre} FR_Snapshot_rows=${snap_pre}"

  # Install CURRENT artifact OVER the old repository: run the file to update the
  # stored procedure, then Install to apply the current schema/seed in place.
  docker cp "${CURRENT_HOST}" "${C}:/tmp/current.sql" >/dev/null
  db "${DBN}" -i /tmp/current.sql >/dev/null 2>&1
  inst=$(db "${DBN}" -h -1 -W -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode=N'Install';" | tr -d '\r')
  echo "${inst}" | grep -q "Success" && instok="Success" || instok="NOT-Success"

  sv_post=$(scalar "${DBN}" "SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey=N'SchemaVersion';")
  snap_post=$(scalar "${DBN}" "SELECT COUNT(*) FROM dbo.FR_Snapshot;")
  tables_post=$(scalar "${DBN}" "SELECT COUNT(*) FROM sys.tables WHERE name LIKE N'FR[_]%';")

  # Report must run against the upgraded repository.
  rep=$(db "${DBN}" -h -1 -W -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode=N'Report';" | tr -d '\r')
  echo "${rep}" | grep -q "FR_R0026" && repok="ok" || repok="no-R0026"

  # Every config key a fresh current install has must be present after upgrade.
  config_keys "${DBN}" > /tmp/keys_post.txt
  comm -23 /tmp/ref_keys.txt /tmp/keys_post.txt | sed 's/^/    MISSING KEY after upgrade: /'
  missing=$(comm -23 /tmp/ref_keys.txt /tmp/keys_post.txt | grep -c . || true)

  echo "    upgraded: install=${instok} SchemaVersion=${sv_post} FR_tables=${tables_post} FR_Snapshot_rows=${snap_post} report=${repok} missing_keys=${missing}"
  assert    "v${v}: install-over succeeds"                 "${instok}"  "Success"
  assert    "v${v}: SchemaVersion stays 0.4.0 (no DDL migration)" "${sv_post}" "0.4.0"
  assert    "v${v}: SchemaVersion unchanged by upgrade"    "${sv_post}" "${sv_pre}"
  assert_ge "v${v}: FR_* tables not dropped"               "${tables_post}" "${tables_pre}"
  assert_ge "v${v}: FR_Snapshot rows preserved"            "${snap_post}"   "${snap_pre}"
  assert    "v${v}: Report runs on upgraded repo"          "${repok}"   "ok"
  assert    "v${v}: all current config keys present"       "${missing}" "0"
done

echo ""
echo "UPGRADE VALIDATION: ${PASS} passed, ${FAIL} failed, ${UNAVAIL} source(s) unavailable."
[ "${FAIL}" -eq 0 ]
