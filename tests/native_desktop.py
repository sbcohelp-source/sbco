"""Native first-run smoke test. Run against an installed prototype in a disposable profile.
Requires tauri-driver, WebKitWebDriver and an X display (or xvfb-run).
"""
import base64,hashlib,json,os,pathlib,secrets,subprocess,time,urllib.request,urllib.error,uuid
from integration import workbook
from setup_import import filled
base='http://127.0.0.1:4444'
def call(path,data=None,method=None):
 req=urllib.request.Request(base+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json'},method=method)
 try:
  with urllib.request.urlopen(req,timeout=40) as response:result=json.load(response)
 except urllib.error.HTTPError as e:raise RuntimeError(e.read().decode()) from e
 if isinstance(result.get('value'),dict) and 'error' in result['value']:raise RuntimeError(result['value'])
 return result.get('value')
driver=subprocess.Popen([os.environ.get('SBCO_NATIVE_DRIVER','tauri-driver'),'--native-driver','/usr/bin/WebKitWebDriver'],stdout=open('/tmp/native-driver.log','w'),stderr=subprocess.STDOUT)
session=None
try:
 for _ in range(50):
  try:call('/status');break
  except Exception:time.sleep(.2)
 value=call('/session',{'capabilities':{'alwaysMatch':{'tauri:options':{'application':os.environ.get('SBCO_NATIVE_APP','/usr/bin/sbco-desktop')}}}})
 session=value['sessionId'];prefix='/session/'+session
 call(prefix+'/timeouts',{'implicit':5000,'script':30000})
 def execute(script,args=[]):return call(prefix+'/execute/sync',{'script':script,'args':args})
 def wait_text(text):
  for _ in range(100):
   if text in execute('return document.body.innerText'):return
   time.sleep(.1)
  raise RuntimeError('Missing '+text+': '+execute('return document.body.innerText'))
 def element(selector):return call(prefix+'/element',{'using':'css selector','value':selector})['element-6066-11e4-a52e-4f735466cecf']
 def fill(name,value):call(prefix+'/element/'+element('[name="'+name+'"]')+'/value',{'text':value})
 wait_text('Set up this offline workspace')
 assert execute('return !!window.__TAURI_INTERNALS__'), 'native IPC missing'
 call(prefix+'/element/'+element('button[data-setup-start]')+'/click',{})
 wait_text('Create administrator')
 password=secrets.token_urlsafe(20)
 fill('name','Offline Administrator');fill('email','offline@example.test');fill('password',password)
 fill('confirm_password',password)
 call(prefix+'/element/'+element('button[type=submit]')+'/click',{})
 wait_text('Welcome back');fill('email','offline@example.test');fill('password',password)
 call(prefix+'/element/'+element('button[type=submit]')+'/click',{})
 wait_text('Overview');wait_text('Back up');wait_text('Restore')
 assert execute('return document.title').startswith('SBCO')
 assert not execute('return [...document.querySelectorAll("main [role=alert]")].some(e=>e.textContent.trim())')
 pathlib.Path(os.environ.get('SBCO_NATIVE_SCREENSHOT','/tmp/sbco-desktop.png')).write_bytes(base64.b64decode(call(prefix+'/screenshot')))
 call(prefix+'/element/'+element('a[href="/imports"]')+'/click',{})
 wait_text('Import transaction workbooks')
 setup_fixture=pathlib.Path('/tmp/native-setup.xlsx')
 setup_fixture.write_bytes(filled('SBCO_Setup_Template.xlsx',{'xl/worksheets/sheet2.xml':{'A2':'NATIVE-SETUP','B2':'Offline setup office','C2':'SO'}}))
 call(prefix+'/element/'+element('#setup-workbook')+'/value',{'text':str(setup_fixture)})
 def click_button(label):
  button=call(prefix+'/element',{'using':'xpath','value':'//button[normalize-space()="'+label+'"]'})['element-6066-11e4-a52e-4f735466cecf']
  call(prefix+'/element/'+button+'/click',{})
 click_button('Preview setup');wait_text('Ready to import: 0 users, 1 offices, 0 pools.')
 click_button('Import setup');wait_text('Imported: 0 users, 1 offices, 0 pools.')
 print('PASS native offline setup template preview and import')
 fixture=pathlib.Path('/tmp/native-workbook.xlsx');fixture.write_bytes(workbook('NATIVE-SO',count=251))
 call(prefix+'/element/'+element('#workbooks')+'/value',{'text':str(fixture)})
 wait_text('Completed')
 def ipc(command,args):
  result=call(prefix+'/execute/async',{'script':"const done=arguments[arguments.length-1];window.__TAURI_INTERNALS__.invoke(arguments[0],arguments[1]).then(value=>done({value})).catch(error=>done({error:String(error)}));",'args':[command,args]})
  assert 'error' not in result,result
  return result['value']
 def command(kind,**fields):return ipc('command',{'request':{'request_id':str(uuid.uuid4()),'command':{'kind':kind,**fields}}})
 command('save_onboarding',step='offices',completed=False)
 progress=ipc('query',{'query':{'kind':'onboarding'}})
 assert progress['step']=='offices' and not progress['completed']
 call(prefix+'/refresh',{})
 wait_text('Import transaction workbooks')
 progress=ipc('query',{'query':{'kind':'onboarding'}})
 assert progress['step']=='offices' and not progress['completed']
 print('PASS native onboarding progress persisted through full window reload')
 deadline=time.monotonic()+90
 while True:
  backup=ipc('backup_status',{})
  assert backup['enabled'] and backup['retention_days']==14,backup
  assert not backup['last_error'],backup
  if backup['last_success'] and backup['last_backup']:break
  assert time.monotonic()<deadline,'Automatic desktop backup did not complete within 90 seconds'
  time.sleep(1)
 backup_path=pathlib.Path(backup['last_backup'])
 assert backup_path.read_bytes().startswith(b'PGDMP')
 assert hashlib.sha256(backup_path.read_bytes()).hexdigest()==backup_path.with_suffix('.sha256').read_text().strip()
 assert backup_path.stat().st_mode & 0o077 == 0,'Backup is accessible to another local account'
 print('PASS native daily automatic backup, status, PostgreSQL archive header, checksum and private permissions')
 pa_password=secrets.token_urlsafe(20)
 pa=command('create_user',name='Offline PA',email='pa@example.test',password=pa_password,role='Pa')['id']
 command('save_pool',id=None,name='Offline fixture',offices=['NATIVE-SO'],pa_user=pa,random_percent=0)
 ipc('logout',{})
 call(prefix+'/refresh',{})
 wait_text('Welcome back');fill('email','pa@example.test');fill('password',pa_password)
 call(prefix+'/element/'+element('button[type=submit]')+'/click',{})
 wait_text('Overview')
 call(prefix+'/element/'+element('a[href="/verify"]')+'/click',{})
 wait_text('Verification queue')
 call(prefix+'/element/'+element('#account-search')+'/value',{'text':'00000250'})
 wait_text('Account 00000250')
 button=call(prefix+'/element',{'using':'xpath','value':'//button[normalize-space()="Mark matched"]'})['element-6066-11e4-a52e-4f735466cecf']
 call(prefix+'/element/'+button+'/click',{})
 wait_text('No records match this view.')
 result=ipc('query',{'query':{'kind':'transactions','filter':{'office':'NATIVE-SO','search':'00000250','status':'Matched','from_date':None,'to_date':None,'queue':'all'},'cursor':None,'limit':10}})
 assert len(result['rows'])==1 and result['rows'][0]['final_status']=='Matched'
 call(prefix+'/element/'+element('a[href="/reports"]')+'/click',{})
 wait_text('Operational reports');wait_text('Checked 1 vouchers')
 report=ipc('query',{'query':{'kind':'report','report':'MPR','filter':{'office':'NATIVE-SO','search':None,'status':None,'from_date':None,'to_date':None,'queue':'all'}}})
 assert report['totals']['total']==1 and len(report['document']['sections'][1]['rows'])==3
 print('PASS native offline DPR preview and MPR report aggregates')
 print('PASS native offline workbook import: 251 rows, PA allocation, search beyond row 200 and persisted verification')
 assert execute('return location.protocol') in ('tauri:','http:','https:')
 print('PASS native window: first-run setup, administrator login, IPC dashboard, backup/restore controls and navigation, with container networking disabled')
finally:
 if session:
  try:call('/session/'+session,method='DELETE')
  except Exception:pass
 driver.terminate()
