# Campaign Brief: HOL26 Holiday Win-Back

| | |
|---|---|
| **Campaign ID** | HOL26 |
| **Requested by** | Retail Marketing (CRM team) |
| **Selection date** | 2026-11-01 |
| **In-home / deploy** | Email and SMS Nov 6, direct mail in-home Nov 10–13 |
| **Channels** | Email (ESP), Direct Mail (mail house), SMS |
| **Goal** | Bring back customers who have slowed down or stopped buying before the holiday peak |

## Requirements as gathered

These are the questions asked in the kickoff with Marketing and Analytics, and the answers that became the build rules.

| Question | Answer | Where it lives |
|---|---|---|
| Who is the target? | Active accounts whose last purchase was 91–365 days before the selection date | `run_params.min/max_recency_days` |
| How do we define "high value"? | $500+ net sales in the last 24 months, **or** Gold/Platinum loyalty tier | `run_params.high_value_threshold` |
| What do returns do? | Reduce net sales, but a return is not a "purchase" for recency | `02_customer_metrics` |
| Contact fatigue rule? | Skip anyone contacted by any campaign in the last 14 days | `run_params.fatigue_days` |
| Duplicate handling? | Same email = same person; otherwise match on name + address + ZIP. Keep the higher-value record | `03_build_audience` step 8 |
| Channel priority? | Email first (cheapest), then direct mail, then SMS, based on opt-in and valid contact data | step 9 |
| Measurement? | 10% random holdout in every segment so lift can be read by segment | `run_params.holdout_pct` |
| Expected volume? | Marketing budgeted for roughly 6,000–12,000 contacts | QA10 |

## Segments and offers

| Segment | Definition | Offer code (test only) |
|---|---|---|
| S1 Lapsed High Value | 181–365 days, high value | HOL26-25OFF100 ($25 off $100) |
| S2 Lapsed Standard | 181–365 days | HOL26-20PCT (20% off) |
| S3 At-Risk High Value | 91–180 days, high value | HOL26-15OFF75 ($15 off $75) |
| S4 At-Risk Standard | 91–180 days | HOL26-10PCT (10% off) |

Cell code format: `CAMPAIGN-SEGMENT-CHANNEL-TEST/CONTROL`, for example `HOL26-S1-EM-T`.

## Suppressions (applied in this order)

1. Closed or deceased accounts
2. No purchase history
3. Outside the 91–365 day recency window
4. Legal / fraud / bankruptcy hold (compliance file)
5. Employees (HR file)
6. Global do-not-contact
7. Contacted in the last 14 days
8. Duplicates
9. No opted-in channel with valid contact data

Email bounces from the ESP are not a full suppression; they only block the email channel, so a bounced customer can still be mailed if they're opted in to direct mail.

## Deliverables

| File | Recipient |
|---|---|
| `HOL26_audience_YYYYMMDD_EM.csv` | ESP |
| `HOL26_audience_YYYYMMDD_DM.csv` | Mail house |
| `HOL26_audience_YYYYMMDD_SMS.csv` | SMS platform |
| `HOL26_audience_YYYYMMDD_HOLDOUT.csv` | Kept internally for response measurement, never sent |
| `HOL26_audience_YYYYMMDD.ctl` | Sent with each file: record counts and MD5 checksums |
| Waterfall and count report | Marketing, for count sign-off before release |
