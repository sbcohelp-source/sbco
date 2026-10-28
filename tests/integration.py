"""Real HTTP/PostgreSQL integration suite. Uses unique fixture offices, never deletes data."""
import base64, concurrent.futures, http.cookiejar, io, json, os, pathlib, secrets, time, urllib.error, urllib.request, uuid, zipfile
from xml.sax.saxutils import escape
BASE=os.environ.get('SBCO_TEST_API','http://127.0.0.1:8091')+'/api/v1/'
class Client:
 def __init__(self): self.opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
 def call(self,path,data=None,expected=200):
  req=urllib.request.Request(BASE+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json','X-SBCO-Request':'1'})
  try:
   response=self.opener.open(req,timeout=30);body=response.read();status=response.status
  except urllib.error.HTTPError as e: status=e.code;body=e.read()
  assert status==expected,(path,status,body[:500])
  return body if body.startswith(b'%PDF') else json.loads(body)
 def command(self,kind,request_id=None,expected=200,**values):return self.call('command',{'request_id':request_id or str(uuid.uuid4()),'command':{'kind':kind,**values}},expected)
 def query(self,kind,**values):return self.call('query',{'kind':kind,**values})
 def login(self,email,password):return self.call('login',{'email':email,'password':password})
FILTER={'office':None,'status':None,'search':None,'from_date':None,'to_date':None,'queue':'all'}
def workbook(office,count=251,duplicate=False,branch=None):
 rows=[['SOL ID',office,'Fixture SO'],['Date','2026-10-01'],['Sl No','Account Number','Scheme Code','Tran Id','Value Date','Credit','Cash','Debit','Cash'],['','','','','','','','','']]
 for i in range(count):rows.append([i+1,f'{i:08}','SB',f'TXN-{i}','2026-10-01',0,100000 if i==0 else 10.25,0,0])
 if duplicate:rows.append([count+1,*rows[-1][1:]])
 if branch:
  for row in rows[4:]:row[5]=10.25;row[6]=0
  rows.insert(1,['BO ID',branch,'Fixture BO'])
 def col(n):
  s=''
  while n:n,r=divmod(n-1,26);s=chr(65+r)+s
  return s
 sheet='<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
 for r,row in enumerate(rows,1):
  sheet+=f'<row r="{r}">'
  for c,v in enumerate(row,1):
   ref=f'{col(c)}{r}'
   sheet+=(f'<c r="{ref}"><v>{v}</v></c>' if isinstance(v,(int,float)) else f'<c r="{ref}" t="inlineStr"><is><t>{escape(v)}</t></is></c>')
  sheet+='</row>'
 sheet+='</sheetData></worksheet>'
 buffer=io.BytesIO()
 with zipfile.ZipFile(buffer,'w',zipfile.ZIP_DEFLATED) as z:
  z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>')
  z.writestr('_rels/.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
  z.writestr('xl/workbook.xml','<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Long Book" sheetId="1" r:id="rId1"/></sheets></workbook>')
  z.writestr('xl/_rels/workbook.xml.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>')
  z.writestr('xl/worksheets/sheet1.xml',sheet)
 return buffer.getvalue()
def run():
 admin=Client();admin.login(os.environ['SBCO_ADMIN_EMAIL'],os.environ['SBCO_ADMIN_PASSWORD']);tag=uuid.uuid4().hex[:8];office='TEST-'+tag;pw=secrets.token_urlsafe(24)
 pa_id=admin.command('create_user',name='Test PA',email=f'pa-{tag}@example.test',password=pw,role='Pa')['id']
 other_id=admin.command('create_user',name='Unassigned PA',email=f'other-{tag}@example.test',password=pw,role='Pa')['id']
 pa=Client();pa.login(f'pa-{tag}@example.test',pw);other=Client();other.login(f'other-{tag}@example.test',pw)
 admin.command('save_office',id=office,name='Fixture SO',office_type='SO',parent_id=None)
 admin.command('save_pool',id=None,name='Fixture '+tag,offices=[office],pa_user=pa_id,random_percent=0)
 content=workbook(office,duplicate=True);filename='fixture-'+tag+'.xlsx'
 imp=admin.command('import',filename=filename,content_base64=base64.b64encode(content).decode())['id']
 assert admin.command('import',filename=filename,content_base64=base64.b64encode(content).decode())['duplicate']
 for _ in range(120):
  batch=next(r for r in admin.query('imports') if r['id']==imp)
  if batch['status'] in ('Completed','Failed'):break
  time.sleep(.5)
 assert batch['status']=='Completed',batch
 assert batch['inserted']==251 and batch['duplicates']==1,batch
 print('PASS workbook parsing, source lineage, exact and semantic duplicates')
 f={**FILTER,'office':office};rows=[];cursor=None
 while True:
  page=pa.query('transactions',filter=f,cursor=cursor,limit=50);rows+=page['rows'];cursor=page['next_cursor']
  if not cursor:break
 assert len(rows)==251 and len({r['id'] for r in rows})==251
 assert pa.query('transactions',filter={**f,'search':'00000250'},cursor=None,limit=50)['rows'][0]['account_number']=='00000250'
 assert not other.query('transactions',filter=f,cursor=None,limit=50)['rows']
 other.command('verify',expected=403,id=rows[1]['id'],revision=1,status='Matched',reason='',notes='')
 admin.command('verify',expected=403,id=rows[1]['id'],revision=1,status='Matched',reason='',notes='')
 print('PASS pagination beyond 200 rows and office/role isolation')
 rid=str(uuid.uuid4());command=dict(id=rows[1]['id'],revision=1,status='Matched',reason='',notes='Checked')
 first=pa.command('verify',request_id=rid,**command);assert first==pa.command('verify',request_id=rid,**command)
 pa.command('verify',expected=409,**command)
 pa.command('verify',expected=400,id=rows[2]['id'],revision=1,status='Mismatch',reason='',notes='')
 pa.command('verify',id=rows[0]['id'],revision=1,status='Mismatch',reason='Voucher missing',notes='Missing')
 review=next(r for r in admin.query('reviews') if r['transaction_id']==rows[0]['id']);assert review['basis']=='High Value'
 admin.command('reverify',expected=400,id=review['id'],revision=1,status='Matched',reason='',notes='')
 admin.command('reverify',id=review['id'],revision=1,status='Mismatch',reason='Voucher missing',notes='Confirmed')
 print('PASS decisions, idempotency, high-value review and mandatory notes')
 incident=next(r for r in pa.query('incidents') if r['transaction_id']==rows[0]['id'])
 letter=pa.command('create_letter',incident_ids=[incident['id']],due_date='2026-11-10')['id'];pa.command('issue_letter',id=letter)
 pdf=pa.call('export',{'report':'Transactions','filter':FILTER,'letter_id':letter});assert pdf.startswith(b'%PDF')
 pa.command('create_reminder',letter_id=letter,due_date='2026-11-20')
 pa.command('comply',id=incident['id'],reference='REPLY-1',notes='Voucher received')
 assert next(r for r in pa.query('letters') if r['id']==letter)['status']=='Complied'
 print('PASS correspondence, reminder, immutable PDF and compliance rollup')
 correction=pa.command('request_correction',id=rows[1]['id'],revision=1,status='Mismatch',reason='Amount differs',notes='Corrected',request_reason='Found difference')['id']
 admin.command('review_correction',id=correction,approve=True,notes='Approved')
 pa.command('request_correction',expected=409,id=rows[1]['id'],revision=1,status='Matched',reason='',notes='',request_reason='Stale')
 report=pa.query('report',report='Transactions',filter=f);assert report['totals']['total']==251 and len(report['rows'])==100
 assert report['totals']['credit']=='102562.50',report['totals']
 history=pa.query('history',id=rows[1]['id']);assert len(history)>=2
 assert history[-1]['before_value']['revision']==1 and history[-1]['after_value']['revision']==2
 assert history[-1]['actor_id']==admin.call('me')['id']
 other.call('query',{'kind':'history','id':rows[1]['id']},expected=403)
 print('PASS correction revision checks, retained history, office scope and complete report aggregates')
 # Progress summaries must use the complete dataset and remain in the caller's office scope.
 dpr=pa.query('report',report='DPR',filter=f)
 assert len(dpr['document']['sections'][0]['rows'])==31
 assert dpr['totals']['total']==2,dpr['totals']
 assert any('Checked 2 vouchers' in r[1] for r in dpr['document']['sections'][0]['rows'])
 mpr=pa.query('report',report='MPR',filter=f)
 balances=mpr['document']['sections'][1]['rows']
 all_balance=next(r for r in balances if r[0]=='All')
 assert all_balance==['All','0','2','1','1'],all_balance
 hidden=other.query('report',report='MPR',filter=f)
 assert hidden['totals']['total']==0
 assert all(int(c)==0 for r in hidden['document']['sections'][1]['rows'] for c in r[1:])
 other.call('query',{'kind':'report','report':'DPR','filter':{**f,'from_date':'2024-01-01','to_date':'2026-01-01'}},expected=400)
 # Renderer sees Unicode data as literal text, and issued correspondence is immutable.
 settings=admin.query('settings')
 try:
  admin.command('save_settings',**{**settings,'signatory':'अनिता தமிழ் മലയാളം','designation':'SBCO Incharge'})
  assert pa.call('export',{'report':'Transactions','filter':FILTER,'letter_id':letter})==pdf
  for kind in ['DPR','MPR','Daily Detail','Transactions','Mismatch','MAP','Pending Voucher']:
   result=pa.call('export',{'report':kind,'filter':f,'letter_id':None})
   assert result.startswith(b'%PDF-') and len(result)>5000
   pathlib.Path('/tmp/sbco-report-'+kind.replace(' ','-')+'.pdf').write_bytes(result)
  pathlib.Path('/tmp/sbco-report-document.json').write_text(json.dumps(pa.query('report',report='MPR',filter=f)['document'],ensure_ascii=False))
 finally:
  admin.command('save_settings',**settings)
 print('PASS DPR dates, MPR balances, Unicode exports, report scope and retained issued bytes')

 parent='PARENT-'+tag;branch='BRANCH-'+tag
 branch_import=admin.command('import',filename='branch-'+tag+'.xlsx',content_base64=base64.b64encode(workbook(parent,count=1,branch=branch)).decode())['id']
 for _ in range(120):
  item=next(r for r in admin.query('imports') if r['id']==branch_import)
  if item['status'] in ('Completed','Failed'):break
  time.sleep(.5)
 assert item['status']=='Completed',item
 admin.command('save_pool',id=None,name='Branch '+tag,offices=[branch],pa_user=pa_id,random_percent=0)
 branch_row=pa.query('transactions',filter={**FILTER,'office':branch},cursor=None,limit=10)['rows'][0]
 pa.command('verify',id=branch_row['id'],revision=1,status='Mismatch',reason='Voucher missing',notes='BO fixture')
 incident=next(r for r in pa.query('incidents') if r['transaction_id']==branch_row['id'])
 letter=pa.command('create_letter',incident_ids=[incident['id']],due_date='2026-11-10')['id']
 assert next(r for r in pa.query('letters') if r['id']==letter)['office_id']==parent
 pa.command('issue_letter',id=letter)
 assert pa.call('export',{'report':'Transactions','filter':FILTER,'letter_id':letter}).startswith(b'%PDF')
 other.call('export',{'report':'Transactions','filter':FILTER,'letter_id':letter},expected=403)
 assert not any(r['id']==letter for r in other.query('letters'))
 print('PASS BO correspondence routes to SO without granting unrelated office access')
 out=pathlib.Path('/tmp/sbco-test-session.json');out.write_text(json.dumps({'pa_email':f'pa-{tag}@example.test','pa_password':pw,'admin_email':os.environ['SBCO_ADMIN_EMAIL'],'admin_password':os.environ['SBCO_ADMIN_PASSWORD'],'office':office}));out.chmod(0o600)
 pathlib.Path('/tmp/sbco-test-letter.pdf').write_bytes(pdf)
 print('All integration scenarios passed.')
if __name__=='__main__':run()
