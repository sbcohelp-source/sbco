"""Persisted onboarding HTTP tests in a disposable database on test PostgreSQL 55438."""
import json
import secrets
import subprocess
import urllib.error
import urllib.request
import uuid

import integration
from reliability import ROOT, Rehearsal
from integration import Client


def expect_status(client, path, body, expected):
    request = urllib.request.Request(
        integration.BASE + path, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "X-SBCO-Request": "1"},
    )
    try:
        response = client.opener.open(request, timeout=30)
        assert response.status == expected
    except urllib.error.HTTPError as error:
        assert error.code == expected, (path, error.code)


def run():
    rehearsal = Rehearsal()
    rehearsal.sql(f"CREATE DATABASE {rehearsal.database};", "sbco")
    try:
        subprocess.run(
            [str(ROOT / "target/debug/sbco-api"), "--bootstrap"],
            env=rehearsal.env, capture_output=True, check=True,
        )
        process = rehearsal.start("sbco-api")

        def connect():
            try:
                return rehearsal.client()
            except OSError:
                return None

        admin = rehearsal.wait(connect)
        initial = admin.query("onboarding")
        assert initial == {
            "step": "welcome", "completed": False, "office_count": 0,
            "assigned_office_count": 0, "user_count": 1,
            "import_count": 0, "transaction_count": 0,
        }, initial
        anonymous = Client()
        anonymous.call("query", {"kind": "onboarding"}, expected=401)
        anonymous.command("save_onboarding", step="welcome", completed=False, expected=401)
        expect_status(anonymous, "setup", {}, 404)
        admin.command("save_onboarding", step="ready", completed=True, expected=400)
        admin.command("save_onboarding", step="welcome", completed=True, expected=400)
        assert admin.query("onboarding") == initial
        assert rehearsal.sql("SELECT count(*) FROM user_onboarding") == "0"
        assert rehearsal.sql("SELECT count(*) FROM audit WHERE action='save_onboarding'") == "0"
        print("PASS authenticated-only onboarding and zero-office administrator completion gate")

        password = secrets.token_urlsafe(24)
        users = {}
        for label, role in [("pa", "Pa"), ("other", "Pa"), ("supervisor", "Supervisor")]:
            user_id = admin.command("create_user", name=label, email=f"{label}@example.test", password=password, role=role)["id"]
            users[label] = (user_id, rehearsal.client(f"{label}@example.test", password))
        pa_id, pa = users["pa"]
        other_id, other = users["other"]
        supervisor_id, supervisor = users["supervisor"]
        disabled_id = admin.command("create_user", name="Disabled user", email="disabled@example.test", password=password, role="Pa")["id"]
        admin.command("update_user", user_id=disabled_id, name="Disabled user", role="Pa", active=False)
        for step in ["welcome", "offices", "team", "preferences", "import", "ready"]:
            assert admin.command("save_onboarding", step=step, completed=False) == {"step": step, "completed": False}
        for client in [pa, supervisor]:
            for step in ["welcome", "work", "review", "ready"]:
                client.command("save_onboarding", step=step, completed=False)
            for forbidden in ["offices", "team", "preferences", "import"]:
                client.command("save_onboarding", step=forbidden, completed=False, expected=400)
            client.command("save_onboarding", step="review", completed=True, expected=400)
        for forbidden in ["work", "review", "unknown", " READY "]:
            admin.command("save_onboarding", step=forbidden, completed=False, expected=400)
        pa.command("save_onboarding", step="ready", completed=True)
        assert pa.query("onboarding")["completed"] is True
        assert other.query("onboarding")["step"] == "welcome"
        assert other.query("onboarding")["completed"] is False
        expect_status(admin, "command", {"request_id": str(uuid.uuid4()), "command": {
            "kind": "save_onboarding", "step": "ready", "completed": False,
            "user_id": pa_id,
        }}, 422)
        print("PASS role-specific steps, completion-at-ready validation, and per-user isolation")

        request_id = str(uuid.uuid4())
        first = admin.command("save_onboarding", request_id=request_id, step="offices", completed=False)
        assert first == admin.command("save_onboarding", request_id=request_id, step="offices", completed=False)
        admin.command("save_onboarding", request_id=request_id, step="team", completed=False, expected=409)
        pa.command("save_onboarding", request_id=request_id, step="offices", completed=False, expected=409)
        receipts = [row for row in admin.query("audit") if row["action"] == "save_onboarding" and row["detail"]["request_id"] == request_id]
        assert len(receipts) == 1, receipts
        print("PASS ordinary idempotency receipts and single audit entry on replay")

        for office in ["ONBOARD-A", "ONBOARD-B", "ONBOARD-C"]:
            admin.command("save_office", id=office, name=office, office_type="SO", parent_id=None)
        admin.command("save_pool", id=None, name="PA pool", offices=["ONBOARD-A"], pa_user=pa_id, random_percent=0)
        admin.command("save_pool", id=None, name="Other pool", offices=["ONBOARD-B"], pa_user=other_id, random_percent=0)
        import_id = str(uuid.uuid4())
        rehearsal.sql(f"""
            INSERT INTO imports(id,filename,file_hash,content,imported_by)
            SELECT '{import_id}', 'onboarding-fixture.xlsx', 'onboarding-fixture', ''::bytea, id
            FROM users WHERE email='admin@example.test';
        """)
        for office, count in [("ONBOARD-A", 2), ("ONBOARD-B", 3), ("ONBOARD-C", 4)]:
            for index in range(count):
                transaction_id = str(uuid.uuid4())
                rehearsal.sql(f"""
                    INSERT INTO transactions(id,office_id,report_type,report_date,value_date,
                      account_number,credit,debit,import_id,source_sheet,source_row,fingerprint)
                    VALUES('{transaction_id}','{office}','SO','2026-10-28','2026-10-28',
                      '000{index}',10.25,0,'{import_id}','{office}',{index+1},'{transaction_id}');
                """)
        expected_counts = {"office_count": 3, "assigned_office_count": 2, "user_count": 4, "import_count": 1, "transaction_count": 9}
        for client in [admin, supervisor]:
            result = client.query("onboarding")
            assert {key: result[key] for key in expected_counts} == expected_counts, result
        for client, count in [(pa, 2), (other, 3)]:
            result = client.query("onboarding")
            assert result["office_count"] == result["assigned_office_count"] == 1, result
            assert result["transaction_count"] == count, result
            assert result["user_count"] is None and result["import_count"] is None, result
        print("PASS global manager counts and PA office/transaction count isolation")

        admin.command("save_onboarding", step="ready", completed=True)
        pa.command("save_onboarding", step="review", completed=False)
        supervisor.command("save_onboarding", step="work", completed=False)
        saved = {"admin": admin.query("onboarding"), "pa": pa.query("onboarding"), "supervisor": supervisor.query("onboarding")}
        process.terminate()
        process.wait(timeout=15)
        rehearsal.start("sbco-api")
        admin = rehearsal.wait(connect)
        pa = rehearsal.client("pa@example.test", password)
        supervisor = rehearsal.client("supervisor@example.test", password)
        for label, client in [("admin", admin), ("pa", pa), ("supervisor", supervisor)]:
            assert client.query("onboarding") == saved[label]
        admin.command("save_onboarding", step="welcome", completed=False)
        assert admin.query("onboarding")["completed"] is False
        assert admin.query("onboarding")["step"] == "welcome"
        admin.command("update_user", user_id=supervisor_id, name="Promoted supervisor", role="Administrator", active=True)
        supervisor = rehearsal.client("supervisor@example.test", password)
        assert supervisor.query("onboarding")["step"] == "welcome"
        assert supervisor.query("onboarding")["completed"] is False
        pa.command("save_onboarding", step="ready", completed=True)
        assert pa.query("onboarding")["completed"] is True
        admin.command("update_user", user_id=pa_id, name="Promoted PA", role="Administrator", active=True)
        pa = rehearsal.client("pa@example.test", password)
        assert pa.query("onboarding")["step"] == "welcome"
        assert pa.query("onboarding")["completed"] is False
        pa.command("save_onboarding", step="offices", completed=False)
        assert pa.query("onboarding")["step"] == "offices"
        print("PASS process-restart persistence, explicit restart and completed-guide reset after role changes")
    finally:
        for process in rehearsal.processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
        rehearsal.sql(f"DROP DATABASE {rehearsal.database} WITH (FORCE);", "sbco")
        rehearsal.logs.cleanup()


if __name__ == "__main__":
    run()
