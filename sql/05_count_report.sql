-- =============================================================================
-- 05_count_report.sql
-- Count sign-off report for Marketing: audience by segment x channel x
-- test/control, plus prior-campaign (FALL26) response for context.
-- =============================================================================

-- Audience counts by cell
SELECT segment, segment_name, channel,
       SUM(test_control = 'T')                     AS test,
       SUM(test_control = 'C')                     AS control,
       COUNT(*)                                    AS total,
       ROUND(AVG(net_sales_24m), 2)                AS avg_net_sales_24m,
       COALESCE(MAX(offer_code), '')               AS offer_code
FROM campaign_audience
GROUP BY segment, segment_name, channel
ORDER BY segment, CASE channel WHEN 'EM' THEN 1 WHEN 'DM' THEN 2 ELSE 3 END;

-- Channel mix
SELECT channel, COUNT(*) AS records,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM campaign_audience), 1) AS pct_of_audience
FROM campaign_audience
GROUP BY channel
ORDER BY records DESC;

-- Prior campaign insight: FALL26 response rate by channel and loyalty tier
SELECT h.channel, c.loyalty_tier,
       COUNT(*)                                     AS contacted,
       SUM(h.responded)                             AS responders,
       ROUND(100.0 * SUM(h.responded) / COUNT(*), 2) AS response_rate_pct
FROM contact_history h
JOIN customers c ON c.customer_id = h.customer_id
WHERE h.campaign_id = 'FALL26'
GROUP BY h.channel, c.loyalty_tier
ORDER BY h.channel,
         CASE c.loyalty_tier WHEN 'PLATINUM' THEN 1 WHEN 'GOLD' THEN 2 WHEN 'SILVER' THEN 3 ELSE 4 END;
