# Campaign QA Checklist

Every list goes through three layers of QA before release. The first two are automated and will stop the job; the third is a short manual review.

## 1. Pre-flight (Unix, before the build)
`unix/run_campaign.sh`

- [x] All seven input extracts present and non-empty
- [x] Each file's header matches the expected layout (catches a changed upstream extract)
- [x] Row counts logged for every input
- [x] No duplicate `customer_id` in the customer master

## 2. Audience QA (SQL / SAS, after the build)
`sql/04_qa_checks.sql` and `sas/04_qa_checks.sas` run the same ten checks. Any FAIL stops the job and no files are written.

| ID | Check | Why it matters |
|---|---|---|
| QA01 | No duplicate `customer_id` | One contact per person |
| QA02 | No duplicate emails in the email file | The ESP would send twice |
| QA03 | No legal hold, employee, DNC or bounced records | Compliance |
| QA04 | Every record opted in to its assigned channel | CAN-SPAM / TCPA exposure |
| QA05 | Valid email, address or phone for the assigned channel | Wasted postage and failed sends |
| QA06 | Every record inside the recency window | Selection logic did what the brief says |
| QA07 | Cell code on every record; offer code on test, none on control | Response tracking and holdout integrity |
| QA08 | Control group 10% ±1.5 pts in every segment | Lift can be measured by segment |
| QA09 | Waterfall reconciles to final count | Nothing was lost or double-counted |
| QA10 | Audience size within the 6,000–12,000 budget range | Catches a broken join or a wrong date |

## 3. File QA (Unix, on the vendor files)
`unix/qa_file_checks.sh`

- [x] Same column count on every row (catches stray delimiters)
- [x] No duplicate customers within a file, or across files
- [x] Record counts match the `.ctl` control file
- [x] Email file: every email well-formed, no duplicates
- [x] Mail file: address present and 5-digit ZIP
- [x] SMS file: 10-digit phone
- [x] No control records in any vendor file; holdout file contains only control

For SAS runs, `unix/check_sas_log.sh` also scans the log for ERROR, WARNING, uninitialized variables, many-to-many merges, invalid data and truncation.

## Manual review before release

- [ ] Waterfall reviewed with Marketing; large drops explained
- [ ] Counts by cell match what was budgeted
- [ ] Spot-check 10 random records from each file against the source tables
- [ ] Seed records added per vendor instructions
- [ ] Offer codes confirmed with the promotions team
- [ ] Count sign-off received in writing before files are transmitted

## Proving the checks work

The checks were tested by breaking the output on purpose:

- Inserting a duplicate row and a do-not-contact customer into the audience → QA01, QA02, QA03 and QA09 all FAIL
- Copying a control record into the mail file → the file checks catch the count mismatch, the control record, the missing offer code and the cross-file duplicate
- Changing a ZIP to 4 digits in the mail file → "missing address or bad ZIP" FAILS
- Feeding a log with an ERROR, a truncation warning and missing values to `check_sas_log.sh` → all flagged, exit code 1
