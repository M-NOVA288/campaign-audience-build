-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 02 · QA gate and count report (Databricks SQL)
-- MAGIC
-- MAGIC The same ten release checks as `sql/04_qa_checks.sql`, written in Databricks SQL.
-- MAGIC The gate cell calls `raise_error()` if any check fails, so a Databricks Job stops here and
-- MAGIC nothing downstream runs.
-- MAGIC
-- MAGIC If you used a different catalog or schema in notebooks 00 and 01, change the `USE` line below.

-- COMMAND ----------

USE workspace.campaign;

-- COMMAND ----------

CREATE OR REPLACE TABLE qa_results AS

-- QA01 one row per customer
SELECT 'QA01' AS check_id, 'No duplicate customer_id in audience' AS check_name,
       '0' AS expected, CAST(COUNT(*) - COUNT(DISTINCT customer_id) AS STRING) AS actual,
       IF(COUNT(*) = COUNT(DISTINCT customer_id), 'PASS', 'FAIL') AS status
FROM campaign_audience

UNION ALL
-- QA02 no duplicate emails to the ESP
SELECT 'QA02', 'No duplicate email addresses in email channel', '0',
       CAST(COUNT(*) - COUNT(DISTINCT email) AS STRING),
       IF(COUNT(*) = COUNT(DISTINCT email), 'PASS', 'FAIL')
FROM campaign_audience WHERE channel = 'EM'

UNION ALL
-- QA03 no suppressed records leaked through
SELECT 'QA03', 'No suppressed records in audience (legal/employee/DNC/bounce)', '0',
       CAST(COUNT(*) AS STRING), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM campaign_audience a
WHERE a.customer_id IN (SELECT customer_id FROM suppress_legal_hold)
   OR a.customer_id IN (SELECT customer_id FROM suppress_employees)
   OR a.customer_id IN (SELECT customer_id FROM contact_preferences WHERE do_not_contact = 1)
   OR (a.channel = 'EM' AND a.email IN (SELECT lower(trim(email)) FROM suppress_email_bounces))

UNION ALL
-- QA04 opt-in compliance by channel
SELECT 'QA04', 'Every record opted in to its assigned channel', '0',
       CAST(COUNT(*) AS STRING), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM campaign_audience a JOIN contact_preferences p USING (customer_id)
WHERE (a.channel = 'EM'  AND p.email_opt_in = 0)
   OR (a.channel = 'DM'  AND p.dm_opt_in    = 0)
   OR (a.channel = 'SMS' AND p.sms_opt_in   = 0)

UNION ALL
-- QA05 usable contact data for the assigned channel
SELECT 'QA05', 'Valid email / address / phone for assigned channel', '0',
       CAST(COUNT(*) AS STRING), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM campaign_audience
WHERE (channel = 'EM'  AND NOT coalesce(email RLIKE '^[^@ ]+@[^@ ]+[.][^@ ]+$', false))
   OR (channel = 'DM'  AND (address IS NULL OR NOT coalesce(zip RLIKE '^[0-9]{5}$', false)))
   OR (channel = 'SMS' AND NOT coalesce(phone RLIKE '^[0-9]{10}$', false))

UNION ALL
-- QA06 selection criteria respected
SELECT 'QA06', 'All records inside recency window', '0',
       CAST(COUNT(*) AS STRING), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM campaign_audience
WHERE recency_days NOT BETWEEN 91 AND 365

UNION ALL
-- QA07 campaign codes: offer on test, none on control
SELECT 'QA07', 'Cell code populated; offer code on all test records', '0',
       CAST(COUNT(*) AS STRING), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM campaign_audience
WHERE cell_code IS NULL
   OR (test_control = 'T' AND offer_code IS NULL)
   OR (test_control = 'C' AND offer_code IS NOT NULL)

UNION ALL
-- QA08 holdout within 10% +/- 1.5 points in every segment
SELECT 'QA08', 'Control group within tolerance in every segment', '10% +/-1.5',
       concat(MIN(pct), '%-', MAX(pct), '%'),
       IF(MIN(pct) >= 8.5 AND MAX(pct) <= 11.5, 'PASS', 'FAIL')
FROM (SELECT segment, round(100.0 * count_if(test_control = 'C') / COUNT(*), 1) AS pct
      FROM campaign_audience GROUP BY segment)

UNION ALL
-- QA09 waterfall reconciles to the final audience
SELECT 'QA09', 'Waterfall reconciles to final audience count',
       CAST((SELECT COUNT(*) FROM campaign_audience) AS STRING),
       CAST(MAX_BY(remaining, step) AS STRING),
       IF(MAX_BY(remaining, step) = (SELECT COUNT(*) FROM campaign_audience), 'PASS', 'FAIL')
FROM campaign_waterfall

UNION ALL
-- QA10 size inside the range agreed with Marketing
SELECT 'QA10', 'Audience size within expected range', '6,000-12,000',
       CAST(COUNT(*) AS STRING), IF(COUNT(*) BETWEEN 6000 AND 12000, 'PASS', 'FAIL')
FROM campaign_audience;

SELECT * FROM qa_results ORDER BY check_id;

-- COMMAND ----------

-- QA gate: stop the notebook (and any Job running it) if anything failed
SELECT CASE
         WHEN count_if(status = 'FAIL') > 0
           THEN raise_error(concat(count_if(status = 'FAIL'),
                                   ' QA check(s) failed - audience NOT released'))
         ELSE 'All QA checks passed - audience cleared for release'
       END AS qa_gate
FROM qa_results;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Count report for Marketing sign-off

-- COMMAND ----------

SELECT segment, segment_name, channel,
       count_if(test_control = 'T')        AS test,
       count_if(test_control = 'C')        AS control,
       COUNT(*)                             AS total,
       round(avg(net_sales_24m), 2)         AS avg_net_sales_24m,
       coalesce(max(offer_code), '')        AS offer_code
FROM campaign_audience
GROUP BY segment, segment_name, channel
ORDER BY segment, CASE channel WHEN 'EM' THEN 1 WHEN 'DM' THEN 2 ELSE 3 END;

-- COMMAND ----------

SELECT * FROM campaign_waterfall ORDER BY step;

-- COMMAND ----------

-- Prior campaign insight: FALL26 response rate by channel and loyalty tier
SELECT h.channel, c.loyalty_tier,
       COUNT(*)                                       AS contacted,
       SUM(h.responded)                               AS responders,
       round(100.0 * SUM(h.responded) / COUNT(*), 2)  AS response_rate_pct
FROM contact_history h
JOIN customers c USING (customer_id)
WHERE h.campaign_id = 'FALL26'
GROUP BY h.channel, c.loyalty_tier
ORDER BY h.channel,
         CASE c.loyalty_tier WHEN 'PLATINUM' THEN 1 WHEN 'GOLD' THEN 2 WHEN 'SILVER' THEN 3 ELSE 4 END;
