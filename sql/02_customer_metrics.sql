-- =============================================================================
-- 02_customer_metrics.sql
-- One row per customer with recency / frequency / monetary (RFM) metrics as of
-- the campaign selection date in run_params.
--   * Returns (negative amounts) reduce net sales but don't count as a purchase.
--   * Only transactions before the as-of date are used (no look-ahead).
-- =============================================================================

DROP TABLE IF EXISTS cust_metrics;

CREATE TABLE cust_metrics AS
SELECT
    t.customer_id,
    MAX(CASE WHEN t.amount > 0 THEN t.txn_date END)                         AS last_purchase_date,
    CAST(julianday(p.as_of_date)
         - julianday(MAX(CASE WHEN t.amount > 0 THEN t.txn_date END)) AS INTEGER) AS recency_days,
    SUM(CASE WHEN t.amount > 0
              AND t.txn_date >= date(p.as_of_date, '-24 months') THEN 1 ELSE 0 END) AS frequency_24m,
    ROUND(SUM(CASE WHEN t.txn_date >= date(p.as_of_date, '-24 months')
                   THEN t.amount ELSE 0 END), 2)                              AS net_sales_24m,
    COUNT(DISTINCT t.channel)                                                 AS channels_used
FROM transactions t
CROSS JOIN run_params p
WHERE t.txn_date < p.as_of_date
GROUP BY t.customer_id;

CREATE UNIQUE INDEX ix_cm_cust ON cust_metrics(customer_id);

-- quick profile for the log
SELECT
    COUNT(*)                                        AS customers_with_txns,
    SUM(CASE WHEN recency_days <= 90  THEN 1 ELSE 0 END)                        AS active_0_90,
    SUM(CASE WHEN recency_days BETWEEN 91  AND 180 THEN 1 ELSE 0 END)           AS at_risk_91_180,
    SUM(CASE WHEN recency_days BETWEEN 181 AND 365 THEN 1 ELSE 0 END)           AS lapsed_181_365,
    SUM(CASE WHEN recency_days > 365 THEN 1 ELSE 0 END)                         AS dormant_365_plus,
    ROUND(AVG(net_sales_24m), 2)                    AS avg_net_sales_24m
FROM cust_metrics;
