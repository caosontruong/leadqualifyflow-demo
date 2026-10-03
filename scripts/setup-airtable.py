#!/usr/bin/env python3
"""Create (or check) the two Airtable tables the pipeline writes to: Leads and Customers.

The workflow fails with 422 UNKNOWN_FIELD_NAME or INVALID_VALUE_FOR_COLUMN when a field name or
field type differs from what it writes, so this script creates the tables and fields with the exact
names and types, and reports anything that does not match.

Prepare:
  1. Create an empty Airtable base and note its id (the "app..." part of its URL).
  2. Create a personal access token for that base with the scopes
       data.records:read, data.records:write, schema.bases:read, schema.bases:write.
     The two schema scopes are only needed by this script; you can remove them afterwards.
  3. Put AIRTABLE_API_KEY, AIRTABLE_BASE_ID and AIRTABLE_TABLE_NAME (default Leads) in .env.

Usage:
  python3 scripts/setup-airtable.py            # create what is missing, then verify
  python3 scripts/setup-airtable.py --check    # read only: report differences, change nothing
Exit code: 0 = everything matches, 1 = something was missing (--check) or an API call failed,
2 = a field exists with the wrong type (Airtable cannot change a field type through the API:
change it in the Airtable UI, or delete it there and run this script again).
"""
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = os.environ.get("AIRTABLE_API_URL", "https://api.airtable.com").rstrip("/")
TEXT, LONG, NUMBER, SELECT, LINK = "singleLineText", "multilineText", "number", "multipleSelects", "multipleRecordLinks"
CHANNELS = ["email", "phone", "telegram", "whatsapp", "zalo", "facebook_messenger", "none"]

CUSTOMERS = "Customers"
CUSTOMER_FIELDS = [  # name, type, extra options
    ("Primary Email", TEXT), ("Primary Phone", TEXT), ("First Seen At", TEXT), ("Last Seen At", TEXT),
    ("Status", TEXT), ("Total Leads", NUMBER, {"precision": 0}),
]
LEAD_FIELDS = [
    ("Email", TEXT), ("Phone", TEXT), ("Message", LONG), ("Classification", TEXT),
    ("Confidence", NUMBER, {"precision": 2}), ("Draft Reply", LONG), ("Received At", TEXT), ("Source", TEXT),
    ("Chat ID", TEXT), ("Lead Score", NUMBER, {"precision": 2}), ("Fit Score", NUMBER, {"precision": 2}),
    ("Intent Score", NUMBER, {"precision": 2}), ("Score Reason", LONG), ("Score Version", TEXT),
    ("Legacy Classification", TEXT), ("Outreach Channel", SELECT, {"choices": [{"name": c} for c in CHANNELS]}),
    ("Outreach Identifier", TEXT), ("Phone (In Message)", TEXT),
]


def read_env():
    env = {}
    path = ROOT / ".env"
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip()
    for key in ("AIRTABLE_API_KEY", "AIRTABLE_BASE_ID", "AIRTABLE_TABLE_NAME"):
        env[key] = os.environ.get(key) or env.get(key, "")
    return env


class Airtable:
    def __init__(self, token, base):
        self.token, self.base = token, base

    def call(self, method, path, body=None):
        request = urllib.request.Request(
            f"{API}/v0/meta/bases/{self.base}{path}", method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:300]
            hint = ""
            if err.code in (401, 403):
                hint = "\nCheck the token scopes (data.records:read/write, schema.bases:read/write) and that it covers this base."
            sys.exit(f"Airtable API error {err.code} on {method} {path}: {detail}{hint}")

    def tables(self):
        return {t["name"]: t for t in self.call("GET", "/tables")["tables"]}


def main():
    check_only = "--check" in sys.argv
    env = read_env()
    token, base = env.get("AIRTABLE_API_KEY", ""), env.get("AIRTABLE_BASE_ID", "")
    leads = env.get("AIRTABLE_TABLE_NAME") or "Leads"
    if not token or not base:
        sys.exit("AIRTABLE_API_KEY and AIRTABLE_BASE_ID must be set in .env")
    at = Airtable(token, base)
    changed, problems, wrong_type = [], [], []

    def ensure_table(name):
        tables = at.tables()
        if name in tables:
            return tables[name]
        if check_only:
            problems.append(f"table missing: {name}")
            return None
        created = at.call("POST", "/tables", {"name": name, "fields": [{"name": "Name", "type": TEXT}]})
        changed.append(f"created table {name}")
        return created

    def ensure_field(table, spec):
        name, kind = spec[0], spec[1]
        options = spec[2] if len(spec) > 2 else None
        have = {f["name"]: f for f in table["fields"]}
        if name in have:
            if have[name]["type"] != kind:
                wrong_type.append(f"{table['name']}.{name}: is {have[name]['type']}, must be {kind}")
            return
        if check_only:
            problems.append(f"field missing: {table['name']}.{name} ({kind})")
            return
        body = {"name": name, "type": kind}
        if options:
            body["options"] = options
        at.call("POST", f"/tables/{table['id']}/fields", body)
        changed.append(f"created field {table['name']}.{name} ({kind})")

    customers = ensure_table(CUSTOMERS)
    lead_table = ensure_table(leads)
    if customers and lead_table:
        for spec in CUSTOMER_FIELDS:
            ensure_field(customers, spec)
        customers = at.tables()[CUSTOMERS] if not check_only else customers
        ensure_field(customers, ("Merged Into", LINK, {"linkedTableId": customers["id"]}))
        for spec in LEAD_FIELDS:
            ensure_field(lead_table, spec)
        lead_table = at.tables()[leads] if not check_only else lead_table
        ensure_field(lead_table, ("Customer", LINK, {"linkedTableId": customers["id"]}))

    tables = at.tables()
    # Airtable creates the reverse of Leads.Customer inside Customers; the workflow expects it to be called "Leads".
    if CUSTOMERS in tables and leads in tables:
        cust, lead = tables[CUSTOMERS], tables[leads]
        names = {f["name"] for f in cust["fields"]}
        if "Leads" not in names:
            reverse = [f for f in cust["fields"] if f["type"] == LINK
                       and (f.get("options") or {}).get("linkedTableId") == lead["id"]]
            if reverse and not check_only:
                at.call("PATCH", f"/tables/{cust['id']}/fields/{reverse[0]['id']}", {"name": "Leads"})
                changed.append(f"renamed {CUSTOMERS}.{reverse[0]['name']} to Leads")
            else:
                problems.append("field missing: Customers.Leads (appears when Leads.Customer is created)")

    # Final verification (read only).
    tables = at.tables()
    missing = []
    for tname, fields in ((CUSTOMERS, CUSTOMER_FIELDS + [("Merged Into", LINK), ("Leads", LINK)]),
                          (leads, [("Name", TEXT)] + LEAD_FIELDS + [("Customer", LINK)])):
        have = {f["name"]: f for f in (tables.get(tname) or {"fields": []})["fields"]}
        for spec in fields:
            if spec[0] not in have:
                missing.append(f"{tname}.{spec[0]}")
            elif have[spec[0]]["type"] != spec[1]:
                entry = f"{tname}.{spec[0]}: is {have[spec[0]]['type']}, must be {spec[1]}"
                if entry not in wrong_type:
                    wrong_type.append(entry)
    for line in changed:
        print("  +", line)
    for line in problems:
        print("  !", line)
    for line in wrong_type:
        print("  ! WRONG TYPE", line)
    if wrong_type:
        print("\nAirtable cannot change a field type through the API. Fix it in Airtable (field menu -> Edit field),\n"
              "or delete the field there and run this script again.")
        sys.exit(2)
    if missing or (check_only and problems):
        print("\nStill missing:", ", ".join(missing) or "see above")
        sys.exit(1)
    print(f"OK: tables {leads} ({len(tables[leads]['fields'])} fields) and {CUSTOMERS} ({len(tables[CUSTOMERS]['fields'])} fields) "
          "match what the workflow writes.")


if __name__ == "__main__":
    main()
