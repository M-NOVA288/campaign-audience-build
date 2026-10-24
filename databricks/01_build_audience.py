# Databricks notebook source
# MAGIC %md
# MAGIC # 01 · Build the campaign audience (PySpark)
# MAGIC
# MAGIC The same rules as `sql/03_build_audience.sql` and `sas/03_build_audience.sas`, written with the
# MAGIC PySpark DataFrame API on Delta tables:
# MAGIC
# MAGIC 1. Customer metrics (recency, 24-month frequency and net sales)
# MAGIC 2. Eligibility and suppressions, tagged with the **first** rule that removed each customer
# MAGIC 3. De-duplication with a window function
# MAGIC 4. Channel assignment: email → direct mail → SMS
# MAGIC 5. Segments, deterministic 10% holdout, cell and offer codes
# MAGIC 6. Suppression waterfall, reconciled against the SQL engine's results

# COMMAND ----------

dbutils.widgets.text("catalog", "workspace", "Catalog")
dbutils.widgets.text("schema", "campaign", "Schema")
dbutils.widgets.text("campaign_id", "HOL26", "Campaign ID")
dbutils.widgets.text("as_of_date", "2026-11-01", "As-of date (YYYY-MM-DD)")

CATALOG = dbutils.widgets.get("catalog")
SCHEMA = dbutils.widgets.get("schema")
CAMPAIGN_ID = dbutils.widgets.get("campaign_id")
AS_OF_DATE = dbutils.widgets.get("as_of_date")

# selection rules: same values as unix/run_campaign.sh and sas/00_config.sas
MIN_RECENCY = 91
MAX_RECENCY = 365
FATIGUE_DAYS = 14
HV_THRESHOLD = 500
HOLDOUT_PCT = 10

spark.sql(f"USE {CATALOG}.{SCHEMA}")

# COMMAND ----------

from pyspark.sql import functions as F
from pyspark.sql.window import Window

as_of = F.to_date(F.lit(AS_OF_DATE))

# ---------------------------------------------------------------------------
# 1. Customer metrics. Returns reduce net sales but are not a "purchase";
#    only transactions before the as-of date are used (no look-ahead).
# ---------------------------------------------------------------------------
txn = spark.table("transactions").where(F.col("txn_date") < as_of)
start_24m = F.add_months(as_of, -24)

cust_metrics = (
    txn.groupBy("customer_id")
    .agg(
        F.max(F.when(F.col("amount") > 0, F.col("txn_date"))).alias("last_purchase_date"),
        F.sum(F.when((F.col("amount") > 0) & (F.col("txn_date") >= start_24m), 1)
              .otherwise(0)).alias("frequency_24m"),
        F.round(F.sum(F.when(F.col("txn_date") >= start_24m, F.col("amount"))
                      .otherwise(0)), 2).cast("double").alias("net_sales_24m"),
    )
    .withColumn("recency_days", F.datediff(as_of, F.col("last_purchase_date")))
)
cust_metrics.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("cust_metrics")

# COMMAND ----------

# ---------------------------------------------------------------------------
# 2. One row per customer with every flag the rules need
# ---------------------------------------------------------------------------
legal = spark.table("suppress_legal_hold").select("customer_id").distinct() \
    .withColumn("legal_hold", F.lit(1))
employees = spark.table("suppress_employees").select("customer_id").distinct() \
    .withColumn("employee", F.lit(1))
recent = (spark.table("contact_history")
          .where((F.col("contact_date") >= F.date_sub(as_of, FATIGUE_DAYS))
                 & (F.col("contact_date") < as_of))
          .select("customer_id").distinct()
          .withColumn("recent_contact", F.lit(1)))
bounces = (spark.table("suppress_email_bounces")
           .select(F.lower(F.trim("email")).alias("bounce_email")).distinct()
           .withColumn("email_bounced", F.lit(1)))
prefs = spark.table("contact_preferences").select(
    "customer_id", "email_opt_in", "sms_opt_in", "dm_opt_in", "do_not_contact")

c = spark.table("customers")
stage = (
    c.withColumn("email_clean", F.lower(F.trim("email")))
    .join(spark.table("cust_metrics"), "customer_id", "left")
    .join(prefs, "customer_id", "left")
    .join(legal, "customer_id", "left")
    .join(employees, "customer_id", "left")
    .join(recent, "customer_id", "left")
    .join(bounces, F.col("email_clean") == F.col("bounce_email"), "left")
    .drop("bounce_email")
    .fillna(0, subset=["email_opt_in", "sms_opt_in", "dm_opt_in", "do_not_contact",
                       "legal_hold", "employee", "recent_contact", "email_bounced",
                       "frequency_24m", "net_sales_24m"])
    # contactability checks (NULL fails every check)
    .withColumn("valid_email", F.when(
        F.col("email").like("%_@_%._%") & ~F.col("email").like("% %"), 1).otherwise(0))
    .withColumn("valid_address", F.when(
        F.col("address").isNotNull() & (F.trim("address") != "")
        & F.col("zip").rlike("^[0-9]{5}$"), 1).otherwise(0))
    .withColumn("valid_phone", F.when(F.col("phone").rlike("^[0-9]{10}$"), 1).otherwise(0))
    .drop("email").withColumnRenamed("email_clean", "email")
)

# Steps 1-7: first failing rule wins
stage = stage.withColumn(
    "drop_reason",
    F.when(F.col("account_status") != "ACTIVE", "01_ACCOUNT_NOT_ACTIVE")
    .when(F.col("recency_days").isNull(), "02_NO_PURCHASE_HISTORY")
    .when(~F.col("recency_days").between(MIN_RECENCY, MAX_RECENCY), "03_OUTSIDE_RECENCY_WINDOW")
    .when(F.col("legal_hold") == 1, "04_LEGAL_HOLD")
    .when(F.col("employee") == 1, "05_EMPLOYEE")
    .when(F.col("do_not_contact") == 1, "06_DO_NOT_CONTACT")
    .when(F.col("recent_contact") == 1, "07_CONTACT_FATIGUE"),
)

# COMMAND ----------

# ---------------------------------------------------------------------------
# 3. De-duplicate survivors: same valid email = same person, otherwise
#    name + address + ZIP. Keep the most valuable, then most recent record.
# ---------------------------------------------------------------------------
stage = stage.withColumn(
    "dedupe_key",
    F.when(F.col("valid_email") == 1, F.concat(F.lit("E|"), "email"))
    .when(F.col("valid_address") == 1,
          F.upper(F.concat_ws("|", F.lit("A"), "first_name", "last_name",
                              F.trim("address"), "zip")))
    .otherwise(F.concat(F.lit("ID|"), F.col("customer_id").cast("string"))),
)

w = Window.partitionBy("dedupe_key").orderBy(
    F.col("net_sales_24m").desc(), F.col("recency_days").asc(), F.col("customer_id").asc())

survivor_rank = (stage.where(F.col("drop_reason").isNull())
                 .withColumn("rn", F.row_number().over(w))
                 .select("customer_id", "rn"))

stage = (stage.join(survivor_rank, "customer_id", "left")
         .withColumn("drop_reason", F.when(F.col("rn") > 1, "08_DUPLICATE")
                     .otherwise(F.col("drop_reason")))
         .drop("rn"))

# ---------------------------------------------------------------------------
# 4. Channel assignment by priority EMAIL > DIRECT MAIL > SMS
# ---------------------------------------------------------------------------
stage = (
    stage.withColumn(
        "channel",
        F.when(F.col("drop_reason").isNotNull(), F.lit(None))
        .when((F.col("valid_email") == 1) & (F.col("email_opt_in") == 1)
              & (F.col("email_bounced") == 0), "EM")
        .when((F.col("valid_address") == 1) & (F.col("dm_opt_in") == 1), "DM")
        .when((F.col("valid_phone") == 1) & (F.col("sms_opt_in") == 1), "SMS"))
    .withColumn(
        "drop_reason",
        F.when(F.col("drop_reason").isNull() & F.col("channel").isNull(),
               "09_NO_CONTACTABLE_CHANNEL").otherwise(F.col("drop_reason")))
)

stage.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("aud_stage")

# COMMAND ----------

# ---------------------------------------------------------------------------
# 5. Final audience: segment, deterministic holdout, cell and offer codes
#    S1 Lapsed high value   181-365 days, net sales >= threshold or GOLD/PLATINUM
#    S2 Lapsed standard     181-365 days
#    S3 At-risk high value   91-180 days, net sales >= threshold or GOLD/PLATINUM
#    S4 At-risk standard     91-180 days
# ---------------------------------------------------------------------------
high_value = (F.col("net_sales_24m") >= HV_THRESHOLD) | F.col("loyalty_tier").isin("GOLD", "PLATINUM")

segment = (F.when((F.col("recency_days") >= 181) & high_value, "S1")
           .when(F.col("recency_days") >= 181, "S2")
           .when(high_value, "S3")
           .otherwise("S4"))

audience = (
    spark.table("aud_stage").where(F.col("drop_reason").isNull())
    .withColumn("campaign_id", F.lit(CAMPAIGN_ID))
    .withColumn("segment", segment)
    .withColumn("segment_name",
                F.when(F.col("segment") == "S1", "Lapsed High Value")
                .when(F.col("segment") == "S2", "Lapsed Standard")
                .when(F.col("segment") == "S3", "At-Risk High Value")
                .otherwise("At-Risk Standard"))
    .withColumn("test_control",
                F.when((F.col("customer_id") * 7919) % 100 < HOLDOUT_PCT, "C").otherwise("T"))
    .withColumn("cell_code", F.concat_ws("-", "campaign_id", "segment", "channel", "test_control"))
    .withColumn("offer_code",
                F.when(F.col("test_control") == "C", F.lit(None))
                .when(F.col("segment") == "S1", F.lit(f"{CAMPAIGN_ID}-25OFF100"))
                .when(F.col("segment") == "S2", F.lit(f"{CAMPAIGN_ID}-20PCT"))
                .when(F.col("segment") == "S3", F.lit(f"{CAMPAIGN_ID}-15OFF75"))
                .otherwise(F.lit(f"{CAMPAIGN_ID}-10PCT")))
    .select("campaign_id", "customer_id", "segment", "segment_name", "channel", "test_control",
            "cell_code", "offer_code", "first_name", "last_name", "email", "phone", "address",
            "city", "state", "zip", "loyalty_tier", "last_purchase_date", "recency_days",
            "frequency_24m", "net_sales_24m")
)
audience.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("campaign_audience")

# COMMAND ----------

# ---------------------------------------------------------------------------
# 6. Suppression waterfall
# ---------------------------------------------------------------------------
steps = [
    ("01_ACCOUNT_NOT_ACTIVE", "Closed or deceased account"),
    ("02_NO_PURCHASE_HISTORY", "No purchase on file"),
    ("03_OUTSIDE_RECENCY_WINDOW", "Last purchase outside 91-365 day window"),
    ("04_LEGAL_HOLD", "Legal / fraud / bankruptcy hold"),
    ("05_EMPLOYEE", "Employee file"),
    ("06_DO_NOT_CONTACT", "Global do-not-contact flag"),
    ("07_CONTACT_FATIGUE", "Contacted in last 14 days"),
    ("08_DUPLICATE", "Duplicate person (email or name+address)"),
    ("09_NO_CONTACTABLE_CHANNEL", "No opted-in, valid channel"),
]

stage_df = spark.table("aud_stage")
total = stage_df.count()
removed_by_step = {r["drop_reason"]: r["n"] for r in
                   stage_df.groupBy("drop_reason").agg(F.count("*").alias("n")).collect()}

rows, remaining = [("00_STARTING_UNIVERSE", "All customer records", 0, total)], total
for step, description in steps:
    removed = removed_by_step.get(step, 0)
    remaining -= removed
    rows.append((step, description, removed, remaining))

waterfall = spark.createDataFrame(rows, "step string, description string, removed long, remaining long")
waterfall.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("campaign_waterfall")
display(waterfall)

# COMMAND ----------

# MAGIC %md
# MAGIC ### Cross-engine reconciliation
# MAGIC
# MAGIC The repo commits the waterfall the SQL engine produced for HOL26 as of 2026-11-01
# MAGIC (`output/HOL26_waterfall_20261101.csv`). With the same data and parameters, every step here
# MAGIC must match it exactly. Any difference stops the notebook.

# COMMAND ----------

import os
import pandas as pd

expected_path = os.path.abspath(os.path.join(
    os.getcwd(), "..", "output", f"{CAMPAIGN_ID}_waterfall_{AS_OF_DATE.replace('-', '')}.csv"))

if os.path.exists(expected_path):
    expected = pd.read_csv(expected_path)[["step", "removed", "remaining"]]
    actual = waterfall.select("step", "removed", "remaining").toPandas()
    diff = expected.merge(actual, on="step", how="outer", suffixes=("_sql", "_spark"), indicator=True)
    mismatched = diff[(diff["_merge"] != "both")
                      | (diff["removed_sql"] != diff["removed_spark"])
                      | (diff["remaining_sql"] != diff["remaining_spark"])]
    display(diff.drop(columns="_merge"))
    assert mismatched.empty, f"Spark waterfall does not match the SQL engine:\n{mismatched}"
    print(f"Reconciled: all {len(expected)} waterfall steps match the SQL engine "
          f"(final audience {int(actual['remaining'].iloc[-1]):,}).")
else:
    print(f"No SQL-engine waterfall at {expected_path}; skipping reconciliation "
          "(expected when running with a Volume or different parameters).")
