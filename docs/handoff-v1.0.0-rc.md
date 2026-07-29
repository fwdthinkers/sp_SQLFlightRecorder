# Handoff — v1.0.0 release record

The record of how `sp_SQLFlightRecorder` reached **v1.0.0**, and what was
deliberately carried past it. Started 2026-07-21 as the RC handoff; closed out
2026-07-29 when v1.0.0 shipped. This is a hub; it links the authoritative docs
rather than duplicating them.

## Snapshot — RELEASED
| | |
|---|---|
| Status | ✅ **v1.0.0 released 2026-07-29** |
| Artifact version | `ToolVersion 1.0.0` (build date 2026-07-29), `SchemaVersion 0.4.0`, `RulePackVersion 0.4.3` |
| Tags | `v1.0.0` on `49e10ac`; `v1.0.0-rc.1` on `1f6d056` |
| Published | GitHub release **`v1.0.0`** (full release), plus the earlier `v1.0.0-rc.1` prerelease |
| `main` | `v1.0.0-rc` **merged** to `main` |
| Contract | v1.x output contract frozen from here — see [compatibility/support-policy.md](compatibility/support-policy.md) |

**Standing rule (unchanged):** the owner authorizes every push, merge, tag, and
publish.

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

## Gates before final v1.0.0 — all closed
Every §11.6 gate was met or formally removed before the release. No public-facing
`TODO` placeholder remains anywhere.

`ToolVersion` is `1.0.0` (build date 2026-07-29), the CHANGELOG carries
`[1.0.0] - 2026-07-29`, validation and the upgrade harness were green — including
the genuine rc.1 → 1.0.0 path — the release process was dry-run twice (D-173:
the rc.1 tag run, and `release` #2 via `workflow_dispatch`, Success in 54s
publishing nothing), and the final `v1.0.0` release workflow then ran and
published successfully.

**Shipped knowingly unverified — recorded, never claimed as passing:** Tier-2
targets are *Unverified* (D-192), and there is no cost or soak evidence (D-194).
See "Post-1.0 follow-ups" below.

Optional and set aside by the owner: `tests/upgrade/artifacts/v0.4.0.sql`.

**Resolved 2026-07-29:** conduct path documented as the designated v1.0.0 route
(owner via GitHub maintainer channels; no address invented; single-maintainer
impartiality limit stated openly). Wording sign-off rule settled by **D-193**.
Hotfix process **rehearsed** (D-174) — branch `hotfix/rehearsal-v1.0.0-rc.1`
from tag `v1.0.0-rc.1`, fix `94969cd`, validation green, forward-merged as
`638df8f`; nothing tagged, published, or pushed. Cost-regression and soak are
**not** gates (**D-194**) and have **no** evidence — neither nightly has ever
run, because scheduled workflows fire only from the default branch and those two
workflow files exist only on `v1.0.0-rc`.

**Resolved 2026-07-29 — private security contact.** `SECURITY.md` names
`sqlflightrecorder-security@forwardthinkersconsulting.com` as the dedicated
private reporting channel. GitHub private vulnerability reporting is **not**
exposed in this repository's settings; the doc states that rather than pointing
reporters at a button that does not exist.

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

## Post-1.0 follow-ups
`v1.0.0` shipped 2026-07-29. Outstanding work, in rough order:

1. **Verify the published `v1.0.0` asset's SHA256** against the local
   reproducible build `dfb46a5428cce98291bcf30ca27a17fb0c0d5242e2d7be97ccfbc74e6a0e2989`
   (344,863 bytes). Same check for the earlier rc.1 asset (`2ae4c475…`,
   344,857 bytes) was never completed either.
2. **Open the Tier-2 attestation issues.** D-164 requires one per release and
   `compatibility/tier2-attestation.md` calls it auto-opened, but **nothing
   implements that** — `release.yml` creates no issues, so it is a manual step.
   Per D-192 this does not gate anything, but it is the only mechanism that
   prompts anyone to attest: the targets stay *Unverified* until someone opens
   them. Five issue bodies were drafted during release prep.
3. **Cost and soak now have somewhere to run.** D-194 recorded that the
   nightlies had never fired because scheduled workflows run only from the
   default branch and `ci-cost.yml`/`ci-soak.yml` existed only on `v1.0.0-rc`.
   That condition is now cleared — `main` carries them, so the crons can fire
   for the first time. Worth checking the first nightly results, and running
   each once via `workflow_dispatch` if you don't want to wait.
4. **Tier-2 attestation automation** — deliberately not built before 1.0. If
   added, prefer a separate workflow on `release: published` with `issues:
   write`, idempotent via a label search, so it cannot break publishing.
5. Collect v1.0.0 user feedback; hotfixes follow D-174 (rehearsed — see the
   readiness report).

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
