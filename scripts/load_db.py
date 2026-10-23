#!/usr/bin/env python3
"""
Load the raw CSV extracts into a local SQLite database, using the DDL in
sql/01_create_tables.sql. Mirrors the "land the files" step of a campaign job.

Usage:
    python3 scripts/load_db.py <db> <data_dir> <ddl.sql>
"""
import csv
import os
import sqlite3
import sys

TABLES = {
    "customers": "customers.csv",
    "contact_preferences": "contact_preferences.csv",
    "transactions": "transactions.csv",
    "contact_history": "contact_history.csv",
    "suppress_email_bounces": "suppress_email_bounces.csv",
    "suppress_legal_hold": "suppress_legal_hold.csv",
    "suppress_employees": "suppress_employees.csv",
}


def main():
    db, data_dir, ddl = sys.argv[1:4]
    if os.path.exists(db):
        os.remove(db)
    con = sqlite3.connect(db)
    with open(ddl) as f:
        con.executescript(f.read())
    for table, fname in TABLES.items():
        with open(os.path.join(data_dir, fname), newline="") as f:
            r = csv.reader(f)
            header = next(r)
            rows = [[None if v == "" else v for v in row] for row in r]
        ph = ",".join("?" * len(header))
        con.executemany(f"INSERT INTO {table} ({','.join(header)}) VALUES ({ph})", rows)
        print(f"NOTE: loaded {len(rows):>7,} rows into {table}")
    con.commit()


if __name__ == "__main__":
    main()
