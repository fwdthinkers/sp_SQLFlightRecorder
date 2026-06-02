#!/usr/bin/env bash
# =============================================================================
# scripts/run-local-tier1.sh
# -----------------------------------------------------------------------------
# Part 2 of 9 (v0.1 Design Prototype).
#
# Local mirror of .github/workflows/ci-tier1.yml. Lets a contributor run the
# same Tier 1 smoke tests on their laptop using Docker, so a PR rarely fails
# CI for reasons the contributor could not have caught locally (D-187:
# recommended-but-not-required local tooling).
#
# Per D-148 this is build-pipeline / local-dev only. Nothing this script
# does ever touches a user's SQL Server.
#
# What it does:
#   1. Runs the static-analysis linter (and its self-test).
#   2. For each target image in TARGETS:
#      a. Starts an mssql container on host port 1433.
#      b. Waits for it to accept connections.
#      c. Creates a disposable FRTest database.
#      d. Installs src/sp_SQLFlightRecorder.sql twice (idempotency check).
#      e. Smokes Help / About / Version / unknown-mode / out-of-range /
#         not-yet-implemented dispatch.
#      f. Drops the procedure.
#      g. Tears down the container.
#
# Requirements:
#   - bash 4+
#   - docker (Linux containers)
#   - Ability to publish port 1433 on the host
#
# Usage:
#   ./scripts/run-local-tier1.sh                  # full matrix
#   ./scripts/run-local-tier1.sh --only 2022      # one target by tag substring
#   ./scripts/run-local-tier1.sh --skip-lint      # skip static-analysis step
#
# Exit code: 0 on success; non-zero on the first failing target.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
SQL_FILE="${REPO_ROOT}/src/sp_SQLFlightRecorder.sql"
LINT_SCRIPT="${SCRIPT_DIR}/run-static-analysis.sh"

# Tier 1 v0.1 Part 2 targets (D-120). 2017 added in Part 5; 2025 in Part 8.
TARGETS=(
  "2019|mcr.microsoft.com/mssql/server:2019-latest"
  "2022|mcr.microsoft.com/mssql/server:2022-latest"
)

SA_PASSWORD="${SA_PASSWORD:-FlightRecorder!Tier1}"
MSSQL_PID="${MSSQL_PID:-Developer}"
CONTAINER_NAME="${CONTAINER_NAME:-fr-tier1-local}"
HOST_PORT="${HOST_PORT:-1433}"
SQLCMD_IMAGE="${SQLCMD_IMAGE:-mcr.microsoft.com/mssql-tools}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

ONLY=""
SKIP_LINT="0"

usage() {
    sed -n '2,40p' "$0"
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

# --- Helpers -----------------------------------------------------------------

cleanup_container() {
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}

# Trap to ensure no container is left running on Ctrl-C or error.
trap cleanup_container EXIT

sqlcmd_in_container() {
    # $1 = database, remaining args = passed to sqlcmd
    local db="$1"; shift
    docker exec "${CONTAINER_NAME}" /opt/mssql-tools/bin/sqlcmd \
        -S localhost -U sa -P "${SA_PASSWORD}" -b -d "${db}" "$@"
}

sqlcmd_host_to_container() {
    # Runs an sqlcmd in a side container talking to the host-published port.
    # Used only by the readiness probe (before sqlcmd is guaranteed to exist
    # inside the server container).
    docker run --rm --network host "${SQLCMD_IMAGE}" \
        /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" "$@"
}

wait_for_ready() {
    echo "  waiting for SQL Server to accept connections..."
    local attempts=$(( WAIT_SECONDS / 2 ))
    for ((i=1; i<=attempts; i++)); do
        if sqlcmd_host_to_container -Q "SELECT 1;" -l 5 >/dev/null 2>&1; then
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
        -p "${HOST_PORT}:1433" \
        "${image}" >/dev/null

    wait_for_ready

    echo "  creating disposable FRTest database..."
    sqlcmd_in_container "master" -Q \
        "IF DB_ID('FRTest') IS NOT NULL DROP DATABASE FRTest; CREATE DATABASE FRTest;" >/dev/null

    echo "  installing procedure (first run)..."
    docker cp "${SQL_FILE}" "${CONTAINER_NAME}:/tmp/sp_SQLFlightRecorder.sql" >/dev/null
    sqlcmd_in_container "FRTest" -i /tmp/sp_SQLFlightRecorder.sql >/dev/null

    echo "  installing procedure (re-run for idempotency)..."
    sqlcmd_in_container "FRTest" -i /tmp/sp_SQLFlightRecorder.sql >/dev/null

    echo "  smoke — Help mode"
    sqlcmd_in_container "FRTest" -Q "EXEC dbo.sp_SQLFlightRecorder;" > /tmp/help.out
    grep -q "sp_SQLFlightRecorder" /tmp/help.out
    grep -q "CHARTER PILLARS"      /tmp/help.out
    grep -q "MODES"                /tmp/help.out
    grep -q "PARAMETERS"           /tmp/help.out

    echo "  smoke — About mode"
    sqlcmd_in_container "FRTest" -h -1 -W \
        -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';" \
        > /tmp/about.out
    grep -q "0.1.0-alpha.1" /tmp/about.out

    echo "  smoke — Version alias"
    sqlcmd_in_container "FRTest" -h -1 -W \
        -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode = N'Version';" \
        > /tmp/version.out
    grep -q "0.1.0-alpha.1" /tmp/version.out

    echo "  smoke — unknown mode returns Error result"
    sqlcmd_in_container "FRTest" -h -1 -W \
        -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode = N'BogusMode';" \
        > /tmp/bogus.out
    grep -q "Unknown @Mode" /tmp/bogus.out

    echo "  smoke — out-of-range @MaxFindings returns Error"
    sqlcmd_in_container "FRTest" -h -1 -W \
        -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @MaxFindings = 5;" \
        > /tmp/maxf.out
    grep -q "Invalid @MaxFindings" /tmp/maxf.out

    echo "  smoke — NotYetImplemented dispatch (Collect)"
    sqlcmd_in_container "FRTest" -h -1 -W \
        -Q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';" \
        > /tmp/collect.out
    grep -q "NotYetImplemented" /tmp/collect.out

    echo "  clean removal — DROP PROCEDURE"
    sqlcmd_in_container "FRTest" -Q "DROP PROCEDURE dbo.sp_SQLFlightRecorder;" >/dev/null

    cleanup_container
    echo "  PASSED — SQL Server ${tag}"
}

# --- Main --------------------------------------------------------------------

if [[ "${SKIP_LINT}" != "1" ]]; then
    if [[ -x "${LINT_SCRIPT}" ]]; then
        echo "==> Static analysis"
        "${LINT_SCRIPT}"
    else
        echo "::warning::run-static-analysis.sh not executable; skipping linter."
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
