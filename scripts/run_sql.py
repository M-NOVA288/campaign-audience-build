#!/usr/bin/env python3
"""
Minimal SQL runner for the local (SQLite) version of the pipeline.

Runs every statement in a .sql file in order, prints the result of any SELECT
as a fixed-width table, and optionally exports the LAST result set to CSV.
In production this step would be `sas -sysin ...` or a database client
(sqlplus / bteq / psql / databricks sql); SQLite keeps the repo runnable anywhere.

Usage:
    python3 scripts/run_sql.py <db> <file.sql> [--export out.csv] [--quiet]
"""
import argparse
import csv
import sqlite3
import sys
import time


def statements(text):
    buf = ""
    for line in text.splitlines(keepends=True):
        buf += line
        if sqlite3.complete_statement(buf):
            stmt = buf.strip()
            buf = ""
            # skip comment-only chunks
            if any(l.strip() and not l.strip().startswith("--") for l in stmt.splitlines()):
                yield stmt
    if buf.strip():
        yield buf.strip()


def print_table(cols, rows, limit=60):
    rows = [["" if v is None else str(v) for v in r] for r in rows]
    widths = [max(len(c), *(len(r[i]) for r in rows)) if rows else len(c) for i, c in enumerate(cols)]
    line = "  ".join(c.ljust(w) for c, w in zip(cols, widths))
    print(line)
    print("  ".join("-" * w for w in widths))
    for r in rows[:limit]:
        print("  ".join(v.ljust(w) for v, w in zip(r, widths)))
    if len(rows) > limit:
        print(f"... ({len(rows) - limit} more rows)")
    print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("sql_file")
    ap.add_argument("--export")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    con = sqlite3.connect(a.db)
    last = None
    t0 = time.time()
    with open(a.sql_file) as f:
        for stmt in statements(f.read()):
            try:
                cur = con.execute(stmt)
            except sqlite3.Error as e:
                first = next(l for l in stmt.splitlines() if l.strip() and not l.strip().startswith("--"))
                print(f"ERROR: {e}\n  in statement starting: {first[:100]}", file=sys.stderr)
                sys.exit(1)
            if cur.description:
                cols = [d[0] for d in cur.description]
                rows = cur.fetchall()
                last = (cols, rows)
                if not a.quiet:
                    print_table(cols, rows)
    con.commit()

    if a.export and last:
        with open(a.export, "w", newline="") as f:
            w = csv.writer(f, lineterminator="\n")
            w.writerow(last[0])
            w.writerows(last[1])
        print(f"NOTE: exported {len(last[1])} rows to {a.export}")
    print(f"NOTE: {a.sql_file} completed in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
