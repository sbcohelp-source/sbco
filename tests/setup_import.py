"""Exercise the delivered templates through the real API using isolated test data."""
import base64
import io
import os
import pathlib
import secrets
import time
import uuid
import xml.etree.ElementTree as ET
import zipfile
from integration import Client, FILTER

TEMPLATES = pathlib.Path(__file__).resolve().parents[1] / 'apps/web/public/templates'
NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'

def filled(filename, sheets):
    """Fill test-only copies of the actual deliverables, preserving styles and headers."""
    output = io.BytesIO()
    with zipfile.ZipFile(TEMPLATES / filename) as source, zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as target:
        for entry in source.infolist():
            data = source.read(entry.filename)
            if entry.filename in sheets:
                root = ET.fromstring(data)
                body = root.find(f'{{{NS}}}sheetData')
                for address, value in sheets[entry.filename].items():
                    number = ''.join(c for c in address if c.isdigit())
                    row = body.find(f'{{{NS}}}row[@r="{number}"]')
                    if row is None:
                        row = ET.SubElement(body, f'{{{NS}}}row', r=number)
                    cell = row.find(f'{{{NS}}}c[@r="{address}"]')
                    if cell is None:
                        cell = ET.SubElement(row, f'{{{NS}}}c', r=address)
                    for child in list(cell): cell.remove(child)
                    cell.set('t', 'n' if isinstance(value, (float, int)) else 'inlineStr')
                    if cell.get('t') == 'n':
                        ET.SubElement(cell, f'{{{NS}}}v').text = str(value)
                    else:
                        ET.SubElement(ET.SubElement(cell, f'{{{NS}}}is'), f'{{{NS}}}t').text = value
                data = ET.tostring(root)
            target.writestr(entry, data)
    return output.getvalue()

def run():
    admin = Client()
    admin.login(os.environ['SBCO_ADMIN_EMAIL'], os.environ['SBCO_ADMIN_PASSWORD'])
    tag = uuid.uuid4().hex[:10]
    email = f'template-{tag}@example.test'
    so, bo, pool = f'00{tag}', f'01{tag}', f'Template {tag}'
    cells = {
        'xl/worksheets/sheet1.xml': {'A2':'Template PA', 'B2':email, 'C2':'Pa'},
        'xl/worksheets/sheet2.xml': {'A2':bo, 'B2':'Template BO', 'C2':'BO', 'D2':so, 'A3':so, 'B3':'Template SO', 'C3':'SO'},
        'xl/worksheets/sheet3.xml': {'A2':pool,'B2':email,'C2':so,'D2':10,'A3':pool,'B3':email,'C3':bo,'D3':10},
    }
    def submit(data, preview=True, expected=200, who=admin):
        return who.command('import_setup', filename='setup.xlsx', content_base64=base64.b64encode(data).decode(), preview=preview, expected=expected)
    blank = (TEMPLATES/'SBCO_Setup_Template.xlsx').read_bytes()
    submit(blank, expected=400)
    content = filled('SBCO_Setup_Template.xlsx', cells)
    preview = submit(content)
    assert preview['created'] == {'users':1,'offices':2,'pools':1}, preview
    assert not any(u['email']==email for u in admin.query('users'))
    assert not any(o['id']==so for o in admin.query('offices'))
    bad = {**cells, 'xl/worksheets/sheet3.xml': {**cells['xl/worksheets/sheet3.xml'], 'C3':'missing-office'}}
    submit(filled('SBCO_Setup_Template.xlsx', bad), preview=False, expected=400)
    assert not any(u['email']==email for u in admin.query('users')), 'Failed import leaked a user'
    assert not any(o['id']==so for o in admin.query('offices')), 'Failed import leaked an office'
    result = submit(content, preview=False)
    assert result['created'] == preview['created']
    repeat = submit(content, preview=False)
    assert repeat['created'] == {'users':0,'offices':0,'pools':0}
    assert repeat['existing'] == preview['created']
    changed = {**cells, 'xl/worksheets/sheet1.xml': {**cells['xl/worksheets/sheet1.xml'], 'C2':'Administrator'}}
    submit(filled('SBCO_Setup_Template.xlsx', changed), preview=False, expected=400)
    user = next(u for u in admin.query('users') if u['email']==email)
    assert user['role']=='Pa'
    password = secrets.token_urlsafe(24)
    admin.command('reset_password', user_id=user['id'], password=password)
    pa = Client(); pa.login(email, password)
    submit(content, who=pa, expected=403)
    print('PASS template preview, atomic rollback, idempotent setup, conflict checks and admin authorization')
    for branch in (False, True):
        filename = f'SBCO_{"BO" if branch else "SO"}_Transactions_Template.xlsx'
        sheet = {'B1':so, 'C1':'Template SO', f'B{3 if branch else 2}':'2026-10-01',
                 'A6':1,'B6':'000012345678','C6':'SB','D6':f'{tag}-{branch}',
                 'E6':'REF-001','F6':'PA01','G6':'Credit','H6':'Deposit','J6':1250.50,'K6':0}
        if branch: sheet.update(B2=bo,C2='Template BO')
        data = filled(filename, {'xl/worksheets/sheet1.xml':sheet})
        batch_id = admin.command('import',filename=filename,content_base64=base64.b64encode(data).decode())['id']
        for _ in range(60):
            batch = next(i for i in admin.query('imports') if i['id']==batch_id)
            if batch['status'] in ('Completed','Failed'):break
            time.sleep(.25)
        assert batch['status']=='Completed' and batch['inserted']==1, batch
        records = pa.query('transactions',filter={**FILTER,'office':bo if branch else so},cursor=None,limit=50)['rows']
        assert len(records)==1 and records[0]['account_number']=='000012345678', records
        assert records[0]['credit']=='1250.50' and records[0]['value_date']=='2026-10-01'
    admin.command('update_user',user_id=user['id'],name='Template PA',role='Pa',active=False)
    pa.call('me',expected=401)
    assert next(p for p in admin.query('pools') if p['name']==pool)['pa_user'] is None
    print('PASS SO/BO template imports, leading-zero accounts, exact amounts, date fallback and disabled-session revocation')

if __name__ == '__main__': run()
