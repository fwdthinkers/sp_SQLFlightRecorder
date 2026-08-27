#!/usr/bin/env bash
# =============================================================================
# scripts/check-version-tag.sh
# -----------------------------------------------------------------------------
# Version/tag consistency gate (D-201). Every release — documentation-only
# releases included — bumps the in-proc version, so on a tagged build the
# artifact's Tool-Version header must match the release tag. This script makes
# that structural instead of remembered:
#
#   * with an argument:      check-version-tag.sh v1.2.0
#     asserts the artifact header matches that tag (used by release.yml,
#     which passes the pushed tag name).
#   * without an argument:   inspects `git tag --points-at HEAD`. If a
#     version tag (v<digit>...) points at HEAD, the header must match one of
#     them; if none does, this is not a tagged build and the check passes as
#     a no-op (so it is safe in per-push CI and locally).
#
# The header is the single source: ci-tier1 separately asserts that the
# header matches the About output, so header == tag implies About == tag.
#
# Per D-148 this is build-pipeline / local-dev tooling only; it reads files
# and git metadata and never connects to SQL Server.
#
# Usage:   ./scripts/check-version-tag.sh [vX.Y.Z]
# Exit:    0 = match, or not a tagged build (no-arg mode only)
#          1 = version tag present but the artifact header does not match
#          2 = usage/environment error (header unparsable, not a git repo)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
SQL="${REPO_ROOT}/sp_SQLFlightRecorder.sql"

if [[ ! -f "${SQL}" ]]; then
  echo "::error::artifact not found: ${SQL}" >&2
  exit 2
fi

HEADER=$(grep -m1 -E '^-- Tool-Version:' "${SQL}" | awk '{print $3}')
if [[ -z "${HEADER}" ]]; then
  echo "::error::could not parse Tool-Version from ${SQL} header." >&2
  exit 2
fi

TAG="${1:-}"

# GitHub Actions tag builds expose the tag even when no argument is passed.
if [[ -z "${TAG}" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  TAG="${GITHUB_REF_NAME:-}"
fi

if [[ -n "${TAG}" ]]; then
  if [[ "v${HEADER}" == "${TAG}" ]]; then
    echo "Version/tag OK: artifact Tool-Version ${HEADER} matches tag ${TAG}."
    exit 0
  fi
  echo "::error::tag ${TAG} does not match artifact Tool-Version ${HEADER} (expected tag v${HEADER}). Every release bumps the in-proc version (D-201)." >&2
  exit 1
fi

if ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "::error::${REPO_ROOT} is not a git work tree and no tag argument was given." >&2
  exit 2
fi

VERSION_TAGS=$(git -C "${REPO_ROOT}" tag --points-at HEAD | grep -E '^v[0-9]' || true)

if [[ -z "${VERSION_TAGS}" ]]; then
  echo "Version/tag check: no version tag points at HEAD; not a tagged build. Nothing to check."
  exit 0
fi

if printf '%s\n' "${VERSION_TAGS}" | grep -qxF "v${HEADER}"; then
  echo "Version/tag OK: artifact Tool-Version ${HEADER} matches tag v${HEADER} at HEAD."
  exit 0
fi

echo "::error::version tag(s) at HEAD [$(printf '%s' "${VERSION_TAGS}" | tr '\n' ' ')] do not match artifact Tool-Version ${HEADER} (expected v${HEADER}). Every release bumps the in-proc version (D-201)." >&2
exit 1
