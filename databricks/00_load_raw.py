# Databricks notebook source
# MAGIC %md
# MAGIC # 00 · Load raw extracts to Delta
# MAGIC
# MAGIC Lands the seven raw CSV extracts as Delta tables in `<catalog>.<schema>`, with explicit types
# MAGIC (IDs as integers, ZIPs and phones as strings, real dates).
# MAGIC
# MAGIC **Where the files come from**
# MAGIC - **Git folder (default):** if this repo was cloned with *Workspace → Create → Git folder*, the CSVs in `data/` are read straight from the workspace.
# MAGIC - **Volume:** to use a Unity Catalog volume instead, upload the CSVs and set `raw_path` to e.g. `/Volumes/workspace/campaign/raw`.

# COMMAND ----------

dbutils.widgets.text("catalog", "workspace", "Catalog")
dbutils.widgets.text("schema", "campaign", "Schema")
dbutils.widgets.text("raw_path", "", "Raw CSV path (blank = repo data/ folder)")

CATALOG = dbutils.widgets.get("catalog")
SCHEMA = dbutils.widgets.get("schema")
RAW_PATH = dbutils.widgets.get("raw_path").strip()

spark.sql(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.{SCHEMA}")
spark.sql(f"USE {CATALOG}.{SCHEMA}")

# COMMAND ----------

import os
import pandas as pd
from pyspark.sql import functions as F

if not RAW_PATH:
    RAW_PATH = os.path.abspath(os.path.join(os.getcwd(), "..", "data"))
print(f"Reading raw extracts from: {RAW_PATH}")

# table -> (file, {column: spark type}); columns not listed stay string
TABLES = {
    "customers": ("customers.csv", {
        "customer_id": "bigint", "birth_date": "date", "enroll_date": "date"}),
    "contact_preferences": ("contact_preferences.csv", {
        "customer_id": "bigint", "email_opt_in": "int", "sms_opt_in": "int",
        "dm_opt_in": "int", "do_not_contact": "int", "updated_date": "date"}),
    "transactions": ("transactions.csv", {
        "txn_id": "bigint", "customer_id": "bigint", "txn_date": "date",
        "amount": "decimal(10,2)"}),
    "contact_history": ("contact_history.csv", {
        "customer_id": "bigint", "contact_date": "date", "responded": "int",
        "response_date": "date"}),
    "suppress_email_bounces": ("suppress_email_bounces.csv", {}),
    "suppress_legal_hold": ("suppress_legal_hold.csv", {"customer_id": "bigint"}),
    "suppress_employees": ("suppress_employees.csv", {"customer_id": "bigint"}),
}


def read_raw(file_name):
    """Read one extract as all-string columns, empty fields as NULL."""
    path = f"{RAW_PATH}/{file_name}"
    if RAW_PATH.startswith("/Volumes") or RAW_PATH.startswith("dbfs:"):
        return spark.read.csv(path, header=True, inferSchema=False)
    # workspace / Git folder files: read with pandas, keep every value as text
    pdf = pd.read_csv(path, dtype=str, keep_default_na=False)
    pdf = pdf.astype(object).where(pdf != "", None)
    return spark.createDataFrame(pdf, schema=", ".join(f"`{c}` string" for c in pdf.columns))


row_counts = []
for table, (file_name, types) in TABLES.items():
    df = read_raw(file_name)
    for col, spark_type in types.items():
        df = df.withColumn(col, F.col(col).cast(spark_type))
    df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(table)
    row_counts.append((table, spark.table(table).count()))

display(spark.createDataFrame(row_counts, "table_name string, row_count long"))
