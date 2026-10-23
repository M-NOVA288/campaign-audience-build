-- =============================================================================
-- 04_qa_checks.sql
-- Automated QA on the final audience before anything is released to a vendor.
-- Each check writes expected vs actual and PASS/FAIL to qa_results.
-- The Unix runner stops the job if any check FAILs.
-- =============================================================================

DROP TABLE IF EXISTS qa_results;
CREATE TABLE qa_results (
    check_id    VARCHAR(6),
    check_name  VARCHAR(80),
    expected    VARCHAR(30),
    actual      VARCHAR(30),
    status      VARCHAR(4)
);

-- QA01 one row per customer
INSERT INTO qa_results
SELECT 'QA01', 'No duplicate customer_id in audience', '0', CAST(COUNT(*) - COUNT(DISTINCT customer_id) AS TEXT),
       CASE WHEN COUNT(*) = COUNT(DISTINCT customer_id) THEN 'PASS' ELSE 'FAIL' END
FROM campaign_audience;

-- QA02 no duplicate emails going to the ESP
INSERT INTO qa_results
SELECT 'QA02', 'No duplicate email addresses in email channel', '0',
       CAST(COUNT(*) - COUNT(DISTINCT email) AS TEXT),
       CASE WHEN COUNT(*) = COUNT(DISTINCT email) THEN 'PASS' ELSE 'FAIL' END
FROM campaign_audience WHERE channel = 'EM';

-- QA03 suppression leakage: nobody on any suppression source made it through
INSERT INTO qa_results
SELECT 'QA03', 'No suppressed records in audience (legal/employee/DNC/bounce)', '0',
       CAST(COUNT(*) AS TEXT), CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM campaign_audience a
WHERE a.customer_id IN (SELECT customer_id FROM suppress_legal_hold)
   OR a.customer_id IN (SELECT customer_id FROM suppress_employees)
   OR a.customer_id IN (SELECT customer_id FROM contact_preferences WHERE do_not_contact = 1)
   OR (a.channel = 'EM' AND a.email IN (SELECT LOWER(TRIM(email)) FROM suppress_email_bounces));

-- QA04 opt-in compliance by channel
INSERT INTO qa_results
SELECT 'QA04', 'Every record opted in to its assigned channel', '0',
       CAST(COUNT(*) AS TEXT), CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM campaign_audience a JOIN contact_preferences p ON p.customer_id = a.customer_id
WHERE (a.channel = 'EM'  AND p.email_opt_in = 0)
   OR (a.channel = 'DM'  AND p.dm_opt_in    = 0)
   OR (a.channel = 'SMS' AND p.sms_opt_in   = 0);

-- QA05 contact data is usable for the assigned channel
INSERT INTO qa_results
SELECT 'QA05', 'Valid email / address / phone for assigned channel', '0',
       CAST(COUNT(*) AS TEXT), CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM campaign_audience
WHERE (channel = 'EM'  AND (email IS NULL OR email NOT LIKE '%_@_%._%'))
   OR (channel = 'DM'  AND (address IS NULL OR zip NOT GLOB '[0-9][0-9][0-9][0-9][0-9]'))
   OR (channel = 'SMS' AND (LENGTH(phone) <> 10 OR phone GLOB '*[^0-9]*'));

-- QA06 selection criteria respected
INSERT INTO qa_results
SELECT 'QA06', 'All records inside recency window', '0',
       CAST(COUNT(*) AS TEXT), CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM campaign_audience a CROSS JOIN run_params p
WHERE a.recency_days NOT BETWEEN p.min_recency_days AND p.max_recency_days;

-- QA07 required campaign fields populated (control cells have no offer by design)
INSERT INTO qa_results
SELECT 'QA07', 'Cell code populated; offer code on all test records', '0',
       CAST(COUNT(*) AS TEXT), CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM campaign_audience
WHERE cell_code IS NULL
   OR (test_control = 'T' AND offer_code IS NULL)
   OR (test_control = 'C' AND offer_code IS NOT NULL);

-- QA08 holdout within tolerance (target +/- 1.5 pts) for every segment
INSERT INTO qa_results
SELECT 'QA08', 'Control group within tolerance in every segment',
       p.holdout_pct || '% +/-1.5',
       MIN(pct) || '%-' || MAX(pct) || '%',
       CASE WHEN MIN(pct) >= p.holdout_pct - 1.5 AND MAX(pct) <= p.holdout_pct + 1.5
            THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT segment, ROUND(100.0 * SUM(test_control = 'C') / COUNT(*), 1) AS pct
        FROM campaign_audience GROUP BY segment) s
CROSS JOIN run_params p;

-- QA09 waterfall reconciles: start - removals = final audience
INSERT INTO qa_results
SELECT 'QA09', 'Waterfall reconciles to final audience count',
       CAST((SELECT COUNT(*) FROM campaign_audience) AS TEXT),
       CAST((SELECT remaining FROM campaign_waterfall ORDER BY step DESC LIMIT 1) AS TEXT),
       CASE WHEN (SELECT COUNT(*) FROM campaign_audience)
               = (SELECT remaining FROM campaign_waterfall ORDER BY step DESC LIMIT 1)
            THEN 'PASS' ELSE 'FAIL' END;

-- QA10 sanity: audience size inside the range agreed with Marketing
INSERT INTO qa_results
SELECT 'QA10', 'Audience size within expected range', '6,000-12,000',
       CAST(COUNT(*) AS TEXT),
       CASE WHEN COUNT(*) BETWEEN 6000 AND 12000 THEN 'PASS' ELSE 'FAIL' END
FROM campaign_audience;

SELECT check_id, check_name, expected, actual, status FROM qa_results ORDER BY check_id;
