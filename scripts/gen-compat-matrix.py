#!/usr/bin/env python3
# =============================================================================
# scripts/gen-compat-matrix.py
# -----------------------------------------------------------------------------
# Generates docs/compatibility/matrix.md (D-165) from the target tables below.
# Build-pipeline tooling (D-148; D-169). The prose is authored here; the three
# status tables — Tier-1 automated, editions, Tier-2 attestation — are the
# parts that change as CI verifies a version or an attestation lands, so they
# are data. A maintainer edits the TIER1 / EDITIONS / TIER2 lists (or a future
# revision wires them to CI results + parsed attestation issues) and re-runs
# this script; CI's `--check` fails if matrix.md drifts from the generator.
#
# Per D-148 this never runs on a user's SQL Server.
#
# Usage:  python scripts/gen-compat-matrix.py            # write the page
#         python scripts/gen-compat-matrix.py --check    # fail if out of date
# =============================================================================
from __future__ import annotations
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "docs" / "compatibility" / "matrix.md"

# Releases whose full six-target Docker matrix passed FAIL=0 (updated per tag).
VALIDATED_THROUGH = "v0.4.1 / v0.4.2 / v0.4.3"

# Tier 1 — automated CI on Linux containers (D-120), blocking.
# Tier 1 — verified by automated Linux containers. `verification` distinguishes
# the hosted per-push gate (ci-tier1, the four Developer targets) from the local
# six-target Docker matrix (run-local-tier1.sh) run before a release, which adds
# the 2022 Express and Standard editions. EngineEdition = SERVERPROPERTY('EngineEdition').
TIER1 = [
    ("SQL Server 2017", "Developer", "3", "Linux", "ci-tier1 + local matrix"),
    ("SQL Server 2019", "Developer", "3", "Linux", "ci-tier1 + local matrix"),
    ("SQL Server 2022", "Developer", "3", "Linux", "ci-tier1 + local matrix"),
    ("SQL Server 2022", "Express",   "4", "Linux", "local matrix"),
    ("SQL Server 2022", "Standard",  "2", "Linux", "local matrix"),
    ("SQL Server 2025", "Developer", "3", "Linux", "ci-tier1 + local matrix"),
]

# Tier 2 — manual attestation (D-121/D-164); Unverified until attested.
TIER2 = [
    ("SQL Server 2012 (Windows)", "⏳ Pending attestation"),
    ("SQL Server 2014 (Windows)", "⏳ Pending attestation"),
    ("SQL Server 2016 (Windows)", "⏳ Pending attestation"),
    ("Azure SQL Managed Instance", "⏳ Pending attestation"),
    ("Azure SQL Database",
     "⏳ Pending attestation (heavy degradation expected: per-DB install, no Agent/msdb/error log — D-109)"),
]


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    for r in rows:
        out.append("| " + " | ".join(r) + " |")
    return "\n".join(out)


def page():
    return f"""# Compatibility matrix

Supported engine range: **SQL Server 2012 through 2025**, on-prem and cloud, with
capability-driven degradation (D-108). Synapse, Fabric, Big Data Clusters, and
Stretch are out of scope.

> **Verification tiers.** **Tier 1** = automated CI on Linux containers, blocking
> (D-120). **Tier 2** = manual attestation for targets that cannot be
> containerized for free, not merge-blocking (D-121/D-164). **Tier 3** =
> community reports (non-binding, D-166). A target's status is only as strong as
> the tier that verified it.

## Tier 1 — verified (automated Linux containers)
The hosted `ci-tier1` workflow verifies the four Developer targets on every
push; the six-target Docker matrix (`run-local-tier1.sh`) additionally covers
the 2022 Express and Standard editions before each release (FAIL=0 through
{VALIDATED_THROUGH}). The v1.0.0-rc artifact was re-verified on the 2022
Developer, Express, and Standard editions, and its upgrade path from every
tagged release was validated (`tests/upgrade/run-upgrade.sh`).

{table(["Version", "Edition", "EngineEdition", "Platform", "Verified by"], TIER1)}

**Other editions.** `Standard` (EngineEdition 2) and `Express` (EngineEdition 4)
are verified above on 2022; Express cascades compression off (D-034) and has no
SQL Agent, so job creation is skipped with a status row (D-116). **Enterprise**
reports `EngineEdition = 3`, the same value as Developer, and the tool branches
on capabilities and EngineEdition — never on edition name — so Developer
coverage is *expected* to carry to Enterprise. Enterprise is not separately
containerized, so it is not independently verified here; this is a compatibility
expectation, not a verified-equivalence claim.

## Tier 2 — manual attestation (pending)
These cannot be containerized in CI; status comes from attestations filed via
the **version-compat** issue template (D-164) — see
[tier2-attestation.md](tier2-attestation.md) for the process. Until an
attestation arrives, status is **Unverified** — not a claim of breakage, only of
untested. Azure targets are listed here as pending; no Azure equivalence is
claimed until a real attestation lands.

{table(["Target", "Status"], TIER2)}

**v1.0 gate:** at least **4 of 5** Tier-2 targets attested (§11.6). The staleness
policy (D-164) moves a target to *Unverified* after 3 minors without an
attestation and opens a deprecation discussion after 6; the process is on an
18-month post-1.0 review (D-190).

## How to contribute an attestation
Open a **Version compatibility / Tier-2 attestation** issue with your Install →
Collect → Report → Uninstall results and the capability snapshot. See
[tier2-attestation.md](tier2-attestation.md) and
[.github/ISSUE_TEMPLATE/version-compat.yml](../../.github/ISSUE_TEMPLATE/version-compat.yml).

---
*Generated by `scripts/gen-compat-matrix.py` (D-165/D-169) — edit the target
tables in that script (or let CI regenerate) rather than this file. The
doc-coverage job runs `--check` and fails if this page drifts from the generator.*
"""


def main():
    check = "--check" in sys.argv
    new = page()
    if check:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != new:
            print("STALE compatibility matrix (run scripts/gen-compat-matrix.py).")
            return 1
        print("compatibility matrix up to date.")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(new, encoding="utf-8", newline="\n")
    print(f"generated {OUT.relative_to(OUT.parents[2])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
