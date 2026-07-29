# Handoff — v1.0.0-rc.1

Full context for picking up the `sp_SQLFlightRecorder` v1.0.0 release candidate.
Written 2026-07-21. This is a hub; it links the authoritative docs rather than
duplicating them.

## Snapshot
| | |
|---|---|
| Branch | `v1.0.0-rc` (cut from `b9d4cd3` = the `v0.4.3` tag), tracking `origin/v1.0.0-rc` |
| HEAD | `1f6d056` — "resolve CODEOWNERS ambiguity — route to `@forward-thinkers-lab` (D-191)" |
| Artifact version | `ToolVersion 1.0.0-rc.1`, `SchemaVersion 0.4.0`, `RulePackVersion 0.4.3` |
| Working tree | clean |
| Pushed? | **Yes** — `origin/v1.0.0-rc` = `1f6d056` |
| Tagged? | **Yes** — annotated `v1.0.0-rc.1` on `1f6d056` (2026-07-28) |
| Published? | **Yes** — GitHub **prerelease** `v1.0.0-rc.1`; `release.yml` passed |
| Merged to `main`? | **No** — tagging from the RC branch is what the plan calls for (D-173); no merge required |
| Status | **RC shipped.** Next milestone is final `v1.0.0`; see [release-readiness-v1.0.0-rc.1.md](release-readiness-v1.0.0-rc.1.md) |

**Standing rule:** the owner authorizes every push, merge, tag, and publish. The
RC is tagged and published; the branch has **not** been merged to `main`.

## What this RC is
A **documentation, CI/release-process, and version-metadata** stabilization on
top of `v0.4.3`. It changes **no persisted schema, output contract, rule ID,
rule logic, collector, or mode**. The only artifact change across the whole RC is
the version metadata (Group F commit 1); everything else is docs, tests, CI, and
release tooling. Scope authority: `docs/decisions.md` (append-only, D-178) and
`docs/design.md`.

## RC commit inventory (18 group commits, `b9d4cd3..730af8f`)
Followed by `504492e` (this handoff doc) and two pre-RC documentation-cleanup
commits: `89b1693` (stale pushed-state corrections + removal of the public
`TODO` contact placeholders) and `1f6d056` (CODEOWNERS → `@forward-thinkers-lab`,
D-191) — the tagged commit. A post-release bookkeeping commit follows. None of
them touch the artifact.
- **Group A** `6872151` — doc inventory + stale-reference cleanup (also the one
  earlier artifact reword: unreachable fallthrough → `UnhandledMode` default).
- Samples `af1cacb` — documentation structure samples (approved before mass docs).
- **Group C** `358fc3e` — security/process docs + all 8 issue templates.
- **Group B** `be94679`, `f8c48a1`, `bc4ad22` — rule docs (31), mode docs (12),
  configuration/capability/compatibility + index.
- **Group D** `9babab0`, `03ff811`, `4a989bb`, `e1c366e`, `4c17fc6` —
  doc-coverage gate; rule fixtures + golden in CI; dry-runnable `release.yml`;
  compat-matrix generator; cost + soak harnesses (non-blocking).
- **Group E** `31500d2`, `956cb29`, `eb3d7e6` — upgrade-path harness; edition/
  compat matrix (6 verified targets); Tier-2 attestation process + helpers.
- **Group F** `4d6deca`, `3a10ce4`, `3e906b7`, `730af8f` — version `1.0.0-rc.1`
  + CHANGELOG; wording-lock review; §12/§13 fold + support policy; release
  dry-run + readiness report.

## Key decisions locked this cycle
- **`RulePackVersion` stays `0.4.3`** (owner-approved). Per D-085 it names the
  release that last changed rule logic/catalog; the RC changed no rules. It only
  coincidentally equalled `ToolVersion` before because every `0.4.x` patch
  touched rules. Divergence is intentional and documented in the artifact.
- **`SchemaVersion` stays `0.4.0`** — forward-only, no DDL (D-038).
- **Plan-XML analysis stays removed/disabled** (FR_R0030–34 reserved, disabled;
  D-015/046/082/136). Not a roadmap item.
- **Output contracts frozen** for v1.x: Findings 16-col (D-067), Timeline 12-col
  (D-071), Markdown 14-key header (D-085). See [compatibility/support-policy.md](compatibility/support-policy.md).
- Repo conventions: single-file artifact at repo root (D-110/D-152); LF endings
  via `.gitattributes`; `.gitignore` covers `dist/` + Python caches; `.claude/`
  excluded via `.git/info/exclude` (local, never committed).

## Validation status (all green, 2026-07-21; local wave re-run green 2026-07-28 on `1f6d056` immediately before tagging)
Run on the completed RC branch:
- `check-doc-coverage.sh` — 12 modes / 31 rules / 36 config keys; no orphans.
- `lint.py sp_SQLFlightRecorder.sql` + `--self-test` (11 fixtures).
- `gen-rule-docs.py --check`, `gen-mode-docs.py --check`,
  `gen-compat-matrix.py --check` — all in sync.
- `build-release-artifact.sh --version 1.0.0-rc.1` — byte-identical 344,857-byte
  artifact, SHA256 `2ae4c475…` (reproducible across runs), 43-line notes.
- `run-upgrade.sh` — **21 passed, 0 failed, 1 unavailable**.
- Rule fixtures + demo golden — **19/19** on SQL 2022 (Group F commit 1).
- RC artifact re-verified on 2022 Developer/Express/Standard (EngineEdition 3/4/2).

## Verified vs pending
- **Upgrades:** 0.4.1 / 0.4.2 / 0.4.3 → rc.1 verified (install-over Success,
  `SchemaVersion` stays 0.4.0, no DDL migration, no `FR_*` data dropped, Report
  works). **v0.4.0 pending** — no public `v0.4.0` tag exists (not faked).
- **Tier 1 verified:** 2017/2019/2022/2025 Developer + 2022 Express/Standard.
- **Tier 2 pending attestation:** 2012/2014/2016 Windows + Azure MI/DB.

## Tracked before FINAL v1.0.0 (none are code changes)
No public-facing `TODO` placeholders remain — `SECURITY.md` and
`CODE_OF_CONDUCT.md` now state the current channel honestly instead. The
underlying items are still open:

1. **Private security contact** — configure a dedicated one, or enable GitHub
   private vulnerability reporting. `SECURITY.md` currently says, without
   inventing an address, that the preferred channel is private vulnerability
   reporting *if enabled*, and that no dedicated contact exists otherwise.
2. **Conduct contact** — configure a dedicated one. `CODE_OF_CONDUCT.md`
   currently routes reports to the owner/maintainers via available GitHub
   channels and says no dedicated address is configured yet.
3. Two-maintainer §6.7 wording sign-off (D-076/D-158/D-189) — the systematic
   review is in [wording-lock-review.md](wording-lock-review.md); the human
   sign-off remains.
4. Release process dry-run twice (§11.6, D-173) — the `workflow_dispatch`
   dry-run has never run.
5. Hotfix process rehearsed (§11.6, D-174) — now possible, since `v1.0.0-rc.1`
   exists to branch from.
6. Optional: `tests/upgrade/artifacts/v0.4.0.sql` to validate the v0.4.0 upgrade
   path. Not a public promise, so not a blocker.

**Removed as a gate 2026-07-29 — Tier-2 attestations (D-192).** v1.0.0 may ship
with Tier-2 targets *Unverified*. What replaces the ≥ 4-of-5 count is a wording
obligation: Tier-1 verified and Tier-2 pending/unverified stay visibly separate,
and no unattested target — 2012/2014/2016 or Azure — is ever described as
verified. Attestations are still wanted as post-1.0 work.

**Resolved 2026-07-28 (was item 3):** CODEOWNERS. `forward-thinkers-lab` is a
GitHub **user account**, not an organization, so `@org/team` syntax could never
resolve. Owners are now `@forward-thinkers-lab` — a valid, resolving owner
(**D-191**, superseding D-185's routing target; D-185's topic-team intent is
retained for a future org move).

**Future / process note, not a v1.0 gate:** if the project moves under an
organization, configure a visible maintainer team with write access and update
`.github/CODEOWNERS` to route to it. Also note GitHub does not request a review
from a PR's own author, so CODEOWNERS alone does not enforce the two-reviewer
rule (D-158) on owner-authored PRs.

## Release process (D-173) — executed for rc.1 on 2026-07-28
Kept as the template for the next release. Steps 1–4 are **done** for
`v1.0.0-rc.1`.
1. Dry-run the release build: `bash scripts/build-release-artifact.sh --version
   <version>` — inspect `dist/` (git-ignored).
2. Push the branch. Each push triggers `ci-tier1` (static-analysis +
   doc-coverage + 4-target matrix + rule-fixtures); confirm green before tagging.
3. (Optional) run `release.yml` via `workflow_dispatch` for a full dry-run (gate
   + build; publishes nothing). Skipped for rc.1 — CI was green and the build
   had been dry-run locally.
4. Tag from the RC branch and push the tag: `git tag -a v<version> -m "…"` then
   `git push --no-follow-tags origin refs/tags/v<version>`. The tag push runs
   `release.yml`: gate → build byte-identical artifact + `SHA256SUMS` +
   compat-matrix snapshot → publish the GitHub Release. A version containing a
   hyphen is auto-marked **prerelease**.
   - `release.yml` asserts the tag equals the artifact `Tool-Version` header, so
     the tag must match exactly.
   - No merge to `main` is involved; the workflow triggers on `tags: v*`.

## Post-RC state and next steps
`v1.0.0-rc.1` shipped. Outstanding work, in rough order:
1. **Verify the published asset's SHA256** against the local reproducible build
   `2ae4c475…` (344,857 bytes).
2. **Open the Tier-2 attestation issues for this RC.** D-164 requires one per RC
   and `compatibility/tier2-attestation.md` calls it auto-opened, but **nothing
   implements that** — `release.yml` creates no issues, so it is a manual step.
   Since D-192 this no longer gates v1.0, but it is the only thing that prompts
   anyone to attest — the targets stay *Unverified* until someone opens them.
3. Collect RC feedback; fix anything it surfaces on this branch.
4. Before **final** `v1.0.0`: resolve the tracked items above, bump `ToolVersion`
   → `1.0.0`, add a CHANGELOG `1.0.0` entry dated on the day it ships, and run
   the validation wave again.

## Repo map
- Artifact: `sp_SQLFlightRecorder.sql` (repo root).
- Generators: `scripts/gen-rule-docs.py`, `gen-mode-docs.py`,
  `gen-compat-matrix.py` (each `--check`-guarded in CI).
- Gates/build: `scripts/check-doc-coverage.sh`, `build-release-artifact.sh`,
  `run-static-analysis.sh`, `run-local-tier1.sh`.
- Tests: `tests/rules/` (fixtures+golden), `tests/static-analysis/` (linter),
  `tests/upgrade/`, `tests/perf/` (cost+soak), `tests/compat/` (attestation
  evidence).
- Workflows: `.github/workflows/ci-tier1.yml` (blocking), `release.yml` (tag/
  dispatch), `ci-cost.yml` + `ci-soak.yml` (nightly, non-blocking).
- Key docs: [design.md](design.md) (§1–§13), [decisions.md](decisions.md),
  [implementation-plan-v1.0.0-rc.md](implementation-plan-v1.0.0-rc.md),
  [release-readiness-v1.0.0-rc.1.md](release-readiness-v1.0.0-rc.1.md),
  [wording-lock-review.md](wording-lock-review.md),
  [compatibility/matrix.md](compatibility/matrix.md),
  [compatibility/tier2-attestation.md](compatibility/tier2-attestation.md),
  [compatibility/support-policy.md](compatibility/support-policy.md).

## Re-validate anytime
```bash
bash scripts/check-doc-coverage.sh
python tests/static-analysis/lint.py sp_SQLFlightRecorder.sql
python tests/static-analysis/lint.py --self-test
python scripts/gen-rule-docs.py --check
python scripts/gen-mode-docs.py --check
python scripts/gen-compat-matrix.py --check
bash scripts/build-release-artifact.sh --version 1.0.0-rc.1   # needs bash
bash tests/upgrade/run-upgrade.sh                             # needs Docker + git
```
