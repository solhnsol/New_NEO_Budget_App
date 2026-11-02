import unittest

from make_history import build

# Made-up data in the shape of Actual's list_accounts / list_transactions.
ACCOUNTS = {"accounts": [
    {"id": "a", "name": "통장", "on_budget": True, "balance": 90_000},
    {"id": "b", "name": "카드", "on_budget": True, "balance": -10_000},
]}
TX = {"total_matches": 3, "returned": 3, "transactions": [
    {"id": "1", "date": "2026-10-01", "account": "통장", "amount": 100_000, "payee": "Starting Balance", "category": "Starting Balances", "notes": None},
    {"id": "2", "date": "2026-10-02", "account": "카드", "amount": -10_000, "payee": "가게", "category": "식비", "notes": "메모", "imported_payee": "가게 본점", "tags": ["x"]},
    {"id": "3", "date": "2026-10-03", "account": "통장", "amount": -10_000, "payee": None, "category": None, "notes": None, "transfer": "→ 카드"},
]}


class MakeHistoryTests(unittest.TestCase):
    def test_a_complete_export_has_no_problems_and_keeps_only_the_import_fields(self):
        history, problems = build(ACCOUNTS, [TX], "2026-10-19", cards=["카드"])
        self.assertEqual(problems, [])
        self.assertEqual([a["kind"] for a in history["accounts"]], ["bank", "card"])
        row = next(r for r in history["transactions"] if r["id"] == "2")
        self.assertEqual(row["imported_payee"], "가게 본점")
        self.assertNotIn("tags", row)
        self.assertNotIn("payee", next(r for r in history["transactions"] if r["id"] == "3"))

    def test_a_split_parent_next_to_its_children_shows_up_as_a_balance_mismatch(self):
        doubled = {"total_matches": 4, "returned": 4, "transactions": TX["transactions"] + [
            {"id": "4", "date": "2026-10-03", "account": "통장", "amount": -10_000, "payee": "부모", "category": None, "notes": None}]}
        _, problems = build(ACCOUNTS, [doubled], "2026-10-19", cards=["카드"])
        self.assertTrue(any("통장: rows add up to 80000" in p for p in problems))

    def test_a_short_page_a_repeated_row_and_a_late_row_are_reported_or_dropped(self):
        short = dict(TX, total_matches=9)
        late = {"total_matches": 1, "returned": 1, "transactions": [
            {"id": "5", "date": "2026-10-25", "account": "통장", "amount": 0, "payee": "x"}]}
        history, problems = build(ACCOUNTS, [short, TX, late], "2026-10-19", cards=["카드"])
        self.assertEqual(len(history["transactions"]), 4)  # the repeated rows were counted once
        self.assertTrue(any("3 of 9" in p for p in problems))
        self.assertTrue(any("after --through" in p for p in problems))


if __name__ == "__main__":
    unittest.main()
