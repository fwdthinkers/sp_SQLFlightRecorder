#!/usr/bin/env bash
# =============================================================================
# scripts/run-local-tier1.sh
# -----------------------------------------------------------------------------
# Local mirror of .github/workflows/ci-tier1.yml. Lets a contributor run the
# same Tier 1 checks on their machine using Docker, so a PR rarely fails CI
# for reasons the contributor could not have caught locally (D-187:
# recommended-but-not-required local tooling).
#
# Per D-148 this is build-pipeline / local-dev only. Nothing this script
# does ever touches a user's SQL Server.
#
# What it does:
#   1. Runs the static-analysis linter (and its self-test).
#   2. For each target image in TARGETS (D-120: 2017/2019/2022/2025):
#      a. Starts an mssql container (no host port; sqlcmd runs via docker
#         exec — mssql-tools18 with -C when present, mssql-tools otherwise).
#      b. Waits for it to accept connections.
#      c. Creates a disposable FRTest database.
#      d. Installs sp_SQLFlightRecorder.sql (repo root) twice (idempotency).
#      e. Smokes Help / About / Version / unknown-mode / out-of-range.
#      f. Lifecycle: Install → Collect ×2 → Report → Purge @WhatIf →
#         Uninstall → asserts zero FR_* objects remain.
#      g. Drops the procedure and tears down the container.
#
# The expected tool version is parsed from the file header (Tool-Version:)
# so version bumps cannot silently diverge from the checks.
#
# Requirements:
#   - bash 4+
#   - docker (Linux containers)
#
# Usage:
#   ./scripts/run-local-tier1.sh                  # full matrix
#   ./scripts/run-local-tier1.sh --only 2022      # one target by tag substring
#   ./scripts/run-local-tier1.sh --skip-lint      # skip static-analysis step
#
# Exit code: 0 on success; non-zero on the first failing target.
# =============================================================================

set -euo pipefail
export MSYS_NO_PATHCONV=1   # keep Git Bash on Windows from mangling /opt paths

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
SQL_FILE="${REPO_ROOT}/sp_SQLFlightRecorder.sql"
LINT_SCRIPT="${SCRIPT_DIR}/run-static-analysis.sh"

# Tier 1 targets (D-120).
TARGETS=(
  "2017|mcr.microsoft.com/mssql/server:2017-latest"
  "2019|mcr.microsoft.com/mssql/server:2019-latest"
  "2022|mcr.microsoft.com/mssql/server:2022-latest"
  "2025|mcr.microsoft.com/mssql/server:2025-latest"
)

SA_PASSWORD="${SA_PASSWORD:-FlightRecorder!Tier1}"
MSSQL_PID="${MSSQL_PID:-Developer}"
CONTAINER_NAME="${CONTAINER_NAME:-fr-tier1-local}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"

ONLY=""
SKIP_LINT="0"

usage() {
    sed -n '2,44p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)        ONLY="${2:-}"; shift 2 ;;
        --skip-lint)   SKIP_LINT="1"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "::error::Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# --- Preflight ---------------------------------------------------------------

if [[ ! -f "${SQL_FILE}" ]]; then
    echo "::error::SQL file not found: ${SQL_FILE}" >&2
    exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "::error::docker is required. Install Docker Desktop or the engine and re-run." >&2
    exit 2
fi

EXPECTED_VERSION="$(grep -m1 -E '^-- Tool-Version:' "${SQL_FILE}" | awk '{print $3}')"
if [[ -z "${EXPECTED_VERSION}" ]]; then
    echo "::error::Could not parse Tool-Version from ${SQL_FILE} header." >&2
    exit 2
fi
echo "Expected tool version: ${EXPECTED_VERSION}"

# --- Helpers -----------------------------------------------------------------

SQLTOOL=""
CFLAG=""

cleanup_container() {
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}

trap cleanup_container EXIT

sqx() {
    # $1 = database, remaining args passed to sqlcmd (runs inside container)
    local db="$1"; shift
    docker exec "${CONTAINER_NAME}" "${SQLTOOL}" ${CFLAG} \
        -S localhost -U sa -P "${SA_PASSWORD}" -b -d "${db}" "$@"
}

detect_sqlcmd() {
    SQLTOOL=""; CFLAG=""
    for _ in $(seq 1 30); do
        if docker exec "${CONTAINER_NAME}" ls /opt/mssql-tools18/bin/sqlcmd >/dev/null 2>&1; then
            SQLTOOL="/opt/mssql-tools18/bin/sqlcmd"; CFLAG="-C"; return 0
        elif docker exec "${CONTAINER_NAME}" ls /opt/mssql-tools/bin/sqlcmd >/dev/null 2>&1; then
            SQLTOOL="/opt/mssql-tools/bin/sqlcmd"; CFLAG=""; return 0
        fi
        sleep 1
    done
    echo "::error::No sqlcmd found inside the container." >&2
    return 1
}

wait_for_ready() {
    echo "  waiting for SQL Server to accept connections..."
    local attempts=$(( WAIT_SECONDS / 2 ))
    for ((i=1; i<=attempts; i++)); do
        if sqx master -Q "SELECT 1;" -l 5 >/dev/null 2>&1; then
            echo "  ready after ${i} attempt(s)."
            return 0
        fi
        sleep 2
    done
    echo "::error::SQL Server did not become ready within ${WAIT_SECONDS}s." >&2
    docker logs "${CONTAINER_NAME}" >&2 || true
    return 1
}

run_target() {
    local tag="$1"
    local image="$2"

    echo ""
    echo "============================================================"
    echo "Tier 1 — SQL Server ${tag}"
    echo "Image: ${image}"
    echo "============================================================"

    cleanup_container

    docker run -d \
        --name "${CONTAINER_NAME}" \
        -e "ACCEPT_EULA=Y" \
        -e "MSSQL_SA_PASSWORD=${SA_PASSWORD}" \
        -e "MSSQL_PID=${MSSQL_PID}" \
        "${image}" >/dev/null

    detect_sqlcmd
    echo "  sqlcmd: ${SQLTOOL} ${CFLAG}"
    wait_for_ready

    echo "  creating disposable FRTest database..."
    sqx master -Q \
        "IF DB_ID('FRTest') IS NOT NULL DROP DATABASE FRTest; CREATE DATABASE FRTest;" >/dev/null

    echo "  installing procedure (first run)..."
    docker cp "${SQL_FILE}" "${CONTAINER_NAME}:/tmp/sp_SQLFlightRecorder.sql" >/dev/null
    sqx FRTest -i /tmp/sp_SQLFlightRecorder.sql >/dev/null

    echo "  installing procedure (re-run for idempotency)..."
    sqx FRTest -i /tmp/sp_SQLFlightRecorder.sql >/dev/null

    echo "  smoke — Help mode"
    sqx FRTest -Q "EXEC dbo.sp_SQLFlightRecorder;" > /tmp/fr-help.out
    grep -q "sp_SQLFlightRecorder"    /tmp/fr-help.out
    grep -q "CHARTER PILLARS"         /tmp/fr-help.out
    grep -q "MODES"                   /tmp/fr-help.out
    grep -q "PARAMETERS"              /tmp/fr-help.out
    grep -q "${EXPECTED_VERSION}"     /tmp/fr-help.out

    echo "  smoke — About mode + Version alias"
    sqx FRTest -h -1 -W \
        -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';" > /tmp/fr-about.out
    grep -q "${EXPECTED_VERSION}" /tmp/fr-about.out
    sqx FRTest -h -1 -W \
        -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode = N'Version';" > /tmp/fr-version.out
    grep -q "${EXPECTED_VERSION}" /tmp/fr-version.out

    echo "  smoke — validation errors return clean results"
    sqx FRTest -h -1 -W \
        -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode = N'BogusMode';" > /tmp/fr-bogus.out
    grep -q "UnknownMode" /tmp/fr-bogus.out
    sqx FRTest -h -1 -W \
        -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @MaxFindings = 5;" > /tmp/fr-maxf.out
    grep -q "InvalidMaxFindings" /tmp/fr-maxf.out

    echo "  lifecycle — Install"
    sqx FRTest -W -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';" > /tmp/fr-install.out
    grep -q "Success" /tmp/fr-install.out

    echo "  lifecycle — Collect ×2 (no collector errors)"
    sqx FRTest -W -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';" > /tmp/fr-collect1.out
    grep -Eq "Success|PartialSuccess" /tmp/fr-collect1.out
    sleep 3
    sqx FRTest -W -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';" > /tmp/fr-collect2.out
    grep -Eq "Success|PartialSuccess" /tmp/fr-collect2.out
    sqx FRTest -h -1 -W \
        -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.FR_RunLogStep WHERE Status = N'Error';" > /tmp/fr-errsteps.out
    grep -Eq "^\s*0\s*$" /tmp/fr-errsteps.out

    echo "  lifecycle — Report (Default + Markdown)"
    sqx FRTest -W -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';" > /tmp/fr-report.out
    grep -q "FR_R0026" /tmp/fr-report.out
    sqx FRTest -y 0 -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report', @OutputFormat = N'Markdown';" > /tmp/fr-md.out
    grep -q "# SQL Server Flight Recorder Report" /tmp/fr-md.out

    echo "  lifecycle — Purge @WhatIf"
    sqx FRTest -W -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 1;" > /tmp/fr-purgewi.out
    grep -q "WhatIf" /tmp/fr-purgewi.out

    echo "  lifecycle — Uninstall leaves zero FR_* objects"
    sqx FRTest -W -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';" > /tmp/fr-uninstall.out
    grep -q "Success" /tmp/fr-uninstall.out
    sqx FRTest -h -1 -W \
        -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.objects WHERE name LIKE N'FR[_]%';" > /tmp/fr-leftover.out
    grep -Eq "^\s*0\s*$" /tmp/fr-leftover.out

    echo "  clean removal — DROP PROCEDURE"
    sqx FRTest -Q "DROP PROCEDURE dbo.sp_SQLFlightRecorder;" >/dev/null

    cleanup_container
    echo "  PASSED — SQL Server ${tag}"
}

# --- Main --------------------------------------------------------------------

if [[ "${SKIP_LINT}" != "1" ]]; then
    if [[ -x "${LINT_SCRIPT}" || -f "${LINT_SCRIPT}" ]]; then
        echo "==> Static analysis"
        bash "${LINT_SCRIPT}"
    else
        echo "::warning::run-static-analysis.sh not found; skipping linter."
    fi
fi

ran_any=0
for entry in "${TARGETS[@]}"; do
    tag="${entry%%|*}"
    image="${entry##*|}"
    if [[ -n "${ONLY}" && "${tag}" != *"${ONLY}"* ]]; then
        continue
    fi
    run_target "${tag}" "${image}"
    ran_any=1
done

if [[ "${ran_any}" -eq 0 ]]; then
    echo "::error::No targets matched --only '${ONLY}'." >&2
    exit 2
fi

echo ""
echo "All Tier 1 targets passed."
