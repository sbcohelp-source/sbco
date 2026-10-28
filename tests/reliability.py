"""Disposable-database reliability rehearsal using the delivered XLSX templates.

Run after sourcing scripts/env.sh. The test creates and drops only its own
sbco_reliability_<random> database on the existing test PostgreSQL container.
It starts its own API and workers; no shared application processes are stopped.
"""
import base64
import concurrent.futures
import io
import os
import pathlib
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.parse
import uuid
import xml.etree.ElementTree as ET
import zipfile

import integration
from integration import Client, FILTER
from setup_import import NS, TEMPLATES

ROOT = pathlib.Path(__file__).resolve().parents[1]


def template(office, count, variant="first"):
    """Populate a copy, retaining the real template's headers, styles and sheets."""
    values = {"B1": office, "C1": "Reliability SO", "B2": "2026-10-01"}
    for i in range(count):
        for column, value in zip(
            "ABCDEFGHIJK",
            [i + 1, f"{i:012}", "SB", f"TXN-{i}", f"REF-{i}", "PA01",
             "Credit", "Deposit", "2026-10-01", 10.25, 0],
        ):
            values[f"{column}{i + 6}"] = value
    output = io.BytesIO()
    with zipfile.ZipFile(TEMPLATES / "SBCO_SO_Transactions_Template.xlsx") as source:
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as target:
            for entry in source.infolist():
                data = source.read(entry.filename)
                if entry.filename == "xl/worksheets/sheet1.xml":
                    tree = ET.fromstring(data)
                    body = tree.find(f"{{{NS}}}sheetData")
                    rows = {r.attrib["r"]: r for r in body}
                    for address, value in values.items():
                        number = "".join(c for c in address if c.isdigit())
                        if number not in rows:
                            rows[number] = ET.SubElement(body, f"{{{NS}}}row", r=number)
                        row = rows[number]
                        cell = row.find(f'{{{NS}}}c[@r="{address}"]')
                        if cell is None:
                            cell = ET.SubElement(row, f"{{{NS}}}c", r=address)
                        for child in list(cell):
                            cell.remove(child)
                        numeric = isinstance(value, (int, float))
                        cell.set("t", "n" if numeric else "inlineStr")
                        if numeric:
                            ET.SubElement(cell, f"{{{NS}}}v").text = str(value)
                        else:
                            ET.SubElement(ET.SubElement(cell, f"{{{NS}}}is"), f"{{{NS}}}t").text = value
                    # Keep rows in spreadsheet order, including preformatted blank rows.
                    body[:] = sorted(body, key=lambda row: int(row.attrib["r"]))
                    dimension = tree.find(f"{{{NS}}}dimension")
                    if dimension is not None:
                        dimension.set("ref", f"A1:K{count + 5}")
                    data = ET.tostring(tree)
                target.writestr(entry, data)
            # Two files can be semantically identical while differing in ZIP metadata.
            target.comment = variant.encode()
    return output.getvalue()


class Rehearsal:
    def __init__(self):
        self.database = "sbco_reliability_" + uuid.uuid4().hex[:12]
        self.container = os.environ.get("SBCO_TEST_POSTGRES_CONTAINER", "sbco-next-test-pg")
        self.processes = []
        self.logs = tempfile.TemporaryDirectory(prefix="sbco-reliability-")
        self.env = dict(os.environ)
        original = urllib.parse.urlsplit(self.env["DATABASE_URL"])
        assert original.hostname in ("127.0.0.1", "localhost") and original.port == 55438, "Use the isolated test PostgreSQL on port 55438"
        self.env["DATABASE_URL"] = urllib.parse.urlunsplit(original._replace(path="/" + self.database))
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.env.update(SBCO_BIND=f"127.0.0.1:{port}", SBCO_INSECURE_LOCAL_HTTP="1",
                        SBCO_ADMIN_NAME="Reliability administrator", SBCO_ADMIN_EMAIL="admin@example.test",
                        SBCO_ADMIN_PASSWORD=secrets.token_urlsafe(24))
        integration.BASE = f"http://127.0.0.1:{port}/api/v1/"

    def sql(self, sql, database=None):
        result = subprocess.run(
            ["docker", "--context", "default", "exec", "-i", self.container, "psql", "-X", "-q", "-A", "-t",
             "-v", "ON_ERROR_STOP=1", "-U", "sbco", "-d", database or self.database],
            input=sql, text=True, capture_output=True, check=True,
        )
        return result.stdout.strip()

    def start(self, name):
        log = open(pathlib.Path(self.logs.name) / f"{name}-{len(self.processes)}.log", "w")
        process = subprocess.Popen([str(ROOT / "target/debug" / name)], env=self.env, stdout=log, stderr=log)
        log.close()
        self.processes.append(process)
        return process

    def client(self, email=None, password=None):
        client = Client()
        client.login(email or self.env["SBCO_ADMIN_EMAIL"], password or self.env["SBCO_ADMIN_PASSWORD"])
        return client

    def recover(self, email, password, success=True):
        result = subprocess.run([str(ROOT / "target/debug/sbco-api"), "--recover-admin"],
                                env={**self.env, "SBCO_RECOVERY_EMAIL": email, "SBCO_RECOVERY_PASSWORD": password},
                                capture_output=True, text=True)
        assert (result.returncode == 0) == success, "Unexpected administrator recovery result"

    def wait(self, predicate, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(0.15)
        raise AssertionError("Timed out waiting for rehearsal condition")

    def run(self):
        self.sql(f"CREATE DATABASE {self.database};", "sbco")
        try:
            subprocess.run([str(ROOT / "target/debug/sbco-api"), "--bootstrap"], env=self.env, capture_output=True, check=True)
            self.start("sbco-api")
            def ready():
                try:
                    return urllib.request.urlopen(integration.BASE.replace("/api/v1/", "/health"), timeout=1).status == 200
                except OSError:
                    return False
            self.wait(ready)
            self.accounts()
            self.imports()
        finally:
            for process in self.processes:
                if process.poll() is None:
                    process.terminate()
            for process in self.processes:
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            assert self.database.startswith("sbco_reliability_")
            self.sql(f"DROP DATABASE IF EXISTS {self.database} WITH (FORCE);", "sbco")
            self.logs.cleanup()

    def accounts(self):
        admin = self.client()
        identity = admin.call("me")["id"]
        for role, active in [("Administrator", False), ("Supervisor", True)]:
            admin.command("update_user", user_id=identity, name="Admin", role=role, active=active, expected=400)
        password = secrets.token_urlsafe(24)
        user = admin.command("create_user", name="PA", email="pa@example.test", password=password, role="Pa")["id"]
        admin.command("save_office", id="ACCOUNT-SO", name="Account SO", office_type="SO", parent_id=None)
        pool = admin.command("save_pool", id=None, name="Account pool", offices=["ACCOUNT-SO"], pa_user=user, random_percent=0)["id"]
        pa1, pa2 = self.client("pa@example.test", password), self.client("pa@example.test", password)
        pa1.command("update_user", user_id=identity, name="Admin", role="Pa", active=True, expected=403)
        admin.command("update_user", user_id=user, name="Supervisor", role="Supervisor", active=True)
        pa1.call("me", expected=401)
        pa2.call("me", expected=401)
        assert next(p for p in admin.query("pools") if p["id"] == pool)["pa_user"] is None
        supervisor = self.client("pa@example.test", password)
        self.recover("pa@example.test", secrets.token_urlsafe(24), success=False)
        assert supervisor.call("me")["role"] == "Supervisor"
        replacement = secrets.token_urlsafe(24)
        admin.command("reset_password", user_id=user, password=replacement)
        supervisor.call("me", expected=401)
        Client().call("login", {"email": "pa@example.test", "password": password}, expected=401)
        changed = self.client("pa@example.test", replacement)
        changed.command("change_password", current_password="wrong-password", new_password=password, expected=401)
        changed.command("change_password", current_password=replacement, new_password=password)
        changed.call("me", expected=401)
        self.client("pa@example.test", password)
        admin.command("update_user", user_id=user, name="Disabled", role="Supervisor", active=False)
        Client().call("login", {"email": "pa@example.test", "password": password}, expected=401)
        # Race two self-demotions. The transaction-level lock must retain one active admin.
        second = admin.command("create_user", name="Second administrator", email="second@example.test", password=password, role="Administrator")["id"]
        clients = [admin, self.client("second@example.test", password)]
        def demote(item):
            client, uid = item
            try:
                client.command("update_user", user_id=uid, name="Former administrator", role="Supervisor", active=True)
                return "changed"
            except AssertionError as error:
                assert error.args[0][1] == 400, error
                return "protected"
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            assert sorted(executor.map(demote, zip(clients, [identity, second]))) == ["changed", "protected"]
        remaining = self.sql("SELECT email FROM users WHERE role='Administrator' AND active;")
        old_password = self.env["SBCO_ADMIN_PASSWORD"] if remaining == self.env["SBCO_ADMIN_EMAIL"] else password
        session = self.client(remaining, old_password)
        recovered = secrets.token_urlsafe(24)
        self.sql(f"INSERT INTO login_attempts VALUES('{remaining}',5,now()+interval '15 minutes') ON CONFLICT(email) DO UPDATE SET failures=5,blocked_until=excluded.blocked_until;")
        self.recover(remaining, recovered)
        session.call("me", expected=401)
        assert self.sql(f"SELECT count(*) FROM login_attempts WHERE email='{remaining}';") == "0"
        Client().call("login", {"email": remaining, "password": old_password}, expected=401)
        self.client(remaining, recovered)
        assert self.sql("SELECT count(*) FROM audit WHERE action='operator_admin_recovery';") == "1"
        self.env.update(SBCO_ADMIN_EMAIL=remaining, SBCO_ADMIN_PASSWORD=recovered)
        print("PASS last-administrator protection including concurrent demotions, all-session revocation, pool removal, reset/change passwords, CLI recovery and non-admin recovery refusal", flush=True)

    def imports(self):
        admin = self.client()
        content = template("LARGE-SO", 5000)
        encoded = base64.b64encode(content).decode()
        clients = [self.client() for _ in range(6)]
        def submit(client):
            return client.command("import", filename="SBCO_SO_Transactions_Template.xlsx", content_base64=encoded)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
            results = list(executor.map(submit, clients))
        first = results[0]["id"]
        assert len({r["id"] for r in results}) == 1
        assert self.sql("SELECT count(*) FROM imports;") == "1"
        assert self.sql("SELECT count(*) FROM jobs;") == "1"
        # Slow only this disposable database, guaranteeing a real committed partial import before killing the worker.
        self.sql("CREATE FUNCTION rehearsal_delay() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(0.002); RETURN NEW; END $$; CREATE TRIGGER rehearsal_delay BEFORE INSERT ON transactions FOR EACH ROW EXECUTE FUNCTION rehearsal_delay();")
        worker = self.start("sbco-worker")
        self.wait(lambda: int(self.sql(f"SELECT inserted FROM imports WHERE id='{first}';")) >= 100)
        worker.kill()
        worker.wait()
        partial = int(self.sql(f"SELECT inserted FROM imports WHERE id='{first}';"))
        assert 100 <= partial < 5000
        self.sql("DROP TRIGGER rehearsal_delay ON transactions; DROP FUNCTION rehearsal_delay();")
        self.start("sbco-worker")
        time.sleep(1)
        assert self.sql(f"SELECT attempts FROM jobs WHERE import_id='{first}';") == "1", "Worker stole an unexpired lease"
        self.sql(f"UPDATE jobs SET lease_until=now()-interval '1 second' WHERE import_id='{first}';")
        # A distinct file containing the same transaction rows races the resumed import.
        second = admin.command("import", filename="semantic-duplicate.xlsx", content_base64=base64.b64encode(template("LARGE-SO", 5000, "second")).decode())["id"]
        self.start("sbco-worker")
        def completed():
            batches = {r["id"]: r for r in admin.query("imports")}
            assert all(batches[i]["status"] != "Failed" for i in [first, second]), batches
            return batches if all(batches[i]["status"] == "Completed" for i in [first, second]) else None
        batches = self.wait(completed, timeout=180)
        assert self.sql("SELECT count(*) FROM transactions WHERE office_id='LARGE-SO';") == "5000"
        assert self.sql(f"SELECT attempts FROM jobs WHERE import_id='{first}';") == "2"
        assert sum(batches[i]["inserted"] for i in [first, second]) == 5000
        assert sum(batches[i]["duplicates"] for i in [first, second]) == 5000
        assert all(batches[i]["inserted"] + batches[i]["duplicates"] == 5000 for i in [first, second])
        report = admin.query("report", report="Transactions", filter={**FILTER, "office": "LARGE-SO"})
        assert report["totals"]["credit"] == "51250.00" and report["totals"]["total"] == 5000
        assert self.sql("SELECT count(*) FROM transactions WHERE account_number='000000000000' AND credit=10.25 AND source_row=6;") == "1"
        # Simulate the fifth abandoned attempt; retry must reset its exhausted lease.
        for process in self.processes[1:]:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        exhausted = admin.command("import", filename="retry.xlsx", content_base64=base64.b64encode(template("RETRY-SO", 10)).decode())["id"]
        self.sql(f"UPDATE jobs SET status='Processing',attempts=5,lease_id='{uuid.uuid4()}',lease_until=now()-interval '1 second' WHERE import_id='{exhausted}'; UPDATE imports SET status='Processing' WHERE id='{exhausted}';")
        self.start("sbco-worker")
        self.wait(lambda: self.sql(f"SELECT status FROM imports WHERE id='{exhausted}';") == "Failed")
        admin.command("retry_import", id=exhausted)
        self.wait(lambda: self.sql(f"SELECT status FROM imports WHERE id='{exhausted}';") == "Completed")
        assert self.sql(f"SELECT inserted FROM imports WHERE id='{exhausted}';") == "10"
        assert self.sql(f"SELECT attempts FROM jobs WHERE import_id='{exhausted}';") == "1"
        print(f"PASS 5,000-row delivered workbook, six simultaneous exact uploads, semantic duplicate race, worker kill after {partial} committed rows, lease expiry/reclaim, retry exhaustion/reset, exact aggregate and source lineage", flush=True)


if __name__ == "__main__":
    started = time.monotonic()
    Rehearsal().run()
    print(f"All isolated reliability scenarios passed in {time.monotonic() - started:.1f}s; disposable database removed.")
