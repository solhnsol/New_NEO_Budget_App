#!/usr/bin/env python3
"""Local-only, stdlib-only coverage synthesis. No source text reaches output."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile

POLICY = "coverage-synthesis-v1"
BASE_MS = 946684800000  # Fixed synthetic epoch, unrelated to collection time.
EVENT_TYPES = frozenset({
    "woori_in", "woori_out", "card_approval", "card_cancel",
    "credit_approval", "credit_cancel", "tb_in", "tb_out", "tb_interest",
    "toss_person_in", "toss_pay", "toss_pay_acct", "kp_send",
    "kp_receive_request", "kp_charge", "tmoney",
})
ITEM_TYPES = {
    "entries": frozenset({"event", "event_change", "todo", "budget_note", "memo"}),
    "inbox_items": frozenset({"calendar_event", "task", "note", "reference", "unknown"}),
}
INBOX_TEXT = {
    "event": "내일 가상장소에서 가상상대와 약속",
    "event_change": "가상 약속을 내일로 변경",
    "todo": "내일 가상작업 완료하기",
    "budget_note": "가상상점에서 12,000원 사용",
    "memo": "가상 메모", "calendar_event": "가상 일정",
    "task": "가상 작업", "note": "가상 노트",
    "reference": "가상 참고자료", "unknown": "가상 미분류 입력",
}


def shape(event):
    """Only finite enumerations/booleans cross the privacy boundary."""
    kind = event.get("type")
    if not isinstance(kind, str) or kind not in EVENT_TYPES:
        return None
    variant = "default"
    if kind in {"woori_in", "woori_out", "tb_in", "kp_send"}:
        flag = {"woori_in": "ownSelf", "woori_out": "ownToss",
                "tb_in": "ownSelf", "kp_send": "ownDest"}[kind]
        variant = "self" if event.get(flag) is True else "other"
    elif kind == "toss_pay":
        variant = "credit" if event.get("credit") is True else "debit"
    elif kind == "tmoney":
        variant = "balance" if event.get("fare") is None else "ride"
    elif kind in {"card_approval", "card_cancel", "credit_approval", "credit_cancel"}:
        variant = "installment" if event.get("installment") not in (None, "일시불") else "single"
    return kind, variant


def notification(kind, variant):
    """Render from code literals, never interpolate any original value."""
    amount, balance = "12,000", "100,000"
    own = variant == "self"
    party = "가상본인" if own else "가상상대"
    provider, title, subtitle, body = "", None, None, None
    if kind in {"woori_in", "woori_out"}:
        provider = "woori"
        direction = "입금" if kind == "woori_in" else "출금"
        if own and kind == "woori_out":
            party = "토뱅가상본인"
        title = f"[{direction}]"
        body = f"{party} {amount}원 000***계좌 잔액 {balance}원 01/01 09:00:00"
    elif kind.startswith("card_") or kind.startswith("credit_"):
        provider = "hyundai"
        card = "체크" if kind.startswith("card_") else "가상카드"
        action = "승인취소" if kind.endswith("cancel") else "승인"
        payment = "3개월" if variant == "installment" else "일시불"
        title = f"가상본인 님, 현대 {card} {action}"
        subtitle = f"{amount}원 {payment}, 1/1 09:00"
        body = "가상상점"
    elif kind in {"tb_in", "tb_out", "tb_interest"}:
        provider = "toss"
        if kind == "tb_interest":
            title, body = "오늘은 토스뱅크 이자 받는 날🎉", "10원을 통장에 쏙! 넣어드렸어요."
        elif kind == "tb_in":
            title, body = f"{amount}원 입금", f"{party} → 내 토스뱅크 통장"
        else:
            title, body = f"{amount}원 출금", "내 토스뱅크 통장 → 가상상대"
    elif kind == "toss_person_in":
        provider, title = "toss", "송금"
        body = f"가상상대님이 보낸 {amount}원이 내 가상은행 계좌로 입금됐어요"
    elif kind == "toss_pay":
        provider, title = "toss", f"{amount}원 결제"
        method = "현대카드가상카드" if variant == "credit" else "M CHECK"
        body = f"페이스페이 ({method}) | 가상상점 (일시불)"
    elif kind == "toss_pay_acct":
        provider, title, body = "toss", f"{amount}원 결제 완료", "우리은행 ・ 가상상점"
    elif kind == "kp_send":
        provider, title = "kakaopay", "송금이 완료되었어요"
        target = "우리은행 (가**인)" if own else "가상은행 (가**대)"
        body = f"{target} 계좌로 {amount}원을 송금했어요"
    elif kind == "kp_receive_request":
        provider, title, body = "kakaopay", "송금을 받아주세요", f"가**대님이 {amount}원을 보냈어요"
    elif kind == "kp_charge":
        provider, body = "kakaopay", f"{amount}원 충전이 완료되었어요"
    elif kind == "tmoney":
        provider, title = "wallet", "Tmoney"
        subtitle = "₩1,000 for Metro" if variant == "ride" else None
        body = f"Your {'new' if variant == 'ride' else 'current'} balance is ₩100,000."
    else:
        raise ValueError("unsupported synthetic shape")
    return {
        "id": f"synthetic-{kind}-{variant}",
        "source": {"applicationIdentifier": f"fixture.{provider}", "providerHint": provider},
        "capturedAtUnixMilliseconds": BASE_MS,
        "title": title, "subtitle": subtitle, "body": body,
        # Neither original IDs nor fabricated stable delivery guarantees.
        "sourceDeliveryID": None, "notificationAtUnixMilliseconds": None, "rawPayload": None,
    }


def read_shapes(path, source):
    """A bounded read transaction includes live WAL; never creates or migrates a DB."""
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=5)
    connection.execute("PRAGMA query_only = ON")
    found, report = set(), {"rows": 0, "unsupported": 0, "malformed": 0}
    try:
        connection.execute("BEGIN")
        if source == "ingest":
            # Do not SELECT notifications.raw, names, IDs, timestamps, amounts or balances.
            for (payload,) in connection.execute("SELECT json FROM events"):
                report["rows"] += 1
                try:
                    event = json.loads(payload)
                    selected = shape(event) if isinstance(event, dict) else None
                except (ValueError, TypeError):
                    report["malformed"] += 1
                    continue
                if selected is None:
                    report["unsupported"] += 1
                else:
                    found.add(selected)
            report["unparsedNotifications"] = connection.execute(
                "SELECT COUNT(*) FROM notifications WHERE status = 'unparsed'"
            ).fetchone()[0]
            report["pendingNotifications"] = connection.execute(
                "SELECT COUNT(*) FROM notifications WHERE status = 'new'"
            ).fetchone()[0]
        else:
            for table, column in (("entries", "kind"), ("inbox_items", "type")):
                for (kind,) in connection.execute(f"SELECT {column} FROM {table}"):
                    report["rows"] += 1
                    if isinstance(kind, str) and kind in ITEM_TYPES[table]:
                        found.add((table, kind))
                    else:
                        report["unsupported"] += 1
        connection.rollback()
    finally:
        connection.close()
    return found, report


def catalog_shapes():
    result = set()
    for kind in EVENT_TYPES:
        variants = ("default",)
        if kind in {"woori_in", "woori_out", "tb_in", "kp_send"}:
            variants = ("self", "other")
        elif kind == "toss_pay":
            variants = ("credit", "debit")
        elif kind == "tmoney":
            variants = ("balance", "ride")
        elif kind.startswith("card_") or kind.startswith("credit_"):
            variants = ("single", "installment")
        result.update((kind, variant) for variant in variants)
    return result


def dataset(notification_shapes, inbox_shapes, reports):
    records = [notification(*s) for s in sorted(notification_shapes)]
    inbox = [{"id": f"synthetic-{table}-{kind}", "table": table, "kind": kind,
              "text": INBOX_TEXT[kind]} for table, kind in sorted(inbox_shapes)]
    encoded = json.dumps({"notifications": records, "inboxShapes": inbox},
                         sort_keys=True, ensure_ascii=False).encode()
    return {"schemaVersion": 1, "policyVersion": POLICY,
            "purpose": "synthetic format coverage; not transaction ground truth",
            "contentDigest": hashlib.sha256(encoded).hexdigest(),
            "notifications": records, "inboxShapes": inbox, "localReport": reports}


def atomic_write(path, payload, sources=()):
    path = path.expanduser().absolute()
    if path.suffix != ".json" or ".git" in path.parts or path.is_symlink():
        raise ValueError("output must be a regular .json path outside Git metadata")
    if any(path.resolve() == p.resolve() for p in sources):
        raise ValueError("output cannot replace a source")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".synthesis-", delete=False) as handle:
            temporary = Path(handle.name)
            os.chmod(temporary, 0o600)
            json.dump(payload, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ingest-db", type=Path)
    parser.add_argument("--inbox-db", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--synthetic-catalog", action="store_true",
                        help="Generate public fixtures from code only; cannot read a database")
    args = parser.parse_args(argv)
    if args.synthetic_catalog and (args.ingest_db or args.inbox_db):
        parser.error("synthetic catalog cannot use production sources")
    if not args.synthetic_catalog and not (args.ingest_db or args.inbox_db):
        parser.error("select a source or --synthetic-catalog")
    try:
        notification_shapes, inbox_shapes, reports = set(), set(), {}
        if args.synthetic_catalog:
            notification_shapes = catalog_shapes()
        for source, path in (("ingest", args.ingest_db), ("inbox", args.inbox_db)):
            if path:
                found, reports[source] = read_shapes(path, source)
                (notification_shapes if source == "ingest" else inbox_shapes).update(found)
        payload = dataset(notification_shapes, inbox_shapes, reports)
        atomic_write(args.output, payload, [p for p in (args.ingest_db, args.inbox_db) if p])
    except (OSError, sqlite3.Error, ValueError):
        # Exceptions can contain paths, SQL or data. Logs carry no source values.
        print("Export failed; check source schema/access and output path. Previous output kept.",
              file=__import__("sys").stderr)
        return 1
    print(f"Generated {len(payload['notifications'])} notification shapes and "
          f"{len(payload['inboxShapes'])} inbox shapes ({POLICY}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
