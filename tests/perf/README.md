# Performance harnesses (cost regression + soak)

Out-of-band, **non-blocking** performance tooling. These never run on
push/pull_request and never gate a PR or the v1.0.0-rc — they run nightly and on
demand (`.github/workflows/ci-cost.yml`, `.github/workflows/ci-soak.yml`) and
are runnable locally with Docker. Build-pipeline only (D-148); nothing here runs
on a user's SQL Server.

Both scripts are self-contained: each starts and tears down its own SQL Server
container, installs the procedure, and drives a workload.

## Cost regression — `run-cost-regression.sh` (D-143)
Repeated `Collect` timing with two checks:

- **Hard:** no single `Collect` may exceed **10 s**. Stable across runners, so
  always enforced.
- **Soft:** mean `Collect` time vs the optional baseline
  `baseline-collect-ms.txt`; a **>2%** slowdown is reported. Hosted runners are
  noisy, so this only fails under `--strict`.

```bash
./tests/perf/run-cost-regression.sh [image] [iterations] [--strict]
# e.g. ./tests/perf/run-cost-regression.sh mcr.microsoft.com/mssql/server:2022-latest 20
```

To arm the 2% check, run on trusted/stable infra and write the reported mean to
`baseline-collect-ms.txt` (a single integer, milliseconds). Per **D-143** the
strict >2% comparison becomes a **PR gate at GA** once the baseline and
thresholds are calibrated; for v1.0.0-rc it is out-of-band and advisory.

## Soak — `run-soak.sh` (D-145)
Drives many `Collect` cycles and asserts the tool stays healthy under sustained
use:

- no `FR_RunLogStep` rows land in `Status = 'Error'` (collector isolation holds,
  D-009);
- `Report` stays under **5 s** throughout;
- `Purge` keeps repo growth bounded — every few cycles half the snapshots are
  backdated past retention and `Purge` must reap them (D-141).

```bash
./tests/perf/run-soak.sh [image] [cycles]     # default 60 cycles
```

**D-145** specifies a 24 h out-of-band soak. A full day exceeds a hosted
runner's job limit, so CI runs a scaled proxy nightly (60 cycles) and the full
24 h soak is run out-of-band on dedicated infra before a release; failures are
handled in release planning (D-145).
