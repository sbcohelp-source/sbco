"""Real installed WebView2 first-run gate. Windows hosted fixture only; stdlib only."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request


class GuiFailure(RuntimeError):
    pass


def redact(text, sensitive):
    for value in sensitive:
        if value:
            text = text.replace(value, "[REDACTED]")
    return re.sub(r"postgres(?:ql)?://[^\s\"<>]+", "[REDACTED_DATABASE_URI]", text)[:3000]


def run(config, phase):
    if os.name != "nt" or os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise GuiFailure("GUI gate requires the disposable Windows hosted fixture")
    private = Path(config["private_root"])
    state_file = private / "account.json"
    if phase == "setup":
        if state_file.exists():
            raise GuiFailure("Account fixture already exists")
        account = {"email": "windows-gui@example.test", "password": secrets.token_urlsafe(28)}
        state_file.write_text(json.dumps(account), encoding="utf-8")
    else:
        account = json.loads(state_file.read_text(encoding="utf-8"))
    sensitive = [account["password"]]
    evidence = Path(config["evidence_root"])
    base = "http://127.0.0.1:" + str(config["port"])
    # No driver command logs: sendKeys bodies contain the generated test password.
    driver = subprocess.Popen([config["driver"], "--port=" + str(config["port"]), "--allowed-ips=127.0.0.1"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    session = None
    application = None
    application_streams = []
    stage = "driver startup"

    def call(path, data=None, method=None):
        request = urllib.request.Request(base + path, data=None if data is None else json.dumps(data).encode(),
                                         headers={"Content-Type": "application/json"}, method=method)
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                value = json.load(response).get("value")
        except urllib.error.HTTPError as error:
            # Never emit request bodies, raw HTML, filled form fields or passwords.
            try:
                failure = json.loads(error.read()).get("value", {})
                message = str(failure.get("error", "WebDriver HTTP error")) + ": " + str(failure.get("message", ""))
            except Exception:
                message = "WebDriver HTTP error " + str(error.code)
            raise GuiFailure(redact(message, sensitive)) from None
        if isinstance(value, dict) and "error" in value:
            raise GuiFailure(redact(str(value.get("error")) + ": " + str(value.get("message", "")), sensitive))
        return value

    def execute(script, args=None):
        return call("/session/" + session + "/execute/sync", {"script": script, "args": args or []})

    def wait(condition, description, timeout=90):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            if application is not None and application.poll() is not None:
                raise GuiFailure("Installed application exited with code " + str(application.returncode))
            if condition():
                return
            time.sleep(.2)
        raise GuiFailure("Timed out waiting for " + description)

    def text_present(text):
        return execute("return document.body.innerText.includes(arguments[0])", [text])

    def element(selector):
        return call("/session/" + session + "/element", {"using": "css selector", "value": selector})["element-6066-11e4-a52e-4f735466cecf"]

    def click(selector):
        call("/session/" + session + "/element/" + element(selector) + "/click", {})

    def fill(selector, value):
        control = element(selector)
        call("/session/" + session + "/element/" + control + "/clear", {})
        call("/session/" + session + "/element/" + control + "/value", {"text": value})

    def screenshot(name):
        # Capture only screens with no password controls, even if the value is masked.
        if execute("return !!document.querySelector('input[type=password]')"):
            raise GuiFailure("Refusing screenshot of credential-entry screen")
        content = base64.b64decode(call("/session/" + session + "/screenshot"), validate=True)
        (evidence / name).write_bytes(content)

    try:
        until = time.monotonic() + 30
        while True:
            if driver.poll() is not None:
                raise GuiFailure("Edge driver exited before accepting a session")
            try:
                if call("/status").get("ready"):
                    break
            except (OSError, GuiFailure):
                pass
            if time.monotonic() >= until:
                raise GuiFailure("Edge driver did not become ready")
            time.sleep(.2)
        stage = "supervised installed application startup"
        # The elevated hosted fixture installs documented, exact-app HKLM
        # WebView2 overrides and removes them after this owned application stops.
        # Environment overrides are intentionally absent: WebView2 ignores them
        # for elevated hosts. This does not qualify ordinary-user/Windows10/11 use.
        debug_port = config["debug_port"]
        application_streams = [open(private / (phase + "-application." + stream), "wb")
                               for stream in ("stdout", "stderr")]
        application = subprocess.Popen([config["application"]],
                                       stdin=subprocess.DEVNULL, stdout=application_streams[0],
                                       stderr=application_streams[1])
        launched_at = time.monotonic()
        (evidence / (phase + "-launch.json")).write_text(json.dumps({
            "application_pid": application.pid, "debug_port": debug_port,
            "debug_configuration": "temporary exact-app HKLM policy", "elevated_host": True,
            "ordinary_user_qualified": False,
        }, indent=2), encoding="utf-8")

        def debugger_ready():
            try:
                with urllib.request.urlopen("http://127.0.0.1:" + str(debug_port) + "/json/version", timeout=2) as response:
                    version = json.load(response)
                return bool(version.get("webSocketDebuggerUrl")) and application.poll() is None
            except (OSError, ValueError):
                return False

        wait(debugger_ready, "installed WebView2 debugging endpoint", timeout=120)
        (evidence / (phase + "-startup.json")).write_text(json.dumps({
            "debug_endpoint_ready": True, "application_alive": application.poll() is None,
            "elapsed_seconds": round(time.monotonic() - launched_at, 2),
            "credentials_entered": False, "debug_bind": "127.0.0.1",
        }, indent=2), encoding="utf-8")
        # The supervisor verifies the actual listener PID/creation/path belongs
        # to our recorded child tree and that every listener is loopback-only.
        request_file = private / (phase + "-debug-request.json")
        request_temp = request_file.with_suffix(".tmp")
        request_temp.write_text(json.dumps({"application_pid": application.pid, "port": debug_port}), encoding="utf-8")
        request_temp.replace(request_file)
        wait(lambda: (private / (phase + "-debug-verified")).read_text(encoding="utf-8") == "verified"
             if (private / (phase + "-debug-verified")).exists() else False,
             "supervisor debugging listener ownership verification", timeout=30)
        stage = "attach to installed WebView2"
        result = call("/session", {"capabilities": {"alwaysMatch": {
            "browserName": "webview2", "ms:edgeChromium": True,
            "ms:edgeOptions": {"debuggerAddress": "127.0.0.1:" + str(debug_port)},
        }}})
        session = result["sessionId"]
        observed_version = result["capabilities"].get("browserVersion", "")
        if observed_version.split(".")[:3] != config["runtime_version"].split(".")[:3]:
            raise GuiFailure("Session WebView2 version differs from the verified runtime/driver")
        call("/session/" + session + "/timeouts", {"implicit": 5000, "script": 30000})
        execute("""window.guiErrors=[];
        addEventListener('error',e=>window.guiErrors.push(String(e.message)));
        addEventListener('unhandledrejection',e=>window.guiErrors.push(String(e.reason)));
        const previous=console.error;console.error=function(...args){window.guiErrors.push(args.map(String).join(' '));previous.apply(console,args)};""")
        if not execute("return !!window.__TAURI_INTERNALS__"):
            raise GuiFailure("Installed window is missing native Tauri IPC")
        if phase == "setup":
            stage = "visible first-run welcome"
            wait(lambda: text_present("Set up this offline workspace"), stage)
            click("button[data-setup-start]")
            wait(lambda: text_present("Create administrator"), "administrator form")
            stage = "visible administrator creation"
            fill('[name="name"]', "Windows GUI Administrator")
            fill('[name="email"]', account["email"])
            fill('[name="password"]', account["password"])
            fill('[name="confirm_password"]', account["password"])
            click('button[type="submit"]')
        stage = "sign-in screen after " + phase
        wait(lambda: text_present("Welcome back"), stage)
        if text_present("Set up this offline workspace"):
            raise GuiFailure("First-run setup unexpectedly remained after account persistence")
        stage = "visible sign-in"
        fill('[name="email"]', account["email"])
        fill('[name="password"]', account["password"])
        click('button[type="submit"]')
        wait(lambda: text_present("Overview"), "authenticated Overview")
        # Ensure sign-in completed before recording evidence or navigating.
        wait(lambda: execute("return !document.querySelector('input[type=password]')"), "credential form removal")
        stage = "Overview checks"
        if not execute("return document.title.startsWith('SBCO') && document.body.innerText.length>150"):
            raise GuiFailure("Page identity or nonblank check failed")
        if execute("return !!document.querySelector('nextjs-portal')"):
            raise GuiFailure("Framework error overlay found")
        if not text_present("Windows GUI Administrator"):
            raise GuiFailure("Expected administrator account is not visible")
        screenshot(phase + "-overview.png")
        stage = "Help navigation and search"
        click('a[href="/help"]')
        wait(lambda: text_present("How can we help?"), "Help screen")
        fill('input[placeholder="Try imports, passwords or training"]', "author")
        wait(lambda: text_present("Author: S K Singh") and text_present("sbcohelp@gmail.com"), "bundled support topic")
        if not execute("return !!document.querySelector('a[href=\"mailto:sbcohelp@gmail.com\"]')"):
            raise GuiFailure("Support contact link is missing")
        errors = execute("return window.guiErrors || []")
        if errors:
            raise GuiFailure("Attached-window runtime errors: " + redact("; ".join(map(str, errors)), sensitive))
        screenshot(phase + "-help.png")
        (evidence / (phase + "-result.json")).write_text(json.dumps({
            "result": "passed", "phase": phase, "native_ipc": True, "visible_sign_in": True,
            "overview": True, "help_search": True, "runtime_version": observed_version,
            "account_persisted_after_restart": phase == "reopen", "console_error_capture": "after WebDriver attachment",
            "native_dialogs_tested": False, "windows_10_11_qualified": False, "ordinary_user_qualified": False,
        }, indent=2), encoding="utf-8")
        print("PASS installed standalone GUI " + phase + ": visible sign-in, Overview, Help and screenshots", flush=True)
    except Exception as error:
        (evidence / (phase + "-failure.json")).write_text(json.dumps({
            "stage": stage, "type": type(error).__name__, "message": redact(str(error), sensitive),
            "application_exit_code": None if application is None else application.poll(),
        }, indent=2), encoding="utf-8")
        # No failure screenshot or page source on account/setup/sign-in screens.
        raise GuiFailure("Installed GUI failed at " + stage + "; inspect sanitized failure evidence") from None
    finally:
        # The PowerShell supervisor closes the exact owned application/PG tree;
        # do not kill a healthy database process from this UI harness.
        for stream in application_streams:
            stream.close()
        if session:
            try:
                call("/session/" + session, method="DELETE")
            except Exception:
                pass
        if driver.poll() is None:
            driver.terminate()
            try:
                driver.wait(timeout=10)
            except subprocess.TimeoutExpired:
                driver.kill()
                driver.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    parser.add_argument("--phase", choices=("setup", "reopen"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        assert redact("secret-value and postgresql://u:p@localhost/db", ["secret-value"]) == "[REDACTED] and [REDACTED_DATABASE_URI]"
        assert "secret-value" not in redact("secret-value" * 1000, ["secret-value"])
        print("PASS GUI evidence redaction; Python stdlib harness imports without launching drivers")
        return
    if not args.config or not args.phase:
        parser.error("--config and --phase are required")
    config = json.loads(Path(args.config).read_text(encoding="utf-8-sig"))
    run(config, args.phase)


if __name__ == "__main__":
    try:
        main()
    except GuiFailure as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
