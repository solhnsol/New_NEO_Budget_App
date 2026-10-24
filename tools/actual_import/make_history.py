#!/usr/bin/env python3
"""Builds imported-history.json (see docs/actual-budget-import.md) from what the Actual Budget tools return.

Read-only: it only reads the JSON files you give it and writes one output file. Nothing here talks to Actual.

  1. Save the result of `list_accounts` to accounts.json.
  2. Save the result(s) of `list_transactions` (since=<first day>, limit=500) to tx-1.json, tx-2.json, ...
     One call returns at most 500 rows: when `total_matches` is larger than `returned`, call again with an earlier `until`.
  3. python3 tools/actual_import/make_history.py --accounts accounts.json --transactions tx-*.json \
         --through 2026-10-19 --card "현대카드 MM" --prepaid 카카오페이 --prepaid 티머니 --out imported-history.json

The output holds real financial data. Never put it in git (`data/` is ignored; keep it outside the repo or in the
private project files) and delete it after the phone has imported it.

Exit status 1 when an account's rows do not add up to the balance Actual reports (a split parent returned next to its
children, a missing page, an account not listed): fix that before importing.
"""
import argparse
import json
import sys
from collections import defaultdict

ROW_FIELDS = ("id", "date", "account", "amount", "payee", "category", "notes", "imported_payee", "transfer")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def build(accounts_json, transaction_jsons, through, cards=(), prepaid=(), zone="Asia/Seoul"):
    """Returns (history dict, problems list). Pure, so it can be tested with made-up data."""
    problems = []
    rows, seen = [], set()
    for result in transaction_jsons:
        returned = result.get("returned", len(result.get("transactions", [])))
        total = result.get("total_matches", returned)
        if total > returned:
            problems.append(f"a page returned {returned} of {total} rows: fetch the rest (earlier `until`)")
        for tx in result.get("transactions", []):
            if tx["id"] in seen:
                continue
            seen.add(tx["id"])
            rows.append({k: tx.get(k) for k in ROW_FIELDS if tx.get(k) is not None})

    accounts = []
    for a in accounts_json["accounts"]:
        name = a["name"]
        kind = "card" if name in cards else "prepaid" if name in prepaid else "bank"
        accounts.append({"name": name, "kind": kind, "on_budget": bool(a.get("on_budget", True)), "balance": a.get("balance")})

    names = {a["name"] for a in accounts}
    sums = defaultdict(int)
    for r in rows:
        if r["account"] not in names:
            problems.append(f"row {r['id']} is on an account that is not in the account list: {r['account']}")
        sums[r["account"]] += r["amount"]
    for a in accounts:
        if a["balance"] is not None and sums[a["name"]] != a["balance"]:
            problems.append(f"{a['name']}: rows add up to {sums[a['name']]} but Actual reports {a['balance']}")
    for r in rows:
        if r["date"] > through:
            problems.append(f"row {r['id']} is dated {r['date']}, after --through {through}")

    rows.sort(key=lambda r: (r["date"], r["id"]))
    history = {"version": 1, "source": "actual", "timeZone": zone, "through": through, "accounts": accounts, "transactions": rows}
    return history, problems


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--accounts", required=True)
    p.add_argument("--transactions", required=True, nargs="+")
    p.add_argument("--through", required=True, help="last day the file covers, YYYY-MM-DD (usually today)")
    p.add_argument("--card", action="append", default=[], help="credit card account name (its balance is debt)")
    p.add_argument("--prepaid", action="append", default=[], help="prepaid wallet / transit card account name")
    p.add_argument("--out", required=True)
    args = p.parse_args(argv)

    history, problems = build(load(args.accounts), [load(path) for path in args.transactions], args.through, args.card, args.prepaid)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(history, f, ensure_ascii=False, indent=1)
    print(f"{len(history['transactions'])} rows, {len(history['accounts'])} accounts -> {args.out}")
    for problem in problems:
        print("PROBLEM:", problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
