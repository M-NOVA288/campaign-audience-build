-- =============================================================================
-- 06_export_file.sql
-- Vendor file layout. One combined file is exported; the Unix runner splits it
-- into per-channel files (ESP, mail house, SMS platform) and writes control
-- totals. Control-group records are kept in a separate holdout file and never
-- sent to a vendor.
-- =============================================================================

SELECT
    campaign_id, cell_code, customer_id, segment, channel, test_control,
    COALESCE(offer_code, '')  AS offer_code,
    first_name, last_name,
    CASE WHEN channel = 'EM'  THEN email   ELSE '' END AS email,
    CASE WHEN channel = 'SMS' THEN phone   ELSE '' END AS phone,
    CASE WHEN channel = 'DM'  THEN address ELSE '' END AS address,
    CASE WHEN channel = 'DM'  THEN city    ELSE '' END AS city,
    CASE WHEN channel = 'DM'  THEN state   ELSE '' END AS state,
    CASE WHEN channel = 'DM'  THEN zip     ELSE '' END AS zip,
    loyalty_tier
FROM campaign_audience
ORDER BY channel, segment, customer_id;
