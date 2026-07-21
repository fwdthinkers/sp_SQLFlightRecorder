# Release readiness — v1.0.0-rc.1

**Date:** 2026-07-21 · **Branch:** `v1.0.0-rc` (not pushed / not tagged) ·
**Artifact:** `ToolVersion 1.0.0-rc.1`, `SchemaVersion 0.4.0`,
`RulePackVersion 0.4.3`.

**Posture:** All five RC-tag criteria are met. The RC is technically ready to
tag. A short list of items is **tracked for resolution before final v1.0.0**
(and, for the contact addresses, preferably before a public RC) — none require a
code/behavior change.

## RC-tag criteria (from `implementation-plan-v1.0.0-rc.md`)
| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Six-target Tier-1 matrix FAIL=0; fixtures/golden green, wired into CI | ✅ | `ci-tier1` runs 2017/2019/2022/2025 Developer + a rule-fixtures job on 2022; six-target matrix FAIL=0 through 0.4.3; fixtures + golden **19/19** re-run on the rc.1 artifact. |
| 2 | Doc completeness (modes/rules/config/capabilities) + compat matrix; doc-coverage gate green | ✅ | 12 modes / 31 rules / 36 config keys documented; `check-doc-coverage.sh` + three generators `--check` green in CI. |
| 3 | §12 + §13 + SECURITY/SUPPORT/CoC/CONTRIBUTING + failure-mode catalog + 8 issue templates + CODEOWNERS present | ✅ | design.md §12/§13 folded in; governance docs + 8 templates + CODEOWNERS present (contacts/team tracked below). |
| 4 | `release.yml` dry-runs; upgrade paths validated | ✅¹ | Release build dry-run for `1.0.0-rc.1`: byte-identical artifact + `SHA256SUMS` + release notes; CHANGELOG gate passed. Upgrades **0.4.1/0.4.2/0.4.3 → rc.1** validated (`run-upgrade.sh`, 21/0). |
| 5 | Tier-2 process live; wording-lock pass; ToolVersion `1.0.0-rc.1`; CHANGELOG | ✅ | Tier-2 attestation process documented; §6.7 wording lock reviewed (no changes needed); version bumped; CHANGELOG `1.0.0-rc.1` entry present. |

¹ `release.yml` itself runs on GitHub Actions (tag push / `workflow_dispatch`);
it was **not** triggered here because this branch is intentionally unpushed. The
build half was dry-run locally via `scripts/build-release-artifact.sh`.

## Verified vs pending
- **Upgrades:** 0.4.1 / 0.4.2 / 0.4.3 → rc.1 verified (install-over Success,
  SchemaVersion stays 0.4.0, no DDL migration, no data dropped, Report works).
  **v0.4.0 pending** — no public `v0.4.0` tag exists; not faked, not claimed.
- **Tier 1 (verified):** 2017/2019/2022/2025 Developer + 2022 Express/Standard.
- **Tier 2 (pending attestation):** 2012/2014/2016 Windows + Azure MI/DB — process
  live, no target marked Verified without evidence.

## Tracked before final v1.0.0 (not code changes)
1. **Security & conduct contacts** — `TODO` placeholders in `SECURITY.md` /
   `CODE_OF_CONDUCT.md`. Must resolve before final v1.0.0; preferably before a
   public RC if the owner can provide them. (`SECURITY.md` uses cautious
   "if enabled" wording for private reporting — no false commitment.)
2. **`@core-maintainers` CODEOWNERS team** — must exist as an org/team or be
   replaced with real maintainer handles before final v1.0.0.
3. **Two-maintainer wording sign-off** (D-076/D-158/D-189) — the systematic
   review is recorded in `wording-lock-review.md`; the human sign-off remains.
4. **Tier-2 attestations** — ≥ 4 of 5 targets before final v1.0.0 (§11.6).
5. **`v0.4.0` upgrade artifact** — optional; supply
   `tests/upgrade/artifacts/v0.4.0.sql` to validate that path. Not a public
   promise, so not an RC blocker (Group F decision).

## Release dry-run (local, this cycle)
```
scripts/build-release-artifact.sh --version 1.0.0-rc.1
  Release version: 1.0.0-rc.1
  byte-identical copy of sp_SQLFlightRecorder.sql (344857 bytes)
  SHA256SUMS + RELEASE_NOTES.md (the CHANGELOG 1.0.0-rc.1 section)
  Build OK.
```
The full workflow (gate → build → publish, or `workflow_dispatch` dry-run) runs
in CI once the branch is pushed; nothing here pushes, tags, or publishes.

## Recommendation
Tag-ready as `v1.0.0-rc.1` on the owner's go-ahead. Resolving the contact
placeholders and the CODEOWNERS team is advisable before a *public* RC; the
remaining items are final-v1.0 gates.
