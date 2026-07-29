#!/usr/bin/env bash
# =============================================================================
# tests/perf/run-cost-regression.sh
# -----------------------------------------------------------------------------
# Cost-regression harness (D-143): a bounded workload + repeated Collect, with
# two checks:
#   * HARD  — no single Collect may exceed the 10 s ceiling (D-143). Stable
#             across runners, so this is always enforced.
#   * SOFT  — mean Collect time vs an optional committed baseline
#             (tests/perf/baseline-collect-ms.txt); a >2% slowdown is reported.
#             Hosted runners are noisy, so this only fails the run under
#             --strict (intended for dedicated/stable infra). Per D-143 the
#             strict >2% check becomes a PR gate at GA once thresholds are
#             calibrated; for v1.0.0-rc it runs out-of-band and non-blocking.
#
# Self-contained (starts/stops its own SQL Server container). Docker/local-dev
# and out-of-band CI only (D-148); never runs on a user's server.
#
# Usage:  ./tests/perf/run-cost-regression.sh [image] [iterations] [--strict]
#   image        default mcr.microsoft.com/mssql/server:2022-latest
#   iterations   timed Collect runs after a warm-up (default 20)
#   --strict     fail the run on a >2% mean slowdown vs the baseline
#
# Exit: 0 pass; 1 a Collect breached the ceiling (or --strict regression).
# =============================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1

IMAGE="mcr.microsoft.com/mssql/server:2022-latest"
ITERS=20
STRICT=0
for a in "$@"; do
  case "$a" in
    --strict) STRICT=1 ;;
    [0-9]*)   ITERS="$a" ;;
    *)        IMAGE="$a" ;;
  esac
done

CEILING_MS=10000                       # D-143 absolute per-Collect ceiling
REGRESSION_PCT=2                        # D-143 throughput-drop threshold
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
SQL_FILE="${REPO_ROOT}/sp_SQLFlightRecorder.sql"
[ -n "$(command -v cygpath 2>/dev/null)" ] && SQL_FILE_HOST="$(cygpath -m "${SQL_FILE}")" || SQL_FILE_HOST="${SQL_FILE}"
BASELINE_FILE="${SCRIPT_DIR}/baseline-collect-ms.txt"
PW='FlightRecorder!Cost'
C="fr-cost"

docker rm -f "${C}" >/dev/null 2>&1 || true
trap 'docker rm -f "${C}" >/dev/null 2>&1 || true' EXIT

echo "Cost-regression: image=${IMAGE} iterations=${ITERS} strict=${STRICT}"
docker run -d --name "${C}" -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=${PW}" -e MSSQL_PID=Developer "${IMAGE}" >/dev/null
SQLTOOL=""; CFLAG=""
for _ in $(seq 1 40); do
  if docker exec "${C}" ls /opt/mssql-tools18/bin/sqlcmd >/dev/null 2>&1; then SQLTOOL=/opt/mssql-tools18/bin/sqlcmd; CFLAG="-C"; break
  elif docker exec "${C}" ls /opt/mssql-tools/bin/sqlcmd >/dev/null 2>&1; then SQLTOOL=/opt/mssql-tools/bin/sqlcmd; CFLAG=""; break; fi
  sleep 1
done
for _ in $(seq 1 60); do docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -Q "SELECT 1" -l 5 >/dev/null 2>&1 && break; sleep 2; done

q(){ docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -d FRTest -b "$@"; }
docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -b -Q "IF DB_ID('FRTest') IS NULL CREATE DATABASE FRTest;" >/dev/null
docker cp "${SQL_FILE_HOST}" "${C}:/tmp/fr.sql" >/dev/null
q -i /tmp/fr.sql >/dev/null 2>&1
q -Q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Install';" >/dev/null
# Seed a bounded, representative workload so Collect has real DMV rows to read.
q -Q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'InstallDemoData';" >/dev/null

collect_once(){ q -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode=N'Collect';" >/dev/null 2>&1; }

collect_once   # warm-up (JIT/plan compile) not counted

total=0; max=0; fail=0
for i in $(seq 1 "${ITERS}"); do
  start=$(date +%s%3N); collect_once; end=$(date +%s%3N)
  ms=$((end - start))
  total=$((total + ms)); [ "${ms}" -gt "${max}" ] && max=${ms}
  if [ "${ms}" -gt "${CEILING_MS}" ]; then
    echo "  CEILING BREACH  iteration ${i}: ${ms} ms > ${CEILING_MS} ms"; fail=1
  fi
done
mean=$((total / ITERS))
echo "Collect timing over ${ITERS} runs: mean=${mean} ms  max=${max} ms  (ceiling ${CEILING_MS} ms)"

if [ -f "${BASELINE_FILE}" ]; then
  base=$(tr -dc '0-9' < "${BASELINE_FILE}")
  if [ -n "${base}" ] && [ "${base}" -gt 0 ]; then
    allowed=$(( base + (base * REGRESSION_PCT / 100) ))
    echo "Baseline mean=${base} ms; ${REGRESSION_PCT}% budget => ${allowed} ms"
    if [ "${mean}" -gt "${allowed}" ]; then
      echo "  REGRESSION  mean ${mean} ms exceeds baseline+${REGRESSION_PCT}% (${allowed} ms)"
      [ "${STRICT}" -eq 1 ] && fail=1 || echo "  (advisory only; pass --strict on stable infra to enforce — D-143 GA gate)"
    fi
  fi
else
  echo "No baseline file; write ${mean} to tests/perf/baseline-collect-ms.txt on trusted infra to arm the ${REGRESSION_PCT}% check."
fi

echo ""
if [ "${fail}" -eq 0 ]; then echo "COST-REGRESSION: PASS"; else echo "COST-REGRESSION: FAIL"; fi
[ "${fail}" -eq 0 ]
