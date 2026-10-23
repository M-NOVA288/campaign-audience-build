#!/usr/bin/env bash
#==============================================================================
# run_campaign.sh - end-to-end campaign list build
#
#   1. Pre-flight: input files present, non-empty, expected headers
#   2. Build the audience (SQL engine locally, or SAS batch in production)
#   3. Scan the log / stop on any QA failure
#   4. Split the output into per-channel vendor files + holdout file
#   5. Write a control (.ctl) file with record counts and checksums
#
# Usage:
#   unix/run_campaign.sh [-c CAMPAIGN_ID] [-d AS_OF_YYYY-MM-DD] [-e sql|sas]
#
# Examples:
#   unix/run_campaign.sh                              # HOL26, 2026-11-01, SQL
#   unix/run_campaign.sh -c HOL26 -d 2026-11-01 -e sas
#==============================================================================
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT
cd "$PROJECT_ROOT"

CAMPAIGN_ID="HOL26"
AS_OF_DATE="2026-11-01"
ENGINE="sql"

# selection rules (SAS reads the same values from sas/00_config.sas)
MIN_RECENCY=91
MAX_RECENCY=365
FATIGUE_DAYS=14
HV_THRESHOLD=500
HOLDOUT_PCT=10

while getopts ":c:d:e:h" opt; do
  case $opt in
    c) CAMPAIGN_ID="$OPTARG" ;;
    d) AS_OF_DATE="$OPTARG" ;;
    e) ENGINE="$OPTARG" ;;
    h) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option -$OPTARG" >&2; exit 2 ;;
  esac
done

if ! [[ "$AS_OF_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "AS_OF_DATE must be YYYY-MM-DD (got '$AS_OF_DATE')" >&2; exit 2
fi
if [[ "$ENGINE" != "sql" && "$ENGINE" != "sas" ]]; then
  echo "ENGINE must be sql or sas (got '$ENGINE')" >&2; exit 2
fi

RUN_YMD="${AS_OF_DATE//-/}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
DATA_DIR="$PROJECT_ROOT/data"
OUT_DIR="$PROJECT_ROOT/output"
LOG_DIR="$PROJECT_ROOT/logs"
DB="$PROJECT_ROOT/sasdata/${CAMPAIGN_ID}.db"
LOG="$LOG_DIR/${CAMPAIGN_ID}_${RUN_TS}.log"
BASE="$OUT_DIR/${CAMPAIGN_ID}_audience_${RUN_YMD}"

mkdir -p "$OUT_DIR" "$LOG_DIR" "$PROJECT_ROOT/sasdata"

# md5sum on Linux, md5 -q on macOS
checksum() { if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }

log()  { printf '%s  %-5s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" | tee -a "$LOG"; }
die()  { log ERROR "$1"; log ERROR "Job FAILED. See $LOG"; exit 1; }
trap 'die "Unexpected failure at line $LINENO: $BASH_COMMAND"' ERR

log INFO "=== ${CAMPAIGN_ID} campaign build | as-of ${AS_OF_DATE} | engine=${ENGINE} ==="

#------------------------------------------------------------------------------
# 1. Pre-flight checks on the input extracts
#------------------------------------------------------------------------------
# file|expected header  (plain list, so it runs on macOS bash 3.2 too)
EXPECTED_HEADERS="customers.csv|customer_id,first_name,last_name,email,phone,address,city,state,zip,birth_date,enroll_date,loyalty_tier,account_status
contact_preferences.csv|customer_id,email_opt_in,sms_opt_in,dm_opt_in,do_not_contact,updated_date
transactions.csv|txn_id,customer_id,txn_date,channel,amount,category
contact_history.csv|customer_id,campaign_id,channel,contact_date,responded,response_date
suppress_email_bounces.csv|email
suppress_legal_hold.csv|customer_id,reason
suppress_employees.csv|customer_id"

while IFS='|' read -r f expected; do
  path="$DATA_DIR/$f"
  [[ -s "$path" ]] || die "Missing or empty input file: $path"
  header="$(head -1 "$path" | tr -d '\r')"
  [[ "$header" == "$expected" ]] || die "Unexpected header in $f: $header"
  rows=$(( $(wc -l < "$path") - 1 ))
  log INFO "$(printf 'Input %-28s %9s rows' "$f" "$rows")"
done <<< "$EXPECTED_HEADERS"

# no duplicate keys in the customer master
dupes=$(tail -n +2 "$DATA_DIR/customers.csv" | cut -d, -f1 | sort | uniq -d | wc -l)
[[ "$dupes" -eq 0 ]] || die "customers.csv has $dupes duplicate customer_id values"
log INFO "Pre-flight checks passed"

#------------------------------------------------------------------------------
# 2-3. Build the audience
#------------------------------------------------------------------------------
if [[ "$ENGINE" == "sas" ]]; then
  command -v sas >/dev/null || die "sas executable not found on PATH"
  SAS_LOG="$LOG_DIR/${CAMPAIGN_ID}_${RUN_TS}_sas.log"
  log INFO "Running SAS batch: sas/run_campaign.sas"
  set +e
  sas -sysin sas/run_campaign.sas -sysparm "${CAMPAIGN_ID}|${AS_OF_DATE}" \
      -log "$SAS_LOG" -print "$LOG_DIR/${CAMPAIGN_ID}_${RUN_TS}_sas.lst" -noterminal
  rc=$?
  set -e
  "$PROJECT_ROOT/unix/check_sas_log.sh" "$SAS_LOG" | tee -a "$LOG" || die "SAS log check failed"
  # SAS return codes: 0 = clean, 1 = warnings, 2+ = errors / QA abort
  [[ $rc -le 1 ]] || die "SAS ended with return code $rc"
  log INFO "SAS completed with return code $rc"
else
  run_sql() {
    log INFO "Running $1"
    python3 scripts/run_sql.py "$DB" "$@" >> "$LOG" 2>&1 || die "$1 failed"
  }

  log INFO "Loading raw extracts into $DB"
  python3 scripts/load_db.py "$DB" "$DATA_DIR" sql/01_create_tables.sql >> "$LOG" 2>&1 \
    || die "Load failed"

  PARAMS_SQL="$LOG_DIR/${CAMPAIGN_ID}_${RUN_TS}_params.sql"
  cat > "$PARAMS_SQL" <<EOF
DROP TABLE IF EXISTS run_params;
CREATE TABLE run_params AS
SELECT '${CAMPAIGN_ID}' AS campaign_id,
       '${AS_OF_DATE}'  AS as_of_date,
       ${MIN_RECENCY}   AS min_recency_days,
       ${MAX_RECENCY}   AS max_recency_days,
       ${FATIGUE_DAYS}  AS fatigue_days,
       ${HV_THRESHOLD}  AS high_value_threshold,
       ${HOLDOUT_PCT}   AS holdout_pct;
SELECT * FROM run_params;
EOF
  run_sql "$PARAMS_SQL"
  run_sql sql/02_customer_metrics.sql
  run_sql sql/03_build_audience.sql

  # QA gate: export results and stop if any check failed
  QA_CSV="$OUT_DIR/${CAMPAIGN_ID}_qa_results_${RUN_YMD}.csv"
  run_sql sql/04_qa_checks.sql --export "$QA_CSV"
  fails=$(awk -F, 'NR>1 && $NF=="FAIL"' "$QA_CSV" | wc -l)
  if [[ "$fails" -gt 0 ]]; then
    awk -F, 'NR>1 && $NF=="FAIL" {print "  " $1 " " $2}' "$QA_CSV" | tee -a "$LOG"
    die "$fails QA check(s) failed - files will NOT be released"
  fi
  log INFO "QA gate passed ($(( $(wc -l < "$QA_CSV") - 1 )) checks)"

  run_sql sql/05_count_report.sql
  python3 scripts/run_sql.py "$DB" sql/06_export_file.sql --quiet --export "${BASE}.csv" \
    >> "$LOG" 2>&1 || die "Export failed"
  # keep a copy of the waterfall for the stakeholder update
  python3 scripts/run_sql.py "$DB" /dev/stdin --quiet \
    --export "$OUT_DIR/${CAMPAIGN_ID}_waterfall_${RUN_YMD}.csv" >> "$LOG" 2>&1 \
    <<< "SELECT * FROM campaign_waterfall ORDER BY step;" || die "Waterfall export failed"
fi

[[ -s "${BASE}.csv" ]] || die "Expected output not found: ${BASE}.csv"

#------------------------------------------------------------------------------
# 4. Split into vendor files: one per channel, control group held back
#    (columns: 5 = channel, 6 = test_control)
#------------------------------------------------------------------------------
rm -f "${BASE}"_EM.csv "${BASE}"_DM.csv "${BASE}"_SMS.csv "${BASE}"_HOLDOUT.csv
awk -F, -v base="$BASE" '
  NR == 1 { hdr = $0; next }
  {
    f = ($6 == "C") ? base "_HOLDOUT.csv" : base "_" $5 ".csv"
    if (!(f in seen)) { print hdr > f; seen[f] = 1 }
    print > f
  }' "${BASE}.csv"

#------------------------------------------------------------------------------
# 5. Control file: counts + checksums the vendor uses to confirm receipt
#------------------------------------------------------------------------------
CTL="${BASE}.ctl"
{
  echo "campaign_id|${CAMPAIGN_ID}"
  echo "as_of_date|${AS_OF_DATE}"
  echo "created|$(date '+%Y-%m-%d %H:%M:%S')"
  echo "file|records|md5"
  for f in "${BASE}"_EM.csv "${BASE}"_DM.csv "${BASE}"_SMS.csv "${BASE}"_HOLDOUT.csv; do
    [[ -f "$f" ]] || continue
    n=$(( $(wc -l < "$f") - 1 ))
    sum=$(checksum "$f")
    echo "$(basename "$f")|${n}|${sum}"
  done
} > "$CTL"

total_in=$(( $(wc -l < "${BASE}.csv") - 1 ))
total_split=$(awk -F'|' 'NR>4 {s += $2} END {print s+0}' "$CTL")
[[ "$total_in" -eq "$total_split" ]] \
  || die "Split files ($total_split) do not reconcile to master file ($total_in)"

log INFO "Output files:"
tail -n +5 "$CTL" | while IFS='|' read -r f n _; do
  log INFO "$(printf '  %-40s %8s records' "$f" "$n")"
done
log INFO "Master $total_in records = split total $total_split  [reconciled]"

# Optional: run the standalone file checks a vendor-release reviewer would run
"$PROJECT_ROOT/unix/qa_file_checks.sh" "$BASE" | tee -a "$LOG" || die "File checks failed"

log INFO "=== ${CAMPAIGN_ID} build complete. Log: $LOG ==="
