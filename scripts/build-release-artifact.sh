#!/usr/bin/env bash
# =============================================================================
# scripts/build-release-artifact.sh
# -----------------------------------------------------------------------------
# Builds the release bundle for a tag and proves it is byte-identical to the
# shipped single-file artifact (D-110/D-152). Because the source is a single
# file (not split), "build" is: validate → copy → checksum → extract the
# CHANGELOG section — no concatenation. Runnable locally for a dry run and
# invoked by .github/workflows/release.yml. Build-pipeline only (D-148); reads
# files, never connects to SQL Server.
#
# Guards it enforces (each a release blocker per D-173):
#   * an explicit --version, when given, must equal the artifact Tool-Version
#     header (no silent tag/header drift);
#   * CHANGELOG.md must contain a "## [<version>]" section (entry mandatory);
#   * the emitted artifact must be byte-identical to sp_SQLFlightRecorder.sql.
#
# Usage:
#   scripts/build-release-artifact.sh [--version X.Y.Z[-rc.N]] [--out DIR]
#     --version  Expected release version. Default: parse from the header.
#     --out      Output directory (default: dist).
#
# Outputs in <out>/:
#   sp_SQLFlightRecorder.sql          byte-identical copy (canonical name)
#   SHA256SUMS                        checksum of the copy
#   RELEASE_NOTES.md                  the CHANGELOG section for this version
#
# Exit: 0 success; 1 validation/verify failure; 2 usage/environment error.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
ARTIFACT="${REPO_ROOT}/sp_SQLFlightRecorder.sql"
CHANGELOG="${REPO_ROOT}/CHANGELOG.md"

VERSION=""
OUT="${REPO_ROOT}/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    -h|--help) grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 2 ;;
  esac
done

for f in "${ARTIFACT}" "${CHANGELOG}"; do
  [[ -f "${f}" ]] || { echo "::error::required file not found: ${f}" >&2; exit 2; }
done

# --- Resolve and cross-check the version -------------------------------------
HEADER_VERSION="$(grep -m1 -E '^-- Tool-Version:' "${ARTIFACT}" | awk '{print $3}')"
if [[ -z "${HEADER_VERSION}" ]]; then
  echo "::error::could not parse '-- Tool-Version:' from ${ARTIFACT}" >&2
  exit 1
fi
if [[ -z "${VERSION}" ]]; then
  VERSION="${HEADER_VERSION}"
elif [[ "${VERSION}" != "${HEADER_VERSION}" ]]; then
  echo "::error::version mismatch: requested '${VERSION}' but the artifact header says '${HEADER_VERSION}'. Bump the Tool-Version header (or the tag) so they agree before releasing." >&2
  exit 1
fi
echo "Release version: ${VERSION}"

# --- CHANGELOG entry is mandatory (D-173/D-175) ------------------------------
if ! grep -qE "^## \[${VERSION}\]" "${CHANGELOG}"; then
  echo "::error::CHANGELOG.md has no '## [${VERSION}]' section. A changelog entry is mandatory before release (D-173)." >&2
  exit 1
fi

# --- Emit the bundle ---------------------------------------------------------
mkdir -p "${OUT}"
cp -f "${ARTIFACT}" "${OUT}/sp_SQLFlightRecorder.sql"

# Byte-identical guarantee (the release asset IS the shipped file, D-110/D-152).
if ! cmp -s "${ARTIFACT}" "${OUT}/sp_SQLFlightRecorder.sql"; then
  echo "::error::built artifact differs from source — build must be a byte-identical copy." >&2
  exit 1
fi

# Checksum (prefer sha256sum; fall back to shasum/openssl for portability).
( cd "${OUT}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum sp_SQLFlightRecorder.sql > SHA256SUMS
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 sp_SQLFlightRecorder.sql > SHA256SUMS
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s  sp_SQLFlightRecorder.sql\n' "$(openssl dgst -sha256 -r sp_SQLFlightRecorder.sql | awk '{print $1}')" > SHA256SUMS
  else
    echo "::error::no sha256 tool found (sha256sum/shasum/openssl)." >&2
    exit 1
  fi
) || exit 1

# Release notes = the CHANGELOG section for this version.
awk -v hdr="## [${VERSION}]" '
  index($0, hdr) == 1 { grab = 1; print; next }
  grab && /^## \[/    { grab = 0 }
  grab                { print }
' "${CHANGELOG}" > "${OUT}/RELEASE_NOTES.md"

BYTES="$(wc -c < "${OUT}/sp_SQLFlightRecorder.sql" | tr -d ' ')"
SHA="$(awk '{print $1}' "${OUT}/SHA256SUMS")"
echo "Built ${OUT}/sp_SQLFlightRecorder.sql (${BYTES} bytes)"
echo "SHA256: ${SHA}"
echo "Release notes: $(wc -l < "${OUT}/RELEASE_NOTES.md" | tr -d ' ') line(s)"
echo "Build OK."
