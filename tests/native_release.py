"""Native Save-dialog and same-version reinstall acceptance, in a disposable profile.

Run `prepare`, close the application, reinstall the same .deb, then run `verify`
under the same XDG_DATA_HOME and with SBCO_NATIVE_RELEASE_STATE pointing at the
same private temporary JSON file. Requires xvfb, WebKitWebDriver and tauri-driver.
No host application profile should be used for this destructive test setup.
"""
import base64
import ctypes
import hashlib
import json
import os
import pathlib
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

from integration import FILTER, workbook
from setup_import import TEMPLATES

BASE = "http://127.0.0.1:4444"
STATE = pathlib.Path(os.environ["SBCO_NATIVE_RELEASE_STATE"])
assert str(STATE).startswith("/tmp/"), "Use a disposable /tmp state file"
assert os.environ.get("XDG_DATA_HOME", "").startswith("/tmp/"), "Use a disposable /tmp application profile"


def call(path, data=None, method=None):
    request = urllib.request.Request(BASE + path, data=None if data is None else json.dumps(data).encode(),
                                     headers={"Content-Type": "application/json"}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(error.read().decode()) from error
    if isinstance(result.get("value"), dict) and "error" in result["value"]:
        raise RuntimeError(result["value"])
    return result.get("value")


class NativeKeys:
    """Send keyboard input to the genuine GTK dialog on the isolated X display."""
    def __init__(self):
        self.x = ctypes.CDLL("libX11.so.6")
        self.test = ctypes.CDLL("libXtst.so.6")
        self.x.XOpenDisplay.restype = ctypes.c_void_p
        self.display = self.x.XOpenDisplay(None)
        assert self.display
        self.x.XStringToKeysym.argtypes = [ctypes.c_char_p]
        self.x.XStringToKeysym.restype = ctypes.c_ulong
        self.x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x.XKeysymToKeycode.restype = ctypes.c_uint
        self.x.XFlush.argtypes = [ctypes.c_void_p]
        self.test.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]

    def event(self, key, down):
        symbol = self.x.XStringToKeysym(key.encode())
        code = self.x.XKeysymToKeycode(self.display, symbol)
        assert code, key
        self.test.XTestFakeKeyEvent(self.display, code, int(down), 0)
        self.x.XFlush(self.display)

    def key(self, key, control=False):
        if control:
            self.event("Control_L", True)
        self.event(key, True)
        self.event(key, False)
        if control:
            self.event("Control_L", False)
        time.sleep(0.04)

    def text(self, value):
        names = {"/": "slash", ".": "period", "-": "minus"}
        for char in value:
            assert char.islower() or char.isdigit() or char in names, "Keep test paths lowercase"
            self.key(names.get(char, char))

    def screenshot(self, path):
        gtk = ctypes.CDLL("libgtk-3.so.0")
        gdk = ctypes.CDLL("libgdk-3.so.0")
        pixbuf = ctypes.CDLL("libgdk_pixbuf-2.0.so.0")
        gtk.gtk_init_check(None, None)
        gdk.gdk_get_default_root_window.restype = ctypes.c_void_p
        window = gdk.gdk_get_default_root_window()
        gdk.gdk_window_get_width.argtypes = [ctypes.c_void_p]
        gdk.gdk_window_get_height.argtypes = [ctypes.c_void_p]
        gdk.gdk_pixbuf_get_from_window.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        gdk.gdk_pixbuf_get_from_window.restype = ctypes.c_void_p
        bitmap = gdk.gdk_pixbuf_get_from_window(window, 0, 0, gdk.gdk_window_get_width(window), gdk.gdk_window_get_height(window))
        pixbuf.gdk_pixbuf_savev.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        assert pixbuf.gdk_pixbuf_savev(bitmap, str(path).encode(), b"png", None, None, None)


def run(phase):
    driver = subprocess.Popen([os.environ.get("SBCO_NATIVE_DRIVER", "tauri-driver"), "--native-driver", "/usr/bin/WebKitWebDriver"],
                              stdout=open("/tmp/native-release-driver.log", "w"), stderr=subprocess.STDOUT)
    session = None
    try:
        for _ in range(100):
            try:
                call("/status")
                break
            except Exception:
                time.sleep(0.1)
        value = call("/session", {"capabilities": {"alwaysMatch": {"tauri:options": {"application": "/usr/bin/sbco-desktop"}}}})
        session = value["sessionId"]
        prefix = "/session/" + session
        call(prefix + "/timeouts", {"implicit": 5000, "script": 30000})

        def execute(script, args=None):
            return call(prefix + "/execute/sync", {"script": script, "args": args or []})

        def wait_text(text):
            for _ in range(120):
                if text in execute("return document.body.innerText"):
                    return
                time.sleep(0.1)
            raise AssertionError("Missing " + text + ": " + execute("return document.body.innerText"))

        def element(selector):
            return call(prefix + "/element", {"using": "css selector", "value": selector})["element-6066-11e4-a52e-4f735466cecf"]

        def click(selector):
            call(prefix + "/element/" + element(selector) + "/click", {})

        def fill(name, value):
            call(prefix + "/element/" + element(f'[name="{name}"]') + "/value", {"text": value})

        def ipc(command, arguments):
            result = call(prefix + "/execute/async", {"script": "const done=arguments[arguments.length-1]; window.__TAURI_INTERNALS__.invoke(arguments[0],arguments[1]).then(value=>done({value})).catch(error=>done({error:String(error)}));", "args": [command, arguments]})
            assert "error" not in result, result
            return result["value"]

        if phase == "prepare":
            wait_text("Set up this offline workspace")
            click("button[data-setup-start]")
            wait_text("Create administrator")
            state = {"email": "release@example.test", "password": secrets.token_urlsafe(20)}
            STATE.write_text(json.dumps(state))
            STATE.chmod(0o600)
            fill("name", "Reinstall administrator")
            fill("email", state["email"])
            fill("password", state["password"])
            fill("confirm_password", state["password"])
            click("button[type=submit]")
        else:
            state = json.loads(STATE.read_text())
        wait_text("Welcome back")
        fill("email", state["email"])
        fill("password", state["password"])
        click("button[type=submit]")
        wait_text("Overview")
        assert execute("return document.title").startswith("SBCO")
        assert execute("return !!window.__TAURI_INTERNALS__")
        if phase == "prepare":
            click('a[href="/imports"]')
            wait_text("Import templates")
            keyboard = NativeKeys()
            for short, filename in [("setup", "SBCO_Setup_Template.xlsx"), ("so", "SBCO_SO_Transactions_Template.xlsx"), ("bo", "SBCO_BO_Transactions_Template.xlsx")]:
                destination = pathlib.Path(f"/tmp/sbco-saved-{short}.xlsx")
                assert not destination.exists()
                click(f'a[href="/templates/{filename}"]')
                time.sleep(0.8)
                keyboard.screenshot(pathlib.Path(os.environ.get("SBCO_NATIVE_EVIDENCE", "/tmp")) / f"sbco-save-dialog-{short}.png")
                keyboard.key("a", control=True)
                keyboard.text(str(destination))
                keyboard.key("Return")
                for _ in range(50):
                    if destination.exists():
                        break
                    time.sleep(0.1)
                assert destination.exists(), "Native Save dialog did not save " + short
                assert destination.read_bytes() == (TEMPLATES / filename).read_bytes(), "Saved template differs from shipped bytes"
                print(f"PASS native {short} Save dialog: saved file SHA-256 {hashlib.sha256(destination.read_bytes()).hexdigest()}", flush=True)
            fixture = pathlib.Path("/tmp/native-release-workbook.xlsx")
            fixture.write_bytes(workbook("REINSTALL-SO", count=2))
            call(prefix + "/element/" + element("#workbooks") + "/value", {"text": str(fixture)})
            wait_text("Completed")
            ipc("command", {"request": {"request_id": str(uuid.uuid4()), "command": {"kind": "save_settings", **ipc("query", {"query": {"kind": "settings"}}), "signatory": "Reinstall preservation marker"}}})
            ipc("command", {"request": {"request_id": str(uuid.uuid4()), "command": {"kind": "save_onboarding", "step": "team", "completed": False}}})
            assert ipc("query", {"query": {"kind": "onboarding"}})["step"] == "team"
            deadline = time.monotonic() + 90
            while True:
                backup = ipc("backup_status", {})
                assert not backup["last_error"], backup
                if backup["last_backup"]:
                    break
                assert time.monotonic() < deadline, "Scheduled backup did not complete"
                time.sleep(1)
            state["backup_path"] = backup["last_backup"]
            state["backup_hash"] = hashlib.sha256(pathlib.Path(backup["last_backup"]).read_bytes()).hexdigest()
            STATE.write_text(json.dumps(state))
            print("PASS created administrator, two transactions, persistent settings, onboarding progress and daily backup before reinstall", flush=True)
        else:
            records = ipc("query", {"query": {"kind": "transactions", "filter": {**FILTER, "office": "REINSTALL-SO"}, "cursor": None, "limit": 10}})
            assert len(records["rows"]) == 2
            assert ipc("query", {"query": {"kind": "settings"}})["signatory"] == "Reinstall preservation marker"
            assert len(ipc("query", {"query": {"kind": "users"}})) == 1
            assert any(i["status"] == "Completed" and i["inserted"] == 2 for i in ipc("query", {"query": {"kind": "imports"}}))
            progress = ipc("query", {"query": {"kind": "onboarding"}})
            assert progress["step"] == "team" and not progress["completed"], progress
            assert hashlib.sha256(pathlib.Path(state["backup_path"]).read_bytes()).hexdigest() == state["backup_hash"]
            print("PASS same-version installer reinstall: original administrator login, transactions, import history, settings, onboarding progress and daily backup preserved", flush=True)
        assert not execute('return [...document.querySelectorAll("main [role=alert]")].some(e=>e.textContent.trim())')
        pathlib.Path(os.environ.get("SBCO_NATIVE_EVIDENCE", "/tmp"), f"sbco-native-release-{phase}.png").write_bytes(base64.b64decode(call(prefix + "/screenshot")))
    finally:
        if session:
            try:
                call("/session/" + session, method="DELETE")
            except Exception:
                pass
        driver.terminate()
        driver.wait(timeout=10)


if __name__ == "__main__":
    assert sys.argv[1] in ("prepare", "verify")
    run(sys.argv[1])
