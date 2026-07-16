#!/usr/bin/env bash
# =============================================================================
# tests/rules/run-rule-fixtures.sh
# -----------------------------------------------------------------------------
# Positive + negative fixtures for the v0.4.2 rules (D-160), plus the §7.13
# fold behavior. Each case seeds FR_* rows with fixed shapes, runs Report, and
# asserts the finding fires (positive) or does not (negative) by exact RuleId
# column match. Repository-only; no live workload needed (D-081).
#
# Docker/local-dev only (D-148). Usage:
#   ./tests/rules/run-rule-fixtures.sh [image]
# Default image: mcr.microsoft.com/mssql/server:2022-latest
# Exit code: 0 if all cases pass, 1 otherwise.
# =============================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1

IMAGE="${1:-mcr.microsoft.com/mssql/server:2022-latest}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
SQL_FILE="${REPO_ROOT}/sp_SQLFlightRecorder.sql"
[ -n "$(command -v cygpath 2>/dev/null)" ] && SQL_FILE_HOST="$(cygpath -m "${SQL_FILE}")" || SQL_FILE_HOST="${SQL_FILE}"
PW='FlightRecorder!RuleFx'
C="fr-rulefx"
PASS=0; FAIL=0

docker rm -f "${C}" >/dev/null 2>&1 || true
trap 'docker rm -f "${C}" >/dev/null 2>&1 || true' EXIT

docker run -d --name "${C}" -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=${PW}" -e MSSQL_PID=Developer "${IMAGE}" >/dev/null
SQLTOOL=""; CFLAG=""
for _ in $(seq 1 40); do
  if docker exec "${C}" ls /opt/mssql-tools18/bin/sqlcmd >/dev/null 2>&1; then SQLTOOL=/opt/mssql-tools18/bin/sqlcmd; CFLAG="-C"; break
  elif docker exec "${C}" ls /opt/mssql-tools/bin/sqlcmd >/dev/null 2>&1; then SQLTOOL=/opt/mssql-tools/bin/sqlcmd; CFLAG=""; break; fi
  sleep 1
done
for _ in $(seq 1 60); do docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -Q "SELECT 1" -l 5 >/dev/null 2>&1 && break; sleep 2; done

q(){ docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -d FRTest -b -h -1 -W -w 65535 -s'|' -Q "$1"; }
q_master(){ docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -b -Q "$1"; }

q_master "IF DB_ID('FRTest') IS NULL CREATE DATABASE FRTest;" >/dev/null
docker cp "${SQL_FILE_HOST}" "${C}:/tmp/fr.sql" >/dev/null
docker exec "${C}" ${SQLTOOL} ${CFLAG} -S localhost -U sa -P "${PW}" -d FRTest -b -i /tmp/fr.sql >/dev/null 2>&1
q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Install';" >/dev/null

# clean the collector tables + reset disabled rules between cases
reset(){ q "DELETE dbo.FR_Request; DELETE dbo.FR_Wait; DELETE dbo.FR_FileStat; DELETE dbo.FR_InstanceSnapshot; DELETE dbo.FR_QueryStoreTopN; DELETE dbo.FR_Snapshot; EXEC dbo.sp_SQLFlightRecorder @Mode=N'Configure', @ConfigKey=N'DisabledRules', @ConfigValue=N'';" >/dev/null; }
report(){ q "SET NOCOUNT ON; EXEC dbo.sp_SQLFlightRecorder @Mode=N'Report', @OutputFormat=N'FindingsOnly';"; }
# rulecnt <file> <ruleprefix>  — count finding rows whose RuleId column == prefix
rulecnt(){ awk -F'|' -v r="$2" '$6==r{c++}END{print c+0}' "$1"; }
assert(){ # assert <name> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  PASS  $1 ($2)"; PASS=$((PASS+1)); else echo "  FAIL  $1 (got $2, want $3)"; FAIL=$((FAIL+1)); fi
}
two_snaps="DECLARE @t1 datetime2(3)=DATEADD(minute,-3,SYSUTCDATETIME()), @t2 datetime2(3)=SYSUTCDATETIME(); INSERT dbo.FR_Snapshot(SnapshotUtc,InstanceFingerprint) VALUES(@t1,N'FX'),(@t2,N'FX'); DECLARE @s1 bigint; SELECT @s1=MIN(SnapshotId) FROM dbo.FR_Snapshot;"

echo "== FR_R0001 ActiveBlockingChain =="
reset; q "${two_snaps} INSERT dbo.FR_Request(SnapshotId,SnapshotUtc,SessionId,DatabaseId,BlockingSessionId,OpenTransactionCount) VALUES (@s1,@t1,51,5,55,0),(@s1,@t1,52,5,55,0),(@s1,@t1,55,5,0,1);" >/dev/null
report > /tmp/fx.out; assert "positive: lead blocker fires" "$(rulecnt /tmp/fx.out FR_R0001_ActiveBlockingChain)" 1
reset; q "${two_snaps} INSERT dbo.FR_Request(SnapshotId,SnapshotUtc,SessionId,DatabaseId,BlockingSessionId,OpenTransactionCount) VALUES (@s1,@t1,60,5,0,0),(@s1,@t1,61,5,0,0);" >/dev/null
report > /tmp/fx.out; assert "negative: no blocking -> silent" "$(rulecnt /tmp/fx.out FR_R0001_ActiveBlockingChain)" 0

echo "== FR_R0002 LongRunningOpenTransaction =="
reset; q "${two_snaps} INSERT dbo.FR_Request(SnapshotId,SnapshotUtc,SessionId,DatabaseId,OpenTransactionCount) VALUES (@s1,@t1,70,5,1),(@s1+1,@t2,70,5,1);" >/dev/null
report > /tmp/fx.out; assert "positive: open txn spans window" "$(rulecnt /tmp/fx.out FR_R0002_LongRunningOpenTransaction)" 1
reset; q "${two_snaps} INSERT dbo.FR_Request(SnapshotId,SnapshotUtc,SessionId,DatabaseId,OpenTransactionCount) VALUES (@s1+1,@t2,71,5,1);" >/dev/null
report > /tmp/fx.out; assert "negative: single-snapshot open txn" "$(rulecnt /tmp/fx.out FR_R0002_LongRunningOpenTransaction)" 0

echo "== FR_R0004 FileIoLatencySpike =="
reset; q "${two_snaps} INSERT dbo.FR_FileStat(SnapshotId,SnapshotUtc,DatabaseId,FileId,NumOfReads,NumOfBytesRead,IoStallReadMs,NumOfWrites,NumOfBytesWritten,IoStallWriteMs,SizeOnDiskBytes) VALUES (@s1,@t1,5,1,1000,0,1000,0,0,0,0),(@s1+1,@t2,5,1,1100,0,6000,0,0,0,0);" >/dev/null
report > /tmp/fx.out; assert "positive: 50ms/op latency spike" "$(rulecnt /tmp/fx.out FR_R0004_FileIoLatencySpike)" 1
reset; q "${two_snaps} INSERT dbo.FR_FileStat(SnapshotId,SnapshotUtc,DatabaseId,FileId,NumOfReads,NumOfBytesRead,IoStallReadMs,NumOfWrites,NumOfBytesWritten,IoStallWriteMs,SizeOnDiskBytes) VALUES (@s1,@t1,5,1,1000,0,1000,0,0,0,0),(@s1+1,@t2,5,1,2000,0,1050,0,0,0,0);" >/dev/null
report > /tmp/fx.out; assert "negative: low latency (0.05ms/op)" "$(rulecnt /tmp/fx.out FR_R0004_FileIoLatencySpike)" 0

echo "== FR_R0005 MemoryGrantsPending =="
reset; q "${two_snaps} INSERT dbo.FR_Request(SnapshotId,SnapshotUtc,SessionId,DatabaseId,RequestedMemoryKb,GrantedMemoryKb) VALUES (@s1,@t1,80,5,500000,NULL);" >/dev/null
report > /tmp/fx.out; assert "positive: requested, not granted" "$(rulecnt /tmp/fx.out FR_R0005_MemoryGrantsPending)" 1
reset; q "${two_snaps} INSERT dbo.FR_Request(SnapshotId,SnapshotUtc,SessionId,DatabaseId,RequestedMemoryKb,GrantedMemoryKb) VALUES (@s1,@t1,81,5,500000,500000);" >/dev/null
report > /tmp/fx.out; assert "negative: grant satisfied" "$(rulecnt /tmp/fx.out FR_R0005_MemoryGrantsPending)" 0

echo "== FR_R0006 ServerRestartDuringWindow =="
reset; q "${two_snaps} DECLARE @sa datetime2(3)=DATEADD(hour,-5,SYSUTCDATETIME()), @sb datetime2(3)=DATEADD(minute,-1,SYSUTCDATETIME()); INSERT dbo.FR_InstanceSnapshot(SnapshotId,SnapshotUtc,SqlStartTimeUtc) VALUES (@s1,@t1,@sa),(@s1+1,@t2,@sb);" >/dev/null
report > /tmp/fx.out; assert "positive: start time changed" "$(rulecnt /tmp/fx.out FR_R0006_ServerRestartDuringWindow)" 1
reset; q "${two_snaps} DECLARE @sa datetime2(3)=DATEADD(hour,-5,SYSUTCDATETIME()); INSERT dbo.FR_InstanceSnapshot(SnapshotId,SnapshotUtc,SqlStartTimeUtc) VALUES (@s1,@t1,@sa),(@s1+1,@t2,@sa);" >/dev/null
report > /tmp/fx.out; assert "negative: constant start time" "$(rulecnt /tmp/fx.out FR_R0006_ServerRestartDuringWindow)" 0

echo "== §7.13 folds =="
# Pair 1: storm (>=5 blocked) folds R0001/R0002
reset; q "${two_snaps} INSERT dbo.FR_Request(SnapshotId,SnapshotUtc,SessionId,DatabaseId,BlockingSessionId,OpenTransactionCount) VALUES (@s1,@t1,1,5,99,0),(@s1,@t1,2,5,99,0),(@s1,@t1,3,5,99,0),(@s1,@t1,4,5,99,0),(@s1,@t1,5,5,99,0),(@s1,@t1,6,5,99,0),(@s1,@t1,99,5,0,1);" >/dev/null
report > /tmp/fx.out
assert "pair1: R0007 present" "$(rulecnt /tmp/fx.out FR_R0007_BlockingStorm)" 1
assert "pair1: R0001 folded away" "$(rulecnt /tmp/fx.out FR_R0001_ActiveBlockingChain)" 0
# Pair 2: R0024 folds R0005
reset; q "${two_snaps} INSERT dbo.FR_Wait(SnapshotId,SnapshotUtc,WaitType,WaitingTasksCount,WaitTimeMs,MaxWaitTimeMs,SignalWaitTimeMs) VALUES (@s1,@t1,N'RESOURCE_SEMAPHORE',5,10000,100,10); INSERT dbo.FR_Request(SnapshotId,SnapshotUtc,SessionId,DatabaseId,RequestedMemoryKb,GrantedMemoryKb) VALUES (@s1,@t1,80,5,500000,NULL);" >/dev/null
report > /tmp/fx.out
assert "pair2: R0024 present" "$(rulecnt /tmp/fx.out FR_R0024_ResourceSemaphoreWaits)" 1
assert "pair2: R0005 folded away" "$(rulecnt /tmp/fx.out FR_R0005_MemoryGrantsPending)" 0
# Pair 2 headline disabled -> R0005 remains
q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Configure', @ConfigKey=N'DisabledRules', @ConfigValue=N'FR_R0024_ResourceSemaphoreWaits';" >/dev/null
report > /tmp/fx.out
assert "pair2: headline disabled -> R0005 visible" "$(rulecnt /tmp/fx.out FR_R0005_MemoryGrantsPending)" 1

echo "== golden: InstallDemoData findings (deterministic sort, D-068/D-122) =="
# InstallDemoData seeds FR_QueryStoreTopN directly, so the demo findings are
# version-independent. Compare (FindingOrdinal|Severity|Confidence|
# EvidenceType|Category|RuleId) — the run-invariant columns — to the golden.
q "DELETE dbo.FR_Request; DELETE dbo.FR_Wait; DELETE dbo.FR_FileStat; DELETE dbo.FR_InstanceSnapshot; DELETE dbo.FR_QueryStoreTopN; DELETE dbo.FR_Deadlock; DELETE dbo.FR_PlanCacheSummary; DELETE dbo.FR_Snapshot;" >/dev/null
q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Configure', @ConfigKey=N'DisabledRules', @ConfigValue=N'';" >/dev/null
q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'InstallDemoData';" >/dev/null
report | awk -F'|' 'NF>=6 && $1 ~ /^[0-9]+$/ {print $1"|"$2"|"$3"|"$4"|"$5"|"$6}' > /tmp/golden-actual.tsv
if diff -q "${SCRIPT_DIR}/golden-demo-findings.tsv" /tmp/golden-actual.tsv >/dev/null 2>&1; then
  echo "  PASS  golden demo findings match ($(wc -l < /tmp/golden-actual.tsv | tr -d ' ') rows)"; PASS=$((PASS+1))
else
  echo "  FAIL  golden demo findings differ:"; diff "${SCRIPT_DIR}/golden-demo-findings.tsv" /tmp/golden-actual.tsv | sed 's/^/    /'; FAIL=$((FAIL+1))
fi

echo ""
echo "RULE FIXTURES: ${PASS} passed, ${FAIL} failed."
[ "${FAIL}" -eq 0 ]
