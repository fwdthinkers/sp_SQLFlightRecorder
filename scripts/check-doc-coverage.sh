#!/usr/bin/env bash
# =============================================================================
# scripts/check-doc-coverage.sh
# -----------------------------------------------------------------------------
# Documentation-completeness gate for the v1.0.0 doc-coverage requirement
# (design §11.6; D-169). The shipped artifact sp_SQLFlightRecorder.sql is the
# single source of truth (D-110/D-152); this script derives the authoritative
# set of modes, rules, and configuration keys FROM the artifact and asserts a
# documentation page / entry exists for each. So adding a mode, rule, or config
# key to the artifact without documenting it fails the gate.
#
#   modes  (closed dispatch set)  -> docs/modes/<mode>.md
#   rules  (FR_Rules seed)        -> docs/rules/FR_R####.md
#   config (FR_Config literals)   -> an entry in docs/configuration.md
#
# It also flags the reverse — a rule or mode page with no backing artifact
# definition (an orphaned doc, e.g. after a copy/paste).
#
# Per D-148 this is build-pipeline / local-dev tooling only; it reads files and
# never connects to SQL Server. No external dependencies beyond POSIX awk/grep.
#
# Usage:   ./scripts/check-doc-coverage.sh
# Exit:    0 = every mode/rule/config key documented and no orphan pages
#          1 = coverage gaps (each listed)
#          2 = usage/environment error (missing artifact or docs)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
SQL="${REPO_ROOT}/sp_SQLFlightRecorder.sql"
DOCS="${REPO_ROOT}/docs"
MODES_DIR="${DOCS}/modes"
RULES_DIR="${DOCS}/rules"
CONFIG_DOC="${DOCS}/configuration.md"

for required in "${SQL}" "${CONFIG_DOC}"; do
  if [[ ! -f "${required}" ]]; then
    echo "::error::required file not found: ${required}" >&2
    exit 2
  fi
done

gaps=0
gap() { printf '  MISSING  %s\n' "$1"; gaps=$((gaps + 1)); }

# --- Extract authoritative identifiers from the artifact ---------------------
# Modes: the N'...' tokens inside the closed "@ModeNormalized ... NOT IN ( ... )"
# validation block (uppercase in the artifact; doc filenames are lowercase).
mapfile -t MODES < <(
  awk '/@ModeNormalized\) NOT IN \(/{grab=1; next} grab && /\)/{grab=0} grab{print}' "${SQL}" \
    | grep -oE "N'[A-Z]+'" | sed "s/^N'//; s/'$//" | sort -u
)
# Rules: every FR_Rules seed guard (RuleId = N'FR_R####_...'); short id FR_R####.
mapfile -t RULES < <(
  grep -oE "RuleId = N'FR_R[0-9]{4}" "${SQL}" | grep -oE "FR_R[0-9]{4}" | sort -u
)
# Config keys: every literal ConfigKey reference anywhere in the artifact.
mapfile -t KEYS < <(
  grep -oE "ConfigKey[[:space:]]*=[[:space:]]*N'[A-Za-z0-9_]+'" "${SQL}" \
    | grep -oE "N'[A-Za-z0-9_]+'" | sed "s/^N'//; s/'$//" | sort -u
)

if [[ ${#MODES[@]} -eq 0 || ${#RULES[@]} -eq 0 || ${#KEYS[@]} -eq 0 ]]; then
  echo "::error::extraction produced an empty set (modes=${#MODES[@]} rules=${#RULES[@]} keys=${#KEYS[@]}); the artifact layout may have changed — update this script." >&2
  exit 2
fi

# --- Forward coverage: artifact -> docs --------------------------------------
echo "Modes (${#MODES[@]}) -> docs/modes/<mode>.md"
for m in "${MODES[@]}"; do
  lc=$(printf '%s' "${m}" | tr '[:upper:]' '[:lower:]')
  [[ -f "${MODES_DIR}/${lc}.md" ]] || gap "docs/modes/${lc}.md (mode ${m})"
done

echo "Rules (${#RULES[@]}) -> docs/rules/FR_R####.md"
for r in "${RULES[@]}"; do
  [[ -f "${RULES_DIR}/${r}.md" ]] || gap "docs/rules/${r}.md"
done

echo "Config keys (${#KEYS[@]}) -> docs/configuration.md"
for k in "${KEYS[@]}"; do
  grep -qwF -- "${k}" "${CONFIG_DOC}" || gap "config key '${k}' not documented in docs/configuration.md"
done

# --- Reverse coverage: orphan rule/mode pages --------------------------------
echo "Reverse: rule/mode pages must correspond to an artifact definition"
shopt -s nullglob
for f in "${RULES_DIR}"/FR_R*.md; do
  b=$(basename "${f}" .md)
  printf '%s\n' "${RULES[@]}" | grep -qxF "${b}" \
    || { printf '  ORPHAN   %s (no FR_Rules definition)\n' "docs/rules/${b}.md"; gaps=$((gaps + 1)); }
done
for f in "${MODES_DIR}"/*.md; do
  b=$(basename "${f}" .md | tr '[:lower:]' '[:upper:]')
  printf '%s\n' "${MODES[@]}" | grep -qxF "${b}" \
    || { printf '  ORPHAN   %s (not in the mode dispatch set)\n' "docs/modes/$(basename "${f}")"; gaps=$((gaps + 1)); }
done
shopt -u nullglob

echo
if [[ ${gaps} -eq 0 ]]; then
  echo "Doc coverage OK: ${#MODES[@]} modes, ${#RULES[@]} rules, ${#KEYS[@]} config keys all documented; no orphan pages."
  exit 0
fi
echo "::error::Doc coverage FAILED: ${gaps} gap(s) above. Add the missing page/entry (or regenerate via scripts/gen-*-docs.py)."
exit 1
