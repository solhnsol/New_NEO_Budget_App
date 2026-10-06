import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "tools/test_data/export.py"
spec = importlib.util.spec_from_file_location("export", SCRIPT)
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "source.sqlite"
        self.output = self.root / "out/dataset.json"

    def ingest(self, events):
        c = sqlite3.connect(self.source)
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("CREATE TABLE events (json TEXT)")
        c.execute("CREATE TABLE notifications (status TEXT, raw TEXT)")
        c.executemany("INSERT INTO events VALUES (?)", [(json.dumps(e),) for e in events])
        c.execute("INSERT INTO notifications VALUES ('unparsed', 'PRIVATE RAW SECRET')")
        c.commit()
        self.addCleanup(c.close)
        return c

    def run_export(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return export.main(list(args))

    def test_private_values_never_cross_the_finite_shape_boundary(self):
        event = {"type": "woori_in", "ownSelf": True, "counterparty": "PRIVATE_PERSON",
                 "amount": 982376541, "balance": 917654329, "id": "PRIVATE_ID",
                 "acct": "PRIVATE_ACCOUNT", "date": "2026-09-19", "time": "19:43:27",
                 "unexpected": {"url": "https://private.example/token", "secret": "PRIVATE_TOKEN"}}
        c = self.ingest([event, {"type": "PRIVATE_NEW_TYPE"}])
        c.execute("INSERT INTO events VALUES ('{PRIVATE_MALFORMED')")
        c.commit()
        before = c.execute("SELECT json FROM events").fetchall()
        self.assertEqual(self.run_export("--ingest-db", str(self.source), "--output", str(self.output)), 0)
        text = self.output.read_text()
        for value in ("PRIVATE", "982376541", "917654329", "2026-09-19", "19:43:27", "private.example"):
            self.assertNotIn(value, text)
        data = json.loads(text)
        self.assertEqual(data["notifications"], [export.notification("woori_in", "self")])
        self.assertEqual(data["localReport"]["ingest"], {
            "rows": 3, "unsupported": 1, "malformed": 1,
            "unparsedNotifications": 1, "pendingNotifications": 0})
        self.assertEqual(before, c.execute("SELECT json FROM events").fetchall())
        self.assertEqual(os.stat(self.output).st_mode & 0o777, 0o600)

    def test_wal_refresh_sees_new_shapes_and_is_idempotent(self):
        c = self.ingest([{"type": "tb_in", "ownSelf": False}])
        args = ("--ingest-db", str(self.source), "--output", str(self.output))
        self.assertEqual(self.run_export(*args), 0)
        first = self.output.read_bytes()
        self.assertEqual(self.run_export(*args), 0)
        self.assertEqual(first, self.output.read_bytes())
        c.execute("INSERT INTO events VALUES (?)", (json.dumps({"type": "tb_out"}),))
        c.commit()
        self.assertEqual(self.run_export(*args), 0)
        self.assertEqual(len(json.loads(self.output.read_text())["notifications"]), 2)
        self.assertTrue(Path(str(self.source) + "-wal").exists())

    def test_failed_read_keeps_previous_output_and_does_not_create_source(self):
        self.output.parent.mkdir()
        self.output.write_text("previous")
        missing = self.root / "absent.sqlite"
        self.assertEqual(self.run_export("--ingest-db", str(missing), "--output", str(self.output)), 1)
        self.assertFalse(missing.exists())
        self.assertEqual(self.output.read_text(), "previous")
        self.ingest([])
        c = sqlite3.connect(self.source)
        c.execute("DROP TABLE events")
        c.commit()
        c.close()
        self.assertEqual(self.run_export("--ingest-db", str(self.source), "--output", str(self.output)), 1)
        self.assertEqual(self.output.read_text(), "previous")

    def test_changes_to_personal_values_cannot_change_the_generated_fixture(self):
        a = {"type": "credit_approval", "installment": "일시불", "amount": 123,
             "merchant": "Alice", "date": "2030-04-29"}
        b = {**a, "amount": 1987654321, "merchant": "Bob", "date": "2010-01-01"}
        self.assertEqual(export.shape(a), export.shape(b))
        self.assertEqual(export.dataset({export.shape(a)}, set(), {}),
                         export.dataset({export.shape(b)}, set(), {}))
        # Multiplicity and arrival order don't become a transaction history.
        self.assertEqual(export.dataset({export.shape(a), export.shape(b)}, set(), {}),
                         export.dataset({export.shape(a)}, set(), {}))

    def test_inbox_free_text_and_nested_results_are_not_read(self):
        c = sqlite3.connect(self.source)
        c.executescript("CREATE TABLE entries (kind TEXT, raw_text TEXT, parsed TEXT);"
                        "CREATE TABLE inbox_items (type TEXT, evidence_text TEXT);")
        c.execute("INSERT INTO entries VALUES ('todo', 'PRIVATE ADDRESS', 'PRIVATE PAYLOAD')")
        c.execute("INSERT INTO entries VALUES ('PRIVATE_KIND', 'PRIVATE PHONE', NULL)")
        c.execute("INSERT INTO inbox_items VALUES ('calendar_event', 'PRIVATE LOCATION')")
        c.commit()
        c.close()
        self.assertEqual(self.run_export("--inbox-db", str(self.source), "--output", str(self.output)), 0)
        self.assertNotIn("PRIVATE", self.output.read_text())
        data = json.loads(self.output.read_text())
        self.assertEqual(len(data["inboxShapes"]), 2)
        self.assertEqual(data["localReport"]["inbox"]["unsupported"], 1)

    def test_public_catalog_cannot_mix_with_production_sources(self):
        with self.assertRaises(SystemExit):
            self.run_export("--synthetic-catalog", "--ingest-db", str(self.source),
                            "--output", str(self.output))
        self.assertFalse(self.output.exists())
        self.assertEqual(self.run_export("--synthetic-catalog", "--output", str(self.output)), 0)
        fixture = SCRIPT.parents[2] / "Tests/NEOBudgetCoreTests/Fixtures/synthetic-notification-coverage.json"
        self.assertEqual(self.output.read_bytes(), fixture.read_bytes())
        self.assertEqual(json.loads(fixture.read_text())["localReport"], {})

    def test_output_cannot_overwrite_database_or_follow_file_symlink(self):
        self.ingest([])
        with self.assertRaises(ValueError):
            export.atomic_write(self.source, {})
        target = self.root / "untouched.json"
        target.write_text("original")
        link = self.root / "link.json"
        link.symlink_to(target)
        with self.assertRaises(ValueError):
            export.atomic_write(link, {})
        self.assertEqual(target.read_text(), "original")
        with self.assertRaises(ValueError):
            export.atomic_write(self.root / ".git/config.json", {})


if __name__ == "__main__":
    unittest.main()
