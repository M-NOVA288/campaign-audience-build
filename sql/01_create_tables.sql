-- =============================================================================
-- 01_create_tables.sql
-- Source tables for the HOL26 campaign build (synthetic data).
-- Written in portable SQL; types map cleanly to Oracle / Teradata / Databricks.
-- =============================================================================

CREATE TABLE customers (
    customer_id     INTEGER PRIMARY KEY,
    first_name      VARCHAR(40),
    last_name       VARCHAR(40),
    email           VARCHAR(120),
    phone           VARCHAR(15),
    address         VARCHAR(120),
    city            VARCHAR(60),
    state           CHAR(2),
    zip             VARCHAR(10),
    birth_date      DATE,
    enroll_date     DATE,
    loyalty_tier    VARCHAR(10),
    account_status  VARCHAR(10)      -- ACTIVE / CLOSED / DECEASED
);

CREATE TABLE contact_preferences (
    customer_id     INTEGER PRIMARY KEY REFERENCES customers(customer_id),
    email_opt_in    SMALLINT,
    sms_opt_in      SMALLINT,
    dm_opt_in       SMALLINT,
    do_not_contact  SMALLINT,
    updated_date    DATE
);

CREATE TABLE transactions (
    txn_id          INTEGER PRIMARY KEY,
    customer_id     INTEGER REFERENCES customers(customer_id),
    txn_date        DATE,
    channel         VARCHAR(10),     -- STORE / WEB / APP
    amount          DECIMAL(10,2),   -- negative = return
    category        VARCHAR(20)
);
CREATE INDEX ix_txn_cust ON transactions(customer_id, txn_date);

CREATE TABLE contact_history (
    customer_id     INTEGER,
    campaign_id     VARCHAR(20),
    channel         VARCHAR(10),
    contact_date    DATE,
    responded       SMALLINT,
    response_date   DATE
);
CREATE INDEX ix_ch_cust ON contact_history(customer_id, contact_date);

-- Global suppression files (compliance / ESP / HR feeds)
CREATE TABLE suppress_email_bounces (email VARCHAR(120));
CREATE TABLE suppress_legal_hold    (customer_id INTEGER, reason VARCHAR(20));
CREATE TABLE suppress_employees     (customer_id INTEGER);
