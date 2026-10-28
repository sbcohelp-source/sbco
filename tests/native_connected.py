"""Native connected-client acceptance against an isolated HTTPS test API.

Requires a disposable /tmp profile, a trusted test CA inside the container only,
and SBCO_CONNECTED_ORIGIN / SBCO_CONNECTED_FIXTURE. No production API is used.
"""
import base64
import json
import os
import pathlib
import subprocess
import time
import uuid
from urllib.parse import urlsplit

from native_training import call
os.environ.setdefault("SBCO_NATIVE_RELEASE_STATE", "/tmp/connected-unused-state")
from native_release import NativeKeys
from integration import FILTER

assert os.environ.get("XDG_DATA_HOME", "").startswith("/tmp/")
origin = os.environ["SBCO_CONNECTED_ORIGIN"]
assert urlsplit(origin).hostname == "localhost", "Only the isolated local HTTPS test proxy is allowed"
credentials = json.loads(pathlib.Path(os.environ["SBCO_CONNECTED_FIXTURE"]).read_text())
driver = subprocess.Popen([os.environ["SBCO_NATIVE_DRIVER"], "--native-driver", "/usr/bin/WebKitWebDriver"], stdout=open("/tmp/native-connected-driver.log", "w"), stderr=subprocess.STDOUT)
session = None
try:
    for _ in range(100):
        try:
            call("/status")
            break
        except Exception:
            time.sleep(.1)
    def start():
        value = call("/session", {"capabilities": {"alwaysMatch": {"tauri:options": {"application": "/usr/bin/sbco-desktop"}}}})
        prefix = "/session/" + value["sessionId"]
        call(prefix + "/timeouts", {"implicit": 5000, "script": 60000})
        return value["sessionId"], prefix
    session, prefix = start()
    def execute(script, args=None):
        return call(prefix + "/execute/sync", {"script": script, "args": args or []})
    def wait_text(text):
        deadline = time.monotonic()+60
        while time.monotonic()<deadline:
            if text in execute("return document.body.innerText"):
                return
            time.sleep(.15)
        raise AssertionError("Missing "+text+": "+execute("return document.body.innerText"))
    def element(selector):
        return call(prefix+"/element", {"using":"css selector","value":selector})["element-6066-11e4-a52e-4f735466cecf"]
    def click(selector):
        call(prefix+"/element/"+element(selector)+"/click",{})
    def button(text):
        control=call(prefix+"/element",{"using":"xpath","value":'//button[normalize-space()="'+text+'"]'})["element-6066-11e4-a52e-4f735466cecf"]
        call(prefix+"/element/"+control+"/click",{})
    def fill(name,value):
        control=element('[name="'+name+'"]')
        call(prefix+"/element/"+control+"/clear",{})
        call(prefix+"/element/"+control+"/value",{"text":value})
    def ipc(command,args=None,error=False):
        result=call(prefix+"/execute/async",{"script":"const done=arguments[arguments.length-1];window.__TAURI_INTERNALS__.invoke(arguments[0],arguments[1]).then(value=>done({result:value})).catch(error=>done({failure:String(error)}));","args":[command,args or {}]})
        if error:
            assert "failure" in result,result
            return result["failure"]
        assert "failure" not in result,result
        return result["result"]
    wait_text("Connect to your SBCO server")
    assert not ipc("connection_status")["configured"]
    fill("server_url",origin.replace("localhost","127.0.0.1"))
    button("Connect to server")
    wait_text("Cannot securely reach the server")
    assert not ipc("connection_status")["configured"]
    fill("server_url",origin)
    button("Connect to server")
    wait_text("Welcome back")
    assert ipc("connection_status")["server_url"]==origin
    assert "Set up this offline workspace" not in execute("return document.body.innerText")
    fill("email",credentials["email"]);fill("password",credentials["password"])
    click("button[type=submit]")
    wait_text("Overview")
    assert "Back up" not in execute("return document.body.innerText")
    assert not ipc("backup_status")["enabled"]
    assert "server" in ipc("restore",error=True)
    click('a[href="/training"]');wait_text("Your training workspace");button("Enable training")
    wait_text("TRAINING MODE — practice data only")
    context=execute('return JSON.parse(sessionStorage.getItem("sbco.training.v1"))')
    assert ipc("me",{"training":context})["role"]=="Administrator"
    offices=ipc("query",{"query":{"kind":"offices"},"training":context})
    assert len(offices)==3
    result=ipc("command",{"request":{"request_id":str(uuid.uuid4()),"command":{"kind":"save_office","id":"NATIVE-HTTPS","name":"HTTPS training office","office_type":"SO","parent_id":None}},"training":context})
    assert len(ipc("query",{"query":{"kind":"offices"},"training":context}))==4
    keyboard=NativeKeys()
    for name,args,destination,signature in [
        ("save_template",{"name":"SBCO_Setup_Template","training":context},"/tmp/connected-template.xlsx",b"PK"),
        ("save_pdf",{"request":{"report":"Transactions","filter":FILTER,"letter_id":None},"training":context},"/tmp/connected-report.pdf",b"%PDF"),
    ]:
        execute("window.nativeSave=null;window.__TAURI_INTERNALS__.invoke(arguments[0],arguments[1]).then(()=>window.nativeSave='saved').catch(error=>window.nativeSave=String(error));",[name,args])
        time.sleep(2)
        keyboard.key("a",control=True);keyboard.text(destination);keyboard.key("Return")
        deadline=time.monotonic()+30
        while not pathlib.Path(destination).exists():
            assert time.monotonic()<deadline,execute("return window.nativeSave")
            time.sleep(.1)
        assert pathlib.Path(destination).read_bytes().startswith(signature)
        if name=="save_template":
            assert pathlib.Path(destination).read_bytes()==pathlib.Path("/work/apps/web/public/templates/SBCO_Setup_Template.xlsx").read_bytes()
    ipc("reset_training",{"generation":context["generation"],"confirmation":"DELETE TRAINING"})
    execute('sessionStorage.removeItem("sbco.training.v1")')
    call(prefix+"/refresh",{});wait_text("Overview")
    pathlib.Path("/evidence/connected-client.png").write_bytes(base64.b64decode(call(prefix+"/screenshot")))
    call("/session/"+session,method="DELETE");session=None
    session,prefix=start();wait_text("Welcome back")
    assert ipc("connection_status")["server_url"]==origin
    assert ipc("me",error=True)=="Sign in to continue"
    files=list(pathlib.Path(os.environ["XDG_DATA_HOME"]).rglob("server-connection.json"))
    assert len(files)==1
    persisted=json.loads(files[0].read_text())
    assert list(persisted)==["server_url"]
    assert not any(path.name in ["PG_VERSION","postgresql.conf","pg_hba.conf"] for path in pathlib.Path(os.environ["XDG_DATA_HOME"]).rglob("*"))
    print("PASS installed connected client: trusted HTTPS and certificate-name rejection, assigned login, remote training query/command/reset, native template/PDF downloads, server-only backups, URL persistence and forgotten session after restart, no local PostgreSQL",flush=True)
finally:
    if session:
        try:call("/session/"+session,method="DELETE")
        except Exception:pass
    driver.terminate();driver.wait(timeout=10)
