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
# Status upgrades only when real evidence exists (D-192). 2014/2016 were attested
# manually against v1.0.0 on 2026-07-29; 2012 completed the same lifecycle but
# with a reproducible collector failure, so it is legacy best-effort (D-195).
TIER2 = [
    ("SQL Server 2016 (Windows)", "✅ Verified — manual, v1.0.0",
     "EngineEdition 2, ProductMajorVersion 13, ProductLevel SP2. Install, Collect ×2, Report (incl. `FR_R0026`), Purge `@WhatIf`, Uninstall all Success. Query Store supported but not enabled on the tested databases; Always On not enabled; ErrorLog and BufferPool collectors left disabled by default."),
    ("SQL Server 2014 (Windows)", "✅ Verified — manual, v1.0.0",
     "EngineEdition 3, ProductLevel RTM. Same lifecycle, all Success. Query Store unsupported and time-zone support unavailable, both as expected; Always On not enabled. Note: `ProductMajorVersion` came back **blank** in the capability snapshot, so keep external `ProductVersion` evidence for this target."),
    ("SQL Server 2012 (Windows)", "⚠️ Legacy best-effort — **not** a clean verified target",
     "EngineEdition 3, ProductLevel RTM. Lifecycle completes — Install, Report (incl. `FR_R0026`), Purge `@WhatIf`, Uninstall all Success — but **both Collect runs returned `PartialSuccess`**: the `SchemaActivity` collector reported `dbsDone=0; dbErrors=1; budgetHit=0`. Expect degraded schema-activity data (D-195)."),
    ("Azure SQL Managed Instance", "⏳ Pending attestation", "No attestation received."),
    ("Azure SQL Database", "⏳ Pending attestation",
     "No attestation received. Heavy degradation expected: per-DB install, no Agent/msdb/error log (D-109)."),
]


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    for r in rows:
        out.append("| " + " | ".join(r) + " |")
    return "\n".join(out)


def page():
    return f"""# Compatibility matrix

Primary supported range: **SQL Server 2014 through 2025**, on-prem and cloud, with
capability-driven degradation (D-108 as amended by **D-195**). Synapse, Fabric,
Big Data Clusters, and Stretch are out of scope.

**Platform support at a glance**

| Range | Platforms | Status |
|---|---|---|
| SQL Server 2017–2025 | Linux **and** Windows | Linux verified in automated Tier-1 CI. Windows is supported by the same capability-based behavior — the tool branches on capability flags and `EngineEdition`, never on OS — and is manually attested where evidence exists. |
| SQL Server 2014 and 2016 | **Windows only** | Manual Tier-2 targets, both **verified against v1.0.0** (see Tier 2 below). |
| SQL Server 2012 | **Windows only** | **Legacy best-effort.** The v1.0.0 lifecycle completed, but with a known `SchemaActivity` collector failure and `PartialSuccess` collects. Not a normally supported target (**D-195**). |

> The released `v1.0.0` artifact reports `SupportedSqlServerRange` as
> "SQL Server 2012–2025". That is not wrong — 2012 still runs, best-effort — but
> it predates this policy and is coarser than it. The artifact is immutable; this
> page carries the qualification.

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

## Tier 2 — manual attestation (Windows and Azure)
These cannot be containerized in CI; status comes from attestations filed via
the **version-compat** issue template (D-164) — see
[tier2-attestation.md](tier2-attestation.md) for the process. Until an
attestation arrives, status is **Unverified** — not a claim of breakage, only of
untested.

{table(["Target", "Status", "Evidence and caveats"], TIER2)}

**Tier 2 verified is not Tier 1 verified.** The 2014 and 2016 rows rest on a
single manual lifecycle run each, recorded above — one run on one machine, not a
per-push automated gate. They are believed good and the evidence is real, but
they are re-checked only when someone runs them again (D-164 staleness applies).
Treat the two tiers as separate claims.

**Azure remains unattested.** No Azure equivalence is claimed for Managed
Instance or SQL Database until a real attestation lands.

**No release gate (D-192).** Tier-2 attestation does not gate a release. `v1.0.0`
shipped with every Tier-2 target *Unverified*; 2014 and 2016 were attested
shortly afterwards and upgraded here on evidence, which is exactly the path D-192
requires — status improves only when someone produces a run. Attestation
collection continues: the staleness policy (D-164) moves a target back to
*Unverified* after 3 minors without a fresh attestation and opens a deprecation
discussion after 6; the process is on an 18-month post-1.0 review (D-190).

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
