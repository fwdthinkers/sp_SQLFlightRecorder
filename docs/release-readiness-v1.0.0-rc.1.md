# Release readiness — v1.0.0-rc.1

**Date:** 2026-07-21 · updated 2026-07-28 (branch state, blocker list, release
outcome) · **Artifact:** `ToolVersion 1.0.0-rc.1`, `SchemaVersion 0.4.0`,
`RulePackVersion 0.4.3`.

> ## ✅ RELEASED — 2026-07-28
> `v1.0.0-rc.1` is **tagged and published as a GitHub prerelease**. This
> document is now a record of the readiness assessment that preceded it, not a
> pending checklist.
>
> | | |
> |---|---|
> | Tag | `v1.0.0-rc.1`, annotated, on `1f6d056` |
> | Branch | `v1.0.0-rc` (tagged from the RC branch per D-173; **not** merged to `main`) |
> | Release workflow | `release.yml` passed |
> | Release | Published as a **prerelease** (auto-marked by the `-rc.1` suffix) |
> | Merged to `main`? | **No** — not required by the release plan |
>
> Attribution of evidence: the tag and its target are verified locally (annotated
> tag object on `1f6d056`). The workflow result and the published release are as
> **reported by the owner** — this environment has no GitHub credentials, so
> `git fetch`/`ls-remote` and the Actions API could not be queried to confirm
> them independently. The published artifact's checksum has therefore **not**
> been compared against the local build (`2ae4c475…`); see the follow-up below.

**Posture:** All five RC-tag criteria were met at tag time. A short list of items
remains **tracked for resolution before final v1.0.0** — none require a
code/behavior change. No public-facing `TODO` placeholder remains in
`SECURITY.md` or `CODE_OF_CONDUCT.md`; both describe the channel that actually
exists. `SECURITY.md` now names a dedicated private security address
(2026-07-29); `CODE_OF_CONDUCT.md` still has no dedicated contact and routes
through available GitHub maintainer channels.

## RC-tag criteria (from `implementation-plan-v1.0.0-rc.md`)
| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Six-target Tier-1 matrix FAIL=0; fixtures/golden green, wired into CI | ✅ | `ci-tier1` runs 2017/2019/2022/2025 Developer + a rule-fixtures job on 2022; six-target matrix FAIL=0 through 0.4.3; fixtures + golden **19/19** re-run on the rc.1 artifact. |
| 2 | Doc completeness (modes/rules/config/capabilities) + compat matrix; doc-coverage gate green | ✅ | 12 modes / 31 rules / 36 config keys documented; `check-doc-coverage.sh` + three generators `--check` green in CI. |
| 3 | §12 + §13 + SECURITY/SUPPORT/CoC/CONTRIBUTING + failure-mode catalog + 8 issue templates + CODEOWNERS present | ✅ | design.md §12/§13 folded in; governance docs + 8 templates present; CODEOWNERS routes to a resolving owner (D-191). Contact items tracked below. |
| 4 | `release.yml` dry-runs; upgrade paths validated | ✅¹ | Release build dry-run for `1.0.0-rc.1`: byte-identical artifact + `SHA256SUMS` + release notes; CHANGELOG gate passed. Upgrades **0.4.1/0.4.2/0.4.3 → rc.1** validated (`run-upgrade.sh`, 21/0). |
| 5 | Tier-2 process live; wording-lock pass; ToolVersion `1.0.0-rc.1`; CHANGELOG | ✅ | Tier-2 attestation process documented; §6.7 wording lock reviewed (no changes needed); version bumped; CHANGELOG `1.0.0-rc.1` entry present. |

¹ Assessed before the release. `release.yml` has since run for real on the
`v1.0.0-rc.1` tag push and passed (owner-reported), executing the gate → build →
publish path it had only been dry-run against locally.

## Verified vs pending
- **Upgrades → `1.0.0` (re-run 2026-07-29, target 2022): 28 passed, 0 failed, 1
  unavailable.** 0.4.1 / 0.4.2 / 0.4.3 / **1.0.0-rc.1** → 1.0.0 all verified:
  install-over Success, SchemaVersion stays 0.4.0, no DDL migration, no `FR_*`
  table dropped, rows preserved, all config keys present, Report works. The
  rc.1 row is now a genuine cross-version upgrade, not idempotency — the
  working-tree artifact is `1.0.0`. **v0.4.0 unavailable** — no public `v0.4.0`
  tag exists; not faked, not claimed, and set aside by the owner.
- **Tier 1 (verified):** 2017/2019/2022/2025 Developer + 2022 Express/Standard.
- **Tier 2 (pending attestation):** 2012/2014/2016 Windows + Azure MI/DB — process
  live, no target marked Verified without evidence.

## Tracked before final v1.0.0 (not code changes)
1. **`v0.4.0` upgrade artifact** — optional; supply
   `tests/upgrade/artifacts/v0.4.0.sql` to validate that path. Not a public
   promise, so not a blocker (Group F decision) — and explicitly set aside by
   the owner.

Then the mechanical v1.0.0 steps themselves: bump `ToolVersion` → `1.0.0`, add a
CHANGELOG `1.0.0` entry dated on its ship day, re-run the validation wave and the
upgrade harness (which at that point exercises the genuine rc.1 → 1.0.0 path),
confirm `ci-tier1` green, then tag.

**Resolved 2026-07-29 — conduct contact.** `CODE_OF_CONDUCT.md` now names a
concrete v1.0.0 reporting path: the repository owner via GitHub maintainer
channels, with a fallback for reporters who have no private channel, marked
explicitly as the designated path for v1.0.0 rather than a placeholder. No
address was invented. It also states plainly that a single-maintainer project
cannot review a report *about* that maintainer independently, and points to
GitHub's own abuse reporting as an independent route.

**Resolved 2026-07-29 — wording sign-off, rule and signature.** D-193 makes
owner sign-off sufficient for v1.0.0 (two-maintainer review resumes
automatically once a second maintainer exists or the project moves to an
organization), and the owner's signature is now recorded in
`wording-lock-review.md`. It was given against the `1.0.0-rc.1` artifact; the
`1.0.0` artifact differs only in version metadata, so it carries over — noted
in that document.

**Resolved 2026-07-29 — release process dry-run twice (§11.6, D-173).** Both
runs of the real workflow are now on record:

| # | Run | Event | Branch | Result |
|---|---|---|---|---|
| 1 | `release` #1 | tag push `v1.0.0-rc.1` | — | Success — gate → build → published the prerelease (2026-07-28) |
| 2 | `release` #2 | `workflow_dispatch` (manual) | `v1.0.0-rc` | **Success**, 54s — gate → build, published nothing (2026-07-29) |

Owner-reported; this environment has no GitHub credentials and cannot query the
Actions API. Note what run #2 built: the branch as pushed (`d158335`), which
still carries the **`1.0.0-rc.1`** artifact — the `1.0.0` bump was not yet
committed. So it validates the workflow path, not the `1.0.0` artifact. The
`1.0.0` artifact's build is covered by the local dry-run below, and by
`ci-tier1` once this commit is pushed.

**Resolved 2026-07-29 — hotfix rehearsal (D-174).** Performed; evidence below.

**Not a gate — cost-regression and soak (D-194).** No green evidence exists for
either, and none is claimed. Details below.

**No longer a blocker — Tier-2 attestations (D-192, 2026-07-29).** The ≥ 4-of-5
attestation gate is superseded: v1.0.0 may ship with Tier-2 targets *Unverified*.
The obligation that replaces it is a wording discipline, not a count — Tier-1
verified and Tier-2 pending/unverified must stay visibly separate, and no
unattested target (2012/2014/2016 or Azure) may be described as verified.
Attestations remain wanted as post-1.0 work; the five prepared issues are still
worth opening.

**Resolved 2026-07-29 — no longer a blocker:** private security contact.
`SECURITY.md` now names a dedicated address,
`sqlflightrecorder-security@forwardthinkersconsulting.com`, as the private
reporting channel. GitHub private vulnerability reporting is **not** exposed in
this repository's settings, so the doc says so plainly and does not send
reporters looking for a *Report a vulnerability* button that is not there.

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
Re-run 2026-07-28 immediately before tagging: same 344,857-byte artifact, same
SHA256 `2ae4c475…`. The real workflow then ran on the tag push and published the
prerelease.

**Final `1.0.0` build dry-run, 2026-07-29:**
```
scripts/build-release-artifact.sh --version 1.0.0
  Built dist/sp_SQLFlightRecorder.sql (344863 bytes)
  SHA256: dfb46a5428cce98291bcf30ca27a17fb0c0d5242e2d7be97ccfbc74e6a0e2989
  Release notes: 74 line(s)   (the CHANGELOG [1.0.0] section)
  Build OK.
```
The checksum necessarily differs from rc.1 — the artifact's version metadata
changed, which is the point of the bump. The diff against the tagged rc.1
artifact is version metadata and three comment lines only; no recommendation,
finding, or message string is touched.

## Outcome
Released as `v1.0.0-rc.1` (prerelease) on 2026-07-28.

**✅ `v1.0.0` released 2026-07-29** — tagged `v1.0.0` on `49e10ac`, published as
a full GitHub release, and `v1.0.0-rc` merged to `main`. `ToolVersion 1.0.0`,
build date 2026-07-29, `SchemaVersion 0.4.0`, `RulePackVersion 0.4.3`.

**Every §11.6 gate was met or formally removed before the release:** security
contact, conduct path, wording sign-off (rule **and** owner signature), release
process dry-run twice (D-173), hotfix rehearsed (D-174), Tier-2 removed as a
gate (D-192), cost/soak removed as a gate (D-194), `v0.4.0` set aside by the
owner.

Two things shipped **knowingly unverified**, recorded here and in the release
notes and never claimed as passing: Tier-2 targets are *Unverified* (no
attestation received — untested, not "works" and not "broken"), and there is no
cost-regression or soak evidence. Both remain post-1.0 follow-ups; see the
handoff.

This document is now a historical record of the readiness assessment. Live
project state lives in [handoff-v1.0.0-rc.md](handoff-v1.0.0-rc.md).

## Hotfix rehearsal (D-174) — performed 2026-07-29
Rehearsed end to end without publishing anything.

| Step | Evidence |
|---|---|
| Branch from latest tag | `hotfix/rehearsal-v1.0.0-rc.1` created from `v1.0.0-rc.1` (`1f6d056`) |
| Minimal fix | `94969cd` — docs-only: `tests/upgrade/README.md` "Current results" heading claimed the table described the current artifact at `ToolVersion 0.4.3`, but the tagged artifact is `1.0.0-rc.1` and the table is never refreshed automatically. Reframed as an explicit point-in-time record. |
| Tier-1-equivalent validation | Run on the hotfix branch: doc-coverage 12/31/36 no orphans; `lint.py` + 11-fixture self-test; three generators `--check` in sync; release build byte-identical, 344,857 bytes, SHA256 `2ae4c475…` |
| Forward-merge | `638df8f` — `git merge --no-ff` into `v1.0.0-rc`, clean, no conflicts |
| Not done, deliberately | no tag, no publish, no push of the hotfix branch. The branch is retained locally as evidence. |

**What this rehearsal does and does not prove.** It exercises the D-174
mechanics — branch from tag, minimal change, validation, forward-merge — and
those worked with no friction. It does **not** exercise the regression-test leg:
D-174 calls for "minimal fix + regression test", and a docs-only fix has no
regression test to write, so that half is still unrehearsed. It also does not
cover the 72-hour turnaround target, which only a real incident can test.

## Cost-regression (D-143) and soak (D-145) — no evidence, and why
**Neither has ever run. No green result is claimed.**

Both harnesses exist (`tests/perf/run-cost-regression.sh`, `run-soak.sh`) with
workflows (`ci-cost.yml`, `ci-soak.yml`), and both are `schedule` +
`workflow_dispatch` only — never on push or PR, by explicit design in their own
headers, so they cannot gate a PR or the RC.

The reason there is no nightly evidence is mechanical, and worth stating because
it is fixable: **GitHub runs scheduled workflows only from the default branch.**
`ci-cost.yml` and `ci-soak.yml` exist only on `v1.0.0-rc`; `origin/main` carries
just `ci-tier1.yml`. Verified with `git ls-tree origin/main .github/workflows/`.
So the nightly crons have never fired and cannot until the branch reaches `main`.

Per **D-194** this is not a v1.0.0 gate — consistent with D-143, which already
defers its strict >2% throughput check to "a PR check at GA once thresholds are
calibrated", and D-145, which already reads "failures handled in release
planning". A manual `workflow_dispatch` run of each before GA is **recommended,
not required**; it is the only way to get evidence before the merge to `main`.

## Post-release follow-ups
1. **Verify the published artifact's checksum.** Download the release asset and
   confirm it matches the local reproducible build, SHA256
   `2ae4c475264468dd3b60805a896114725f7cecddc3a4fc2f5c15ab3183c0d750`
   (344,857 bytes). Not yet done — no credentials in the authoring environment.
2. **Open the Tier-2 attestation issues for this RC.** D-164 specifies an
   attestation issue each RC, and `compatibility/tier2-attestation.md` describes
   it as auto-opened, but **no workflow implements it** — `release.yml` does not
   create issues. It is a manual maintainer step today. Since D-192 these no
   longer gate v1.0, but they remain the only mechanism that prompts anyone to
   attest, so the targets stay *Unverified* indefinitely until someone opens
   them. Five issue bodies (one per target) are drafted and ready to paste.
3. **CHANGELOG date.** The `1.0.0-rc.1` entry is dated `2026-07-21` (when the
   version was prepared); the actual tag and publish date was `2026-07-28`. Left
   as-is deliberately: that section was extracted verbatim into the published
   release notes, and editing it now would make the repository disagree with the
   published release. Worth dating the final `1.0.0` entry on its release day.
