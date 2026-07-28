# Release readiness — v1.0.0-rc.1

**Date:** 2026-07-21 · updated 2026-07-28 (branch state + blocker list) ·
**Branch:** `v1.0.0-rc`, **pushed** 2026-07-21 and tracking `origin/v1.0.0-rc`;
**not tagged, not published** — no `v1.0.0-rc.1` tag and no GitHub Release
exist. HEAD before the 2026-07-28 documentation-cleanup commit was `504492e`. ·
**Artifact:** `ToolVersion 1.0.0-rc.1`, `SchemaVersion 0.4.0`,
`RulePackVersion 0.4.3`.

**Posture:** All five RC-tag criteria are met. The RC is technically ready to
tag. A short list of items is **tracked for resolution before final v1.0.0** —
none require a code/behavior change. As of 2026-07-28 no public-facing `TODO`
placeholder remains in `SECURITY.md` or `CODE_OF_CONDUCT.md`; both now describe
the channel that actually exists, so the absence of a dedicated contact is no
longer a *publication* blocker for the RC, only a final-v1.0 blocker.

## RC-tag criteria (from `implementation-plan-v1.0.0-rc.md`)
| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Six-target Tier-1 matrix FAIL=0; fixtures/golden green, wired into CI | ✅ | `ci-tier1` runs 2017/2019/2022/2025 Developer + a rule-fixtures job on 2022; six-target matrix FAIL=0 through 0.4.3; fixtures + golden **19/19** re-run on the rc.1 artifact. |
| 2 | Doc completeness (modes/rules/config/capabilities) + compat matrix; doc-coverage gate green | ✅ | 12 modes / 31 rules / 36 config keys documented; `check-doc-coverage.sh` + three generators `--check` green in CI. |
| 3 | §12 + §13 + SECURITY/SUPPORT/CoC/CONTRIBUTING + failure-mode catalog + 8 issue templates + CODEOWNERS present | ✅ | design.md §12/§13 folded in; governance docs + 8 templates present; CODEOWNERS routes to a resolving owner (D-191). Contact items tracked below. |
| 4 | `release.yml` dry-runs; upgrade paths validated | ✅¹ | Release build dry-run for `1.0.0-rc.1`: byte-identical artifact + `SHA256SUMS` + release notes; CHANGELOG gate passed. Upgrades **0.4.1/0.4.2/0.4.3 → rc.1** validated (`run-upgrade.sh`, 21/0). |
| 5 | Tier-2 process live; wording-lock pass; ToolVersion `1.0.0-rc.1`; CHANGELOG | ✅ | Tier-2 attestation process documented; §6.7 wording lock reviewed (no changes needed); version bumped; CHANGELOG `1.0.0-rc.1` entry present. |

¹ `release.yml` itself runs on GitHub Actions (tag push / `workflow_dispatch`).
It has **not** been triggered: the branch is pushed, but no tag has been created
and no `workflow_dispatch` dry-run has been recorded here. The build half was
dry-run locally via `scripts/build-release-artifact.sh`. Remote CI results for
the pushed branch are not recorded in this document — check `ci-tier1` on
`origin/v1.0.0-rc` before tagging.

## Verified vs pending
- **Upgrades:** 0.4.1 / 0.4.2 / 0.4.3 → rc.1 verified (install-over Success,
  SchemaVersion stays 0.4.0, no DDL migration, no data dropped, Report works).
  **v0.4.0 pending** — no public `v0.4.0` tag exists; not faked, not claimed.
- **Tier 1 (verified):** 2017/2019/2022/2025 Developer + 2022 Express/Standard.
- **Tier 2 (pending attestation):** 2012/2014/2016 Windows + Azure MI/DB — process
  live, no target marked Verified without evidence.

## Tracked before final v1.0.0 (not code changes)
1. **Private security contact** — configure a dedicated one, **or** enable
   GitHub private vulnerability reporting on the repository. `SECURITY.md`
   states the honest current position: private vulnerability reporting is the
   preferred channel *if enabled*; if it is not, the project has no dedicated
   private security contact yet, reporters are told to withhold specifics until
   a private channel exists, and non-sensitive hardening suggestions may be
   opened as normal issues. No address is invented.
2. **Conduct contact** — configure a dedicated one. `CODE_OF_CONDUCT.md` routes
   reports to the owner/maintainers through available GitHub channels and says
   plainly that no dedicated address is configured. No address is invented.
3. **Two-maintainer wording sign-off** (D-076/D-158/D-189) — the systematic
   review is recorded in `wording-lock-review.md`; the human sign-off remains.
4. **Tier-2 attestations** — ≥ 4 of 5 targets before final v1.0.0 (§11.6).
5. **`v0.4.0` upgrade artifact** — optional; supply
   `tests/upgrade/artifacts/v0.4.0.sql` to validate that path. Not a public
   promise, so not an RC blocker (Group F decision).

**Resolved 2026-07-28 — no longer a blocker:** CODEOWNERS. The owner was
confirmed to be a GitHub **user account**, not an organization, so `@org/team`
syntax could never resolve here. Owners are now the repository owner account
`@forward-thinkers-lab`, which resolves and takes effect as written (D-191,
superseding D-185's routing target).

## Future / process note (not a v1.0 gate)
If the repository moves under an organization, configure a visible maintainer
team with write access to this repository and update `.github/CODEOWNERS` to
route to it, restoring D-185's topic-team split. Separately, note that GitHub
does not request a review from a PR's own author, so `CODEOWNERS` alone does not
enforce the two-reviewer rule (D-158) on owner-authored PRs; that still relies
on a second human reviewer, or on branch protection if it is ever needed
mechanically.

## Release dry-run (local, this cycle)
```
scripts/build-release-artifact.sh --version 1.0.0-rc.1
  Release version: 1.0.0-rc.1
  byte-identical copy of sp_SQLFlightRecorder.sql (344857 bytes)
  SHA256SUMS + RELEASE_NOTES.md (the CHANGELOG 1.0.0-rc.1 section)
  Build OK.
```
The full workflow (gate → build → publish, or `workflow_dispatch` dry-run) runs
in CI on a tag push or manual dispatch. Nothing in this document tags or
publishes. Re-run 2026-07-28: same 344,857-byte artifact, same SHA256
`2ae4c475…`.

## Recommendation
Tag-ready as `v1.0.0-rc.1` on the owner's go-ahead. The public `TODO`
placeholders that previously argued for delaying a public RC are gone, and the
CODEOWNERS ambiguity is resolved. The two contact items, the wording sign-off
and the Tier-2 attestations remain final-v1.0 gates. Before tagging, confirm
`ci-tier1` is green on the pushed branch — this document does not record remote
CI state.
