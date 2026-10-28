"""Installed native training lifecycle, in a disposable offline profile only.

Run under xvfb with tauri-driver and the current .deb installed. Never point
XDG_DATA_HOME at a real application profile. No external API is used.
"""
import base64
import json
import os
import pathlib
import secrets
import subprocess
import time
import urllib.error
import urllib.request
import uuid

from integration import FILTER, workbook

assert os.environ.get("XDG_DATA_HOME", "").startswith("/tmp/"), "Disposable profile required"
BASE = "http://127.0.0.1:4444"


def call(path, data=None, method=None):
    request = urllib.request.Request(BASE + path, data=None if data is None else json.dumps(data).encode(),
                                     headers={"Content-Type": "application/json"}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(error.read().decode()) from error
    value = result.get("value")
    if isinstance(value, dict) and "error" in value:
        raise RuntimeError(value)
    return value


def run():
    driver = subprocess.Popen([os.environ.get("SBCO_NATIVE_DRIVER", "tauri-driver"), "--native-driver", "/usr/bin/WebKitWebDriver"],
                              stdout=open("/tmp/native-training-driver.log", "w"), stderr=subprocess.STDOUT)
    session = None
    try:
        for _ in range(100):
            try:
                call("/status")
                break
            except Exception:
                time.sleep(0.1)
        session = call("/session", {"capabilities": {"alwaysMatch": {"tauri:options": {"application": "/usr/bin/sbco-desktop"}}}})["sessionId"]
        prefix = "/session/" + session
        call(prefix + "/timeouts", {"implicit": 5000, "script": 60000})

        def execute(script, args=None):
            return call(prefix + "/execute/sync", {"script": script, "args": args or []})

        def wait_text(text):
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if text in execute("return document.body.innerText"):
                    return
                time.sleep(0.15)
            raise AssertionError("Missing " + text + ": " + execute("return document.body.innerText"))

        def element(selector):
            return call(prefix + "/element", {"using": "css selector", "value": selector})["element-6066-11e4-a52e-4f735466cecf"]

        def click(selector):
            call(prefix + "/element/" + element(selector) + "/click", {})

        def button(label):
            found = call(prefix + "/element", {"using": "xpath", "value": '//button[normalize-space()="' + label + '"]'})["element-6066-11e4-a52e-4f735466cecf"]
            call(prefix + "/element/" + found + "/click", {})

        def fill(name, value):
            call(prefix + "/element/" + element('[name="' + name + '"]') + "/value", {"text": value})

        def ipc(name, args=None, error=False):
            result = call(prefix + "/execute/async", {"script": "const done=arguments[arguments.length-1];window.__TAURI_INTERNALS__.invoke(arguments[0],arguments[1]).then(value=>done({result:value})).catch(error=>done({failure:String(error)}));", "args": [name, args or {}]})
            if error:
                assert "failure" in result, result
                return result["failure"]
            assert "failure" not in result, result
            return result["result"]

        def query(kind, context=None, **fields):
            return ipc("query", {"query": {"kind": kind, **fields}, "training": context})

        def command(kind, context=None, **fields):
            return ipc("command", {"request": {"request_id": str(uuid.uuid4()), "command": {"kind": kind, **fields}}, "training": context})

        wait_text("Set up this offline workspace")
        click("button[data-setup-start]")
        wait_text("Create administrator")
        password = secrets.token_urlsafe(20)
        for name, value in {"name": "Native training owner", "email": "native-training@example.test", "password": password, "confirm_password": password}.items():
            fill(name, value)
        click("button[type=submit]")
        wait_text("Welcome back")
        fill("email", "native-training@example.test")
        fill("password", password)
        click("button[type=submit]")
        wait_text("Overview")
        live_actor = ipc("me")
        command("save_office", id="LIVE-NATIVE", name="Real office marker", office_type="SO", parent_id=None)
        before = {kind: query(kind) for kind in ["offices", "users", "pools", "imports", "settings"]}
        click('a[href="/training"]')
        wait_text("Your training workspace")
        button("Enable training")
        wait_text("TRAINING MODE — practice data only")
        wait_text("Practice role: Administrator")
        context = execute('return JSON.parse(sessionStorage.getItem("sbco.training.v1"))')
        assert context["role"] == "Administrator"
        status = ipc("training_status")
        assert status["available"] and status["counts"]["transactions"] == 24, status
        assert query("offices", context) != before["offices"]
        print("PASS native enable: synthetic workspace, distinct live data, training banner", flush=True)
        command("save_office", context, id="PRACTICE-NATIVE", name="New practice office", office_type="SO", parent_id=None)
        command("create_user", context, name="New practice user", email="practice-native@example.test", password=secrets.token_urlsafe(20), role="Pa")
        command("save_pool", context, id=None, name="New practice pool", offices=["PRACTICE-NATIVE"], pa_user=None, random_percent=0)
        command("save_settings", context, **{**before["settings"], "signatory": "Practice-only marker"})
        content = base64.b64encode(workbook("PRACTICE-IMPORT", count=251)).decode()
        command("import", context, filename="native-training.xlsx", content_base64=content)
        deadline = time.monotonic() + 60
        while True:
            imports = query("imports", context)
            if any(row["filename"] == "native-training.xlsx" and row["status"] == "Completed" and row["inserted"] == 251 for row in imports):
                break
            assert time.monotonic() < deadline, imports
            time.sleep(0.3)
        assert query("settings", context)["signatory"] == "Practice-only marker"
        call(prefix + "/refresh", {})
        wait_text("TRAINING MODE — practice data only")
        assert ipc("me", {"training": context})["role"] == "Administrator"
        assert query("settings", context)["signatory"] == "Practice-only marker"
        print("PASS native training-created records, 251-row background import and reload persistence", flush=True)
        for role, label in [("Pa", "Postal Assistant"), ("Supervisor", "Supervisor"), ("Administrator", "Administrator")]:
            element("select")
            execute('const select=document.querySelector("select"); select.value=arguments[0]; select.dispatchEvent(new Event("change",{bubbles:true}));', [role])
            wait_text("Practice role: " + label)
            context = execute('return JSON.parse(sessionStorage.getItem("sbco.training.v1"))')
            assert ipc("me", {"training": context})["role"] == role
        for name in ["backup", "backup_status", "restore"]:
            assert "Leave training mode" in ipc(name, {"training": context}, error=True)
        print("PASS native three practice roles and backup/restore isolation", flush=True)
        button("Disable training and return to live")
        wait_text("LIVE workspace active")
        assert ipc("me") == live_actor
        assert {kind: query(kind) for kind in before} == before
        button("Resume training")
        wait_text("TRAINING MODE — practice data only")
        assert execute('return JSON.parse(sessionStorage.getItem("sbco.training.v1")).generation') == context["generation"]
        button("Review training deletion")
        wait_text("Type DELETE TRAINING to confirm")
        confirm = element('section[aria-label="Confirm training deletion"] input')
        call(prefix + "/element/" + confirm + "/value", {"text": "DELETE TRAINING"})
        button("Delete all my training data")
        wait_text("LIVE workspace active")
        assert ipc("training_status")["available"] is False
        assert {kind: query(kind) for kind in before} == before
        assert ipc("me") == live_actor
        assert "reset" in ipc("query", {"query": {"kind": "offices"}, "training": context}, error=True).lower()
        assert "reset" in ipc("save_pdf", {"request": {"report": "DPR", "filter": FILTER, "letter_id": None}, "training": context}, error=True).lower()
        actions = [entry["action"] for entry in query("audit")]
        assert "EnableTraining" in actions and "ResetTraining" in actions
        click('a[href="/help"]')
        wait_text("Author: S K Singh")
        wait_text("sbcohelp@gmail.com")
        assert execute("return !!document.querySelector('a[href=\"mailto:sbcohelp@gmail.com\"]')")
        print("PASS native offline Help author and contact details", flush=True)
        pathlib.Path(os.environ.get("SBCO_NATIVE_TRAINING_SCREENSHOT", "/tmp/sbco-native-training.png")).write_bytes(base64.b64decode(call(prefix + "/screenshot")))
        print("PASS native disable/resume, confirmed reset, stale query/export rejection and unchanged live records", flush=True)
        assert not execute('return [...document.querySelectorAll("main [role=alert]")].some(e=>e.textContent.trim())')
    finally:
        if session:
            try:
                call("/session/" + session, method="DELETE")
            except Exception:
                pass
        driver.terminate()
        driver.wait(timeout=10)


if __name__ == "__main__":
    run()
