-- =============================================================================
-- 03_build_audience.sql
-- HOL26 Holiday Win-Back: audience selection, suppression waterfall,
-- de-duplication, channel assignment, segmentation, test/control split.
--
-- Every customer starts in aud_stage and is either kept or tagged with the
-- FIRST rule that removed them (drop_reason). That single column drives the
-- waterfall, so the counts always reconcile back to the starting universe.
-- All thresholds come from run_params (set by the Unix runner).
-- =============================================================================

DROP TABLE IF EXISTS aud_stage;

CREATE TABLE aud_stage AS
SELECT
    c.customer_id,
    c.first_name,
    c.last_name,
    LOWER(TRIM(c.email))                          AS email,
    c.phone,
    c.address,
    c.city,
    c.state,
    c.zip,
    c.loyalty_tier,
    c.account_status,
    m.last_purchase_date,
    m.recency_days,
    COALESCE(m.frequency_24m, 0)                  AS frequency_24m,
    COALESCE(m.net_sales_24m, 0)                  AS net_sales_24m,
    COALESCE(cp.email_opt_in, 0)                  AS email_opt_in,
    COALESCE(cp.sms_opt_in, 0)                    AS sms_opt_in,
    COALESCE(cp.dm_opt_in, 0)                     AS dm_opt_in,
    COALESCE(cp.do_not_contact, 0)                AS do_not_contact,
    CASE WHEN lh.customer_id IS NOT NULL THEN 1 ELSE 0 END AS legal_hold,
    CASE WHEN se.customer_id IS NOT NULL THEN 1 ELSE 0 END AS employee,
    CASE WHEN rc.customer_id IS NOT NULL THEN 1 ELSE 0 END AS recent_contact,
    CASE WHEN bo.email       IS NOT NULL THEN 1 ELSE 0 END AS email_bounced,
    -- contactability checks
    CASE WHEN c.email LIKE '%_@_%._%' AND c.email NOT LIKE '% %'
         THEN 1 ELSE 0 END                        AS valid_email,
    CASE WHEN c.address IS NOT NULL AND TRIM(c.address) <> ''
          AND c.zip GLOB '[0-9][0-9][0-9][0-9][0-9]'
         THEN 1 ELSE 0 END                        AS valid_address,
    CASE WHEN LENGTH(c.phone) = 10 AND c.phone NOT GLOB '*[^0-9]*'
         THEN 1 ELSE 0 END                        AS valid_phone,
    CAST(NULL AS VARCHAR(30))                     AS drop_reason
FROM customers c
LEFT JOIN cust_metrics        m  ON m.customer_id  = c.customer_id
LEFT JOIN contact_preferences cp ON cp.customer_id = c.customer_id
LEFT JOIN (SELECT DISTINCT customer_id FROM suppress_legal_hold) lh ON lh.customer_id = c.customer_id
LEFT JOIN (SELECT DISTINCT customer_id FROM suppress_employees)  se ON se.customer_id = c.customer_id
LEFT JOIN (SELECT DISTINCT h.customer_id
             FROM contact_history h CROSS JOIN run_params p
            WHERE h.contact_date >= date(p.as_of_date, '-' || p.fatigue_days || ' days')
              AND h.contact_date <  p.as_of_date)               rc ON rc.customer_id = c.customer_id
LEFT JOIN (SELECT DISTINCT LOWER(TRIM(email)) AS email
             FROM suppress_email_bounces)                       bo ON bo.email = LOWER(TRIM(c.email));

CREATE UNIQUE INDEX ix_as_cust ON aud_stage(customer_id);

-- -----------------------------------------------------------------------------
-- Steps 1-7: eligibility and suppressions (first failing rule wins)
-- -----------------------------------------------------------------------------
UPDATE aud_stage
SET drop_reason = (
    SELECT CASE
        WHEN aud_stage.account_status <> 'ACTIVE'                       THEN '01_ACCOUNT_NOT_ACTIVE'
        WHEN aud_stage.recency_days IS NULL                             THEN '02_NO_PURCHASE_HISTORY'
        WHEN aud_stage.recency_days NOT BETWEEN p.min_recency_days
                                            AND p.max_recency_days      THEN '03_OUTSIDE_RECENCY_WINDOW'
        WHEN aud_stage.legal_hold     = 1                               THEN '04_LEGAL_HOLD'
        WHEN aud_stage.employee       = 1                               THEN '05_EMPLOYEE'
        WHEN aud_stage.do_not_contact = 1                               THEN '06_DO_NOT_CONTACT'
        WHEN aud_stage.recent_contact = 1                               THEN '07_CONTACT_FATIGUE'
    END
    FROM run_params p
);

-- -----------------------------------------------------------------------------
-- Step 8: de-duplicate survivors. Same valid email = same person; otherwise
-- match on name + address + ZIP. Keep the most valuable, most recent record.
-- -----------------------------------------------------------------------------
ALTER TABLE aud_stage ADD COLUMN dedupe_key VARCHAR(200);

UPDATE aud_stage
SET dedupe_key = CASE
    WHEN valid_email = 1 THEN 'E|' || email
    WHEN valid_address = 1 THEN 'A|' || UPPER(first_name || '|' || last_name || '|'
                                              || TRIM(address) || '|' || zip)
    ELSE 'ID|' || customer_id            -- nothing to match on: treat as unique
END;

WITH ranked AS (
    SELECT customer_id,
           ROW_NUMBER() OVER (PARTITION BY dedupe_key
                              ORDER BY net_sales_24m DESC, recency_days ASC, customer_id ASC) AS rn
    FROM aud_stage
    WHERE drop_reason IS NULL
)
UPDATE aud_stage
SET drop_reason = '08_DUPLICATE'
WHERE customer_id IN (SELECT customer_id FROM ranked WHERE rn > 1);

-- -----------------------------------------------------------------------------
-- Step 9: channel assignment by priority  EMAIL > DIRECT MAIL > SMS
-- -----------------------------------------------------------------------------
ALTER TABLE aud_stage ADD COLUMN channel VARCHAR(5);

UPDATE aud_stage
SET channel = CASE
    WHEN valid_email = 1 AND email_opt_in = 1 AND email_bounced = 0 THEN 'EM'
    WHEN valid_address = 1 AND dm_opt_in = 1                        THEN 'DM'
    WHEN valid_phone = 1 AND sms_opt_in = 1                         THEN 'SMS'
END
WHERE drop_reason IS NULL;

UPDATE aud_stage
SET drop_reason = '09_NO_CONTACTABLE_CHANNEL'
WHERE drop_reason IS NULL AND channel IS NULL;

-- -----------------------------------------------------------------------------
-- Final audience: segment, test/control, cell and offer codes
--   S1 Lapsed high value   181-365 days, net sales >= threshold or GOLD/PLATINUM
--   S2 Lapsed standard     181-365 days
--   S3 At-risk high value   91-180 days, net sales >= threshold or GOLD/PLATINUM
--   S4 At-risk standard     91-180 days
-- Holdout is a deterministic hash of customer_id, so a rerun gives the same split.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS campaign_audience;

CREATE TABLE campaign_audience AS
WITH seg AS (
    SELECT a.*,
           CASE
             WHEN a.recency_days >= 181 AND (a.net_sales_24m >= p.high_value_threshold
                                             OR a.loyalty_tier IN ('GOLD','PLATINUM')) THEN 'S1'
             WHEN a.recency_days >= 181                                               THEN 'S2'
             WHEN a.net_sales_24m >= p.high_value_threshold
                  OR a.loyalty_tier IN ('GOLD','PLATINUM')                            THEN 'S3'
             ELSE 'S4'
           END AS segment,
           CASE WHEN (a.customer_id * 7919) % 100 < p.holdout_pct THEN 'C' ELSE 'T' END AS test_control,
           p.campaign_id
    FROM aud_stage a CROSS JOIN run_params p
    WHERE a.drop_reason IS NULL
)
SELECT
    campaign_id,
    customer_id,
    segment,
    CASE segment WHEN 'S1' THEN 'Lapsed High Value'  WHEN 'S2' THEN 'Lapsed Standard'
                 WHEN 'S3' THEN 'At-Risk High Value' ELSE 'At-Risk Standard' END AS segment_name,
    channel,
    test_control,
    campaign_id || '-' || segment || '-' || channel || '-' || test_control      AS cell_code,
    CASE WHEN test_control = 'C' THEN NULL
         ELSE CASE segment WHEN 'S1' THEN 'HOL26-25OFF100'
                           WHEN 'S2' THEN 'HOL26-20PCT'
                           WHEN 'S3' THEN 'HOL26-15OFF75'
                           ELSE           'HOL26-10PCT' END END                 AS offer_code,
    first_name, last_name, email, phone, address, city, state, zip,
    loyalty_tier, last_purchase_date, recency_days, frequency_24m, net_sales_24m
FROM seg;

CREATE UNIQUE INDEX ix_aud_cust ON campaign_audience(customer_id);

-- -----------------------------------------------------------------------------
-- Suppression waterfall
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS campaign_waterfall;

CREATE TABLE campaign_waterfall AS
WITH steps(step, description) AS (
    VALUES ('01_ACCOUNT_NOT_ACTIVE',      'Closed or deceased account'),
           ('02_NO_PURCHASE_HISTORY',     'No purchase on file'),
           ('03_OUTSIDE_RECENCY_WINDOW',  'Last purchase outside 91-365 day window'),
           ('04_LEGAL_HOLD',              'Legal / fraud / bankruptcy hold'),
           ('05_EMPLOYEE',                'Employee file'),
           ('06_DO_NOT_CONTACT',          'Global do-not-contact flag'),
           ('07_CONTACT_FATIGUE',         'Contacted in last 14 days'),
           ('08_DUPLICATE',               'Duplicate person (email or name+address)'),
           ('09_NO_CONTACTABLE_CHANNEL',  'No opted-in, valid channel')
),
drops AS (
    SELECT s.step, s.description, COUNT(a.customer_id) AS removed
    FROM steps s LEFT JOIN aud_stage a ON a.drop_reason = s.step
    GROUP BY s.step, s.description
),
total AS (SELECT COUNT(*) AS n FROM aud_stage)
SELECT '00_STARTING_UNIVERSE' AS step, 'All customer records' AS description,
       0 AS removed, n AS remaining
FROM total
UNION ALL
SELECT d.step, d.description, d.removed,
       t.n - SUM(d.removed) OVER (ORDER BY d.step ROWS UNBOUNDED PRECEDING) AS remaining
FROM drops d CROSS JOIN total t
ORDER BY step;

SELECT step, description, removed, remaining FROM campaign_waterfall ORDER BY step;
