#!/usr/bin/env bash
#==============================================================================
# check_sas_log.sh - scan a SAS log for problems that don't always stop a job
# but should never reach production output.
#
#   unix/check_sas_log.sh logs/HOL26_20261101_060000_sas.log
#
# Exit 0 = clean, 1 = issues found
#==============================================================================
set -uo pipefail

SAS_LOG="${1:?usage: check_sas_log.sh <sas.log>}"
[[ -f "$SAS_LOG" ]] || { echo "SAS log not found: $SAS_LOG"; exit 1; }

# pattern | label
PATTERNS='^ERROR|ERROR
^WARNING|WARNING
uninitialized|Uninitialized variable
MERGE statement has more than one data set with repeats of BY values|Many-to-many merge
Missing values were generated|Missing values generated
Invalid data for|Invalid data on input
Invalid argument|Invalid function argument
truncated|Possible truncation
The query requires remerging summary statistics|SQL remerge
Division by zero|Division by zero
QA .* FAILED|QA check failed'

issues=0
echo "SAS log check: $(basename "$SAS_LOG")"
while IFS='|' read -r pat label; do
  n=$(grep -Eci "$pat" "$SAS_LOG" || true)
  if [[ "$n" -gt 0 ]]; then
    printf '  %-28s %5d   e.g. line %s\n' "$label" "$n" \
      "$(grep -Eni "$pat" "$SAS_LOG" | head -1 | cut -d: -f1)"
    issues=$((issues + n))
  fi
done <<< "$PATTERNS"

if [[ $issues -gt 0 ]]; then
  echo "SAS log check: $issues issue line(s) found - review before release"
  exit 1
fi
echo "SAS log check: clean"
