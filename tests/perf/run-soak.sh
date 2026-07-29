#!/usr/bin/env bash
# =============================================================================
# tests/perf/run-soak.sh
# -----------------------------------------------------------------------------
# Soak harness (D-145): drive many Collect cycles and assert the tool stays
# healthy under sustained use — the drift that per-PR tests miss. Checks:
#   * no FR_RunLogStep rows ever land in Status='Error' (collector isolation
#     holds cycle after cycle, D-009);
#   * Report stays under the 5 s ceiling throughout;
#   * Purge keeps repo growth bounded — every few cycles half the snapshots are
#     backdated past retention and Purge must reap them (children before
#     parents, D-141), so row count returns to the live-window size.
#
# D-145 specifies a 24 h out-of-band soak; a full day exceeds a hosted runner's
# job limit, so CI runs a scaled proxy (default 60 cycles) nightly and the full
# 24 h soak is run out-of-band on dedicated infra before a release. Failures are
# handled in release planning (D-145), so this is non-blocking.
#
# Self-contained container. Docker/local-dev and out-of-band CI only (D-148).
#
# Usage:  ./tests/perf/run-soak.sh [image] [cycles]
# Exit:   0 pass; 1 an error step appeared, Report breached 5 s, or Purge did
#         not keep up.
# =============================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1

IMAGE="${1:-mcr.microsoft.com/mssql/server:2022-latest}"
CYCLES="${2:-60}"
REPORT_CEILING_MS=5000
PURGE_EVERY=10

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
SQL_FILE="${REPO_ROOT}/sp_SQLFlightRecorder.sql"
[ -n "$(command -v cygpath 2>/dev/null)" ] && SQL_FILE_HOST="$(cygpath -m "${SQL_FILE}")" || SQL_FILE_HOST="${SQL_FILE}"
PW='FlightRecorder!Soak'
C="fr-soak"
fail=0

docker rm -f "${C}" >/dev/null 2>&1 || true
trap 'docker rm -f "${C}" >/dev/null 2>&1 || true' EXIT

echo "Soak: image=${IMAGE} cycles=${CYCLES} (purge every ${PURGE_EVERY}, Report ceiling ${REPORT_CEILING_MS} ms)"
docker run -d --name "${C}" -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=${PW}" -e MSSQL_PID=Developer "${IMAGE}" >/dev/null
SQLTOOL=""; CFLAG=""
for _ in $(seq 1 40); do
  if docker exec "${C}" ls /opt/mssql-tools18/bin/sqlcmd >/dev/null 2>&1; then SQLTOOL=/opt/mssql-tools18/bin/sqlcmd; CFLAG="-C"; break
  elif docker exec "${C}" ls /opt/mssql-tools/bin/sqlcmd >/dev/null 2>&1; then SQLTOOL=/opt/mssql-tools/bin/sqlcmd; CFLAG=""; break; fi
  sleep 1
done
for _ in $(seq 1 60); do docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -Q "SELECT 1" -l 5 >/dev/null 2>&1 && break; sleep 2; done

q(){ docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -d FRTest -b "$@"; }
scalar(){ q -h -1 -W -Q "SET NOCOUNT ON; $1" | tr -d ' \r' | grep -E '^[0-9]+$' | head -1; }

docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -b -Q "IF DB_ID('FRTest') IS NULL CREATE DATABASE FRTest;" >/dev/null
docker cp "${SQL_FILE_HOST}" "${C}:/tmp/fr.sql" >/dev/null
q -i /tmp/fr.sql >/dev/null 2>&1
q -Q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Install';" >/dev/null
# Retention of 1 day makes backdated snapshots purge-eligible within the soak.
q -Q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Configure', @ConfigKey=N'SnapshotRetentionDays', @ConfigValue=N'1';" >/dev/null

report_max_ms=0
for i in $(seq 1 "${CYCLES}"); do
  q -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode=N'Collect';" >/dev/null 2>&1

  if [ $(( i % PURGE_EVERY )) -eq 0 ]; then
    before=$(scalar "SELECT COUNT(*) FROM dbo.FR_Snapshot;")
    q -Q "UPDATE dbo.FR_Snapshot SET SnapshotUtc = DATEADD(day,-10,SnapshotUtc) WHERE SnapshotId % 2 = 0;" >/dev/null 2>&1
    q -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode=N'Purge';" >/dev/null 2>&1
    after=$(scalar "SELECT COUNT(*) FROM dbo.FR_Snapshot;")
    echo "  cycle ${i}: snapshots ${before} -> ${after} after backdate+purge"
    if [ -n "${before}" ] && [ -n "${after}" ] && [ "${after}" -ge "${before}" ] && [ "${before}" -gt 1 ]; then
      echo "    PURGE DID NOT KEEP UP (expected a drop)"; fail=1
    fi

    # Time a Report while the repo is at its fullest.
    start=$(date +%s%3N)
    q -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode=N'Report';" >/dev/null 2>&1
    end=$(date +%s%3N); rms=$((end - start))
    [ "${rms}" -gt "${report_max_ms}" ] && report_max_ms=${rms}
    if [ "${rms}" -gt "${REPORT_CEILING_MS}" ]; then
      echo "    REPORT BREACH cycle ${i}: ${rms} ms > ${REPORT_CEILING_MS} ms"; fail=1
    fi
  fi
done

errsteps=$(scalar "SELECT COUNT(*) FROM dbo.FR_RunLogStep WHERE Status=N'Error';")
final=$(scalar "SELECT COUNT(*) FROM dbo.FR_Snapshot;")
echo ""
echo "Soak summary: ${CYCLES} cycles, error-steps=${errsteps:-?}, final snapshots=${final:-?}, Report max=${report_max_ms} ms"
if [ -z "${errsteps}" ] || [ "${errsteps}" -ne 0 ]; then echo "  ERROR STEPS PRESENT (${errsteps:-unknown})"; fail=1; fi

if [ "${fail}" -eq 0 ]; then echo "SOAK: PASS"; else echo "SOAK: FAIL"; fi
[ "${fail}" -eq 0 ]
