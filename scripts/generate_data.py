#!/usr/bin/env python3
"""
Generate a synthetic retail marketing database for the HOL26 campaign build.

All data is fake. Names, emails, phones and addresses are randomly generated
and do not belong to real people. The generator deliberately injects common
data quality problems (duplicates, missing/invalid emails, bad ZIPs, closed and
deceased accounts) so the QA steps downstream have real issues to catch.

Usage:
    python3 scripts/generate_data.py [--customers 25000] [--seed 2026] [--out data]
"""
import argparse
import csv
import os
import random
from datetime import date, timedelta

AS_OF = date(2026, 11, 1)  # campaign selection date

FIRST = ["James", "Maria", "Robert", "Linda", "Michael", "Patricia", "David", "Jennifer",
         "Carlos", "Elizabeth", "Daniel", "Susan", "Jose", "Jessica", "Kevin", "Sarah",
         "Brian", "Karen", "Luis", "Nancy", "Anthony", "Lisa", "Mark", "Betty", "Andrew",
         "Ashley", "Joshua", "Emily", "Ryan", "Michelle", "Nguyen", "Priya", "Ahmed", "Grace"]
LAST = ["Smith", "Johnson", "Garcia", "Martinez", "Brown", "Davis", "Rodriguez", "Wilson",
        "Lopez", "Anderson", "Thomas", "Hernandez", "Moore", "Jackson", "Martin", "Lee",
        "Perez", "Thompson", "White", "Harris", "Clark", "Lewis", "Walker", "Hall", "Young",
        "Allen", "King", "Wright", "Scott", "Tran", "Patel", "Kim", "Nguyen", "Ali"]
CITIES = [  # (city, state, zip prefix)
    ("Houston", "TX", "770"), ("Katy", "TX", "774"), ("Sugar Land", "TX", "774"),
    ("Pasadena", "TX", "775"), ("The Woodlands", "TX", "773"), ("Pearland", "TX", "775"),
    ("Dallas", "TX", "752"), ("Austin", "TX", "787"), ("San Antonio", "TX", "782"),
    ("Baton Rouge", "LA", "708"), ("New Orleans", "LA", "701"), ("Tulsa", "OK", "741"),
]
STREETS = ["Main St", "Westheimer Rd", "Richmond Ave", "Kirby Dr", "Memorial Dr", "Oak Ln",
           "Bellaire Blvd", "Shepherd Dr", "Gessner Rd", "Elm St", "Cedar Ct", "Post Oak Blvd"]
DOMAINS = ["examplemail.com", "mailtest.net", "fakeinbox.org", "sample.io"]
CATEGORIES = ["Apparel", "Home", "Electronics", "Beauty", "Toys", "Grocery", "Outdoor"]
TIERS = ["BRONZE", "SILVER", "GOLD", "PLATINUM"]


def rand_date(rng, start, end):
    return start + timedelta(days=rng.randint(0, (end - start).days))


def write_csv(path, header, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--customers", type=int, default=25000)
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--out", default="data")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    os.makedirs(args.out, exist_ok=True)

    customers, prefs, txns, history = [], [], [], []
    emails_used = []
    txn_id = 1

    for i in range(1, args.customers + 1):
        cid = 100000 + i
        fn, ln = rng.choice(FIRST), rng.choice(LAST)
        city, state, zp = rng.choice(CITIES)
        zip5 = f"{zp}{rng.randint(1, 99):02d}"
        email = f"{fn.lower()}.{ln.lower()}{rng.randint(1, 9999)}@{rng.choice(DOMAINS)}"
        phone = f"{rng.choice(['713', '281', '832', '346', '214', '512'])}{rng.randint(2000000, 9999999)}"
        addr = f"{rng.randint(100, 19999)} {rng.choice(STREETS)}"
        enroll = rand_date(rng, date(2016, 1, 1), date(2026, 6, 30))
        birth = rand_date(rng, date(1945, 1, 1), date(2006, 12, 31))
        tier = rng.choices(TIERS, weights=[55, 25, 15, 5])[0]
        status = rng.choices(["ACTIVE", "CLOSED", "DECEASED"], weights=[95, 4, 1])[0]

        # --- injected data quality issues ---
        r = rng.random()
        if r < 0.04:
            email = ""                                         # missing email
        elif r < 0.06:
            email = email.replace("@", "")                     # malformed email
        elif r < 0.075 and emails_used:
            email = rng.choice(emails_used[-500:])             # duplicate household/person
        if rng.random() < 0.01:
            zip5 = rng.choice(["0000", "ABCDE", "", "7700"])   # bad ZIP
        if rng.random() < 0.03:
            addr = ""                                          # missing address
        if rng.random() < 0.02:
            phone = ""
        if email:
            emails_used.append(email)

        customers.append([cid, fn, ln, email, phone, addr, city, state, zip5,
                          birth.isoformat(), enroll.isoformat(), tier, status])

        email_opt = 1 if rng.random() < 0.78 else 0
        sms_opt = 1 if rng.random() < 0.35 else 0
        dm_opt = 1 if rng.random() < 0.90 else 0
        dnc = 1 if rng.random() < 0.02 else 0
        prefs.append([cid, email_opt, sms_opt, dm_opt, dnc,
                      rand_date(rng, enroll, AS_OF - timedelta(days=1)).isoformat()])

        # --- purchase behavior: pick a recency profile ---
        profile = rng.choices(["active", "at_risk", "lapsed", "dormant", "never"],
                              weights=[38, 20, 22, 15, 5])[0]
        if profile != "never":
            last_gap = {"active": (1, 90), "at_risk": (91, 180),
                        "lapsed": (181, 365), "dormant": (366, 900)}[profile]
            last = AS_OF - timedelta(days=rng.randint(*last_gap))
            n = max(1, int(rng.expovariate(1 / (6 if tier in ("GOLD", "PLATINUM") else 3))))
            if last < enroll:  # can't buy before enrolling; keep the recency profile
                last = enroll + timedelta(days=rng.randint(0, max(0, (AS_OF - enroll).days - 1)))
            first_possible = max(enroll, last - timedelta(days=1095))
            dates = sorted({last} | {rand_date(rng, first_possible, last) for _ in range(n - 1)})
            for d in dates:
                base = {"BRONZE": 45, "SILVER": 70, "GOLD": 110, "PLATINUM": 180}[tier]
                amt = round(max(4.99, rng.gauss(base, base * 0.5)), 2)
                if rng.random() < 0.03:
                    amt = -round(amt * rng.uniform(0.2, 1.0), 2)  # returns
                txns.append([txn_id, cid, d.isoformat(),
                             rng.choices(["STORE", "WEB", "APP"], weights=[55, 30, 15])[0],
                             amt, rng.choice(CATEGORIES)])
                txn_id += 1

        # --- prior contact history (fall promo + recent emails) ---
        if rng.random() < 0.55:
            ch = rng.choice(["EMAIL", "DM", "SMS"])
            cdate = date(2026, 9, rng.randint(8, 20))
            resp = 1 if rng.random() < {"EMAIL": 0.035, "DM": 0.022, "SMS": 0.041}[ch] else 0
            history.append([cid, "FALL26", ch, cdate.isoformat(), resp,
                            (cdate + timedelta(days=rng.randint(1, 21))).isoformat() if resp else ""])
        if rng.random() < 0.12:  # contacted in the last 14 days -> fatigue suppression
            cdate = AS_OF - timedelta(days=rng.randint(1, 14))
            history.append([cid, "OCT26_FLASH", "EMAIL", cdate.isoformat(), 0, ""])

    write_csv(f"{args.out}/customers.csv",
              ["customer_id", "first_name", "last_name", "email", "phone", "address", "city",
               "state", "zip", "birth_date", "enroll_date", "loyalty_tier", "account_status"],
              customers)
    write_csv(f"{args.out}/contact_preferences.csv",
              ["customer_id", "email_opt_in", "sms_opt_in", "dm_opt_in", "do_not_contact",
               "updated_date"], prefs)
    write_csv(f"{args.out}/transactions.csv",
              ["txn_id", "customer_id", "txn_date", "channel", "amount", "category"], txns)
    write_csv(f"{args.out}/contact_history.csv",
              ["customer_id", "campaign_id", "channel", "contact_date", "responded",
               "response_date"], history)

    # Global suppression files (as typically delivered by compliance / ESP)
    sample = rng.sample(customers, 400)
    write_csv(f"{args.out}/suppress_email_bounces.csv", ["email"],
              [[c[3]] for c in sample[:250] if c[3]])
    write_csv(f"{args.out}/suppress_legal_hold.csv", ["customer_id", "reason"],
              [[c[0], rng.choice(["LITIGATION", "FRAUD_REVIEW", "BANKRUPTCY"])] for c in sample[250:310]])
    write_csv(f"{args.out}/suppress_employees.csv", ["customer_id"],
              [[c[0]] for c in sample[310:400]])

    print(f"customers={len(customers)} transactions={len(txns)} "
          f"contact_history={len(history)} -> {args.out}/")


if __name__ == "__main__":
    main()
