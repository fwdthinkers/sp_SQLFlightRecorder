#!/usr/bin/env bash
# =============================================================================
# scripts/run-static-analysis.sh
# -----------------------------------------------------------------------------
# Part 2 of 9 (v0.1 Design Prototype).
#
# Thin convenience wrapper around tests/static-analysis/lint.py. Exists so
# contributors and CI invoke the linter the same way (D-187: recommended-
# but-not-required local tooling), and so the CI workflow has a single
# line to call.
#
# Per D-148 this is build-pipeline / local-dev only. It never runs on a
# user's SQL Server.
#
# Usage:
#   ./scripts/run-static-analysis.sh               # lints default target(s)
#   ./scripts/run-static-analysis.sh path/a.sql    # lints specific files
#   ./scripts/run-static-analysis.sh --self-test   # runs linter self-test
#
# Exit code: forwards the linter's exit code (0 pass, 1 fail).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
LINTER="${REPO_ROOT}/tests/static-analysis/lint.py"

# Pick the first available python3 / python.
if command -v python3 >/dev/null 2>&1; then
    PY="python3"
elif command -v python >/dev/null 2>&1; then
    PY="python"
else
    echo "::error::python3 is required to run the static-analysis linter." >&2
    echo "       Install Python 3.10+ and re-run. See docs/contributing/overview.md." >&2
    exit 2
fi

if [[ ! -f "${LINTER}" ]]; then
    echo "::error::Linter not found at ${LINTER}" >&2
    exit 2
fi

# If no arguments given, run against the default target and additionally
# self-test, so a bare invocation gives full coverage on a contributor's
# machine. CI calls the two commands explicitly in separate steps.
if [[ $# -eq 0 ]]; then
    echo "==> Running static-analysis linter (default targets)..."
    "${PY}" "${LINTER}"
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        exit ${rc}
    fi
    echo "==> Running linter self-test..."
    exec "${PY}" "${LINTER}" --self-test
fi

exec "${PY}" "${LINTER}" "$@"
