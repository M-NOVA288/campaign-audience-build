#!/usr/bin/env bash
#==============================================================================
# qa_file_checks.sh - independent checks on the vendor files, using only
# standard Unix tools. Run by run_campaign.sh, or by hand before release:
#
#   unix/qa_file_checks.sh output/HOL26_audience_20261101
#
# File layout (comma-delimited, header row):
#   1 campaign_id  2 cell_code  3 customer_id  4 segment  5 channel
#   6 test_control 7 offer_code 8 first_name   9 last_name 10 email
#   11 phone  12 address  13 city  14 state  15 zip  16 loyalty_tier
#==============================================================================
set -uo pipefail

BASE="${1:?usage: qa_file_checks.sh <path/to/CAMPAIGN_audience_YYYYMMDD>}"
CTL="${BASE}.ctl"
FAILS=0

check() {   # check "<description>" <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    printf '  PASS  %-66s %s\n' "$1" "$2"
  else
    printf '  FAIL  %-66s got %s, expected %s\n' "$1" "$2" "$3"
    FAILS=$((FAILS + 1))
  fi
}

echo "File checks: $(basename "$BASE")"
[[ -f "$CTL" ]] || { echo "  FAIL  control file missing: $CTL"; exit 1; }

for f in "${BASE}"_EM.csv "${BASE}"_DM.csv "${BASE}"_SMS.csv "${BASE}"_HOLDOUT.csv; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f")"
  body() { tail -n +2 "$f"; }

  # every row has the same number of fields as the header (catches stray commas)
  check "$name: consistent column count" \
        "$(awk -F, '{print NF}' "$f" | sort -u | wc -l | tr -d ' ')" "1"

  # one row per customer
  check "$name: duplicate customer_id" \
        "$(body | cut -d, -f3 | sort | uniq -d | wc -l | tr -d ' ')" "0"

  # record count agrees with the control file
  check "$name: record count matches .ctl" \
        "$(( $(wc -l < "$f") - 1 ))" "$(awk -F'|' -v n="$name" '$1==n {print $2}' "$CTL")"

  case "$name" in
    *_EM.csv)
      check "$name: missing or malformed email" \
            "$(body | awk -F, '$10 !~ /^[^@ ]+@[^@ ]+\.[^@ ]+$/' | wc -l | tr -d ' ')" "0"
      check "$name: duplicate email" \
            "$(body | cut -d, -f10 | sort | uniq -d | wc -l | tr -d ' ')" "0" ;;
    *_DM.csv)
      check "$name: missing address or bad ZIP" \
            "$(body | awk -F, '$12 == "" || $15 !~ /^[0-9][0-9][0-9][0-9][0-9]$/' | wc -l | tr -d ' ')" "0" ;;
    *_SMS.csv)
      check "$name: phone not 10 digits" \
            "$(body | awk -F, '$11 !~ /^[0-9]+$/ || length($11) != 10' | wc -l | tr -d ' ')" "0" ;;
  esac

  if [[ "$name" == *_HOLDOUT.csv ]]; then
    check "$name: only control records" \
          "$(body | awk -F, '$6 != "C"' | wc -l | tr -d ' ')" "0"
  else
    check "$name: no control records sent to vendor" \
          "$(body | awk -F, '$6 != "T"' | wc -l | tr -d ' ')" "0"
    check "$name: offer code on every record" \
          "$(body | awk -F, '$7 == ""' | wc -l | tr -d ' ')" "0"
  fi
done

# a customer must appear in exactly one file
check "No customer in more than one file" \
      "$(for f in "${BASE}"_*.csv; do tail -n +2 "$f" | cut -d, -f3; done | sort | uniq -d | wc -l | tr -d ' ')" "0"

if [[ $FAILS -gt 0 ]]; then
  echo "File checks: $FAILS FAILED"
  exit 1
fi
echo "File checks: all passed"
