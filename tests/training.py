"""Training isolation/lifecycle rehearsal; disposable PostgreSQL database only."""
import base64
import concurrent.futures
import json
import pathlib
import secrets
import subprocess
import time
import urllib.error
import urllib.request
import uuid

import integration
from integration import FILTER
from reliability import ROOT, Rehearsal, template
from setup_import import filled


class Practice:
    def __init__(self, live, generation, role='Administrator'):
        self.live, self.generation, self.role = live, generation, role

    def call(self, path, data=None, expected=200):
        request = urllib.request.Request(integration.BASE + path,
            data=None if data is None else json.dumps(data).encode(),
            headers={'Content-Type':'application/json','X-SBCO-Request':'1',
                     'X-SBCO-Training':json.dumps({'generation':self.generation,'role':self.role})})
        try:
            response = self.live.opener.open(request, timeout=90)
            status, body = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, body = error.code, error.read()
        assert status == expected, (path,status,body[:500])
        return body if body.startswith(b'%PDF') else json.loads(body)

    def query(self, kind, **values):
        return self.call('query', {'kind':kind, **values})

    def command(self, kind, expected=200, request_id=None, **values):
        return self.call('command', {'request_id':request_id or str(uuid.uuid4()),'command':{'kind':kind, **values}}, expected)


def run():
    r = Rehearsal()
    r.sql(f'CREATE DATABASE {r.database}', 'sbco')
    try:
        subprocess.run([str(ROOT/'target/debug/sbco-api'),'--bootstrap'],env=r.env,capture_output=True,check=True)
        process = r.start('sbco-api')
        def connect():
            try: return r.client()
            except OSError: return None
        admin = r.wait(connect)
        password = secrets.token_urlsafe(24)
        for name, role in [('pa','Pa'),('supervisor','Supervisor')]:
            admin.command('create_user',name=name,email=name+'@example.test',password=password,role=role)
        pa = r.client('pa@example.test',password)
        supervisor = r.client('supervisor@example.test',password)
        admin.command('save_office',id='REAL-SO',name='Real Office',office_type='SO',parent_id=None)
        before = {table:r.sql(f'SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),\'[]\'::jsonb) FROM {table} t') for table in ['users','offices','settings']}
        assert not admin.call('training')['available']
        integration.Client().call('training',expected=401)
        integration.Client().call('training/enable',{},expected=401)
        # Force failure after migrations and seed, immediately before publish.
        # PostgreSQL must roll back schema DDL, sample rows and metadata together.
        r.sql('''CREATE FUNCTION fail_training_provision() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.action='EnableTraining' THEN RAISE EXCEPTION 'test provisioning rollback'; END IF; RETURN NEW; END $$;
            CREATE TRIGGER fail_training_provision BEFORE INSERT ON audit FOR EACH ROW EXECUTE FUNCTION fail_training_provision();''')
        admin.call('training/enable',{},expected=500)
        assert r.sql('SELECT count(*) FROM training_workspaces') == '0'
        assert r.sql("SELECT count(*) FROM pg_namespace WHERE nspname LIKE 'sbco_training_%'") == '0'
        r.sql('DROP TRIGGER fail_training_provision ON audit; DROP FUNCTION fail_training_provision()')
        print('PASS failed provisioning rolls back all schema/data/metadata atomically')
        with concurrent.futures.ThreadPoolExecutor(3) as executor:
            enabled = list(executor.map(lambda _:admin.call('training/enable',{}),range(3)))
        assert len({value['generation'] for value in enabled}) == 1
        generation = enabled[0]['generation']
        assert enabled[0]['counts'] == {'offices':3,'users':3,'pools':1,'imports':1,'transactions':24,'incidents':3,'letters':1}, enabled
        assert r.sql("SELECT count(*) FROM audit WHERE action='EnableTraining'") == '1'
        assert r.sql('SELECT count(*) FROM training_workspaces') == '1'
        training = Practice(admin,generation)
        training_pa = Practice(admin,generation,'Pa')
        training_supervisor = Practice(admin,generation,'Supervisor')
        assert training.call('me')['role'] == 'Administrator'
        assert training_pa.call('me')['role'] == 'Pa'
        assert training_supervisor.call('me')['role'] == 'Supervisor'
        assert len(training.query('users')) == 3
        training_pa.call('query',{'kind':'users'},expected=403)
        assert len(training.query('offices')) == 3
        assert len(admin.query('offices')) == 1
        assert len(training_pa.query('transactions',filter=FILTER,cursor=None,limit=100)['rows']) == 24
        training_pa.command('save_office',id='FORBIDDEN',name='Denied',office_type='SO',parent_id=None,expected=403)
        training.command('change_password',current_password=r.env['SBCO_ADMIN_PASSWORD'],new_password=password,expected=400)
        assert r.client().call('me')['role'] == 'Administrator'
        print('PASS concurrent idempotent enable, authentication, role switching, permissions and live password isolation')

        other_generation = pa.call('training/enable',{})['generation']
        supervisor_generation = supervisor.call('training/enable',{})['generation']
        Practice(pa,generation).call('query',{'kind':'offices'},expected=409)
        Practice(admin,other_generation).call('me',expected=409)
        assert Practice(pa,other_generation).call('me')['role'] == 'Administrator'
        assert Practice(supervisor,supervisor_generation).call('me')['role'] == 'Administrator'
        training.command('save_office',id='PRACTICE-NEW',name='User created training office',office_type='SO',parent_id=None)
        assert len(training.query('offices')) == 4
        assert len(Practice(pa,other_generation).query('offices')) == 3
        assert len(admin.query('offices')) == 1
        assert pa.call('me')['role'] == 'Pa'
        assert supervisor.call('me')['role'] == 'Supervisor'
        wrong = Practice(pa,generation)
        wrong.command('save_office',id='WRONG-OWNER',name='Denied',office_type='SO',parent_id=None,expected=409)
        wrong.call('export',{'report':'Transactions','filter':FILTER,'letter_id':None},expected=409)
        user = training.command('create_user',name='Practice created user',email='created@practice.test',password=password,role='Pa')['id']
        training.command('save_pool',id=None,name='Practice created pool',offices=['PRACTICE-NEW'],pa_user=user,random_percent=25)
        extra_admin = training.command('create_user',name='Second training admin',email='second-admin@practice.test',password=password,role='Administrator')['id']
        for persona in [row for row in training.query('users') if row['email'].endswith('@training.invalid')]:
            for changed_role, active in [('Pa' if persona['role'] != 'Pa' else 'Supervisor',True),(persona['role'],False)]:
                training.command('update_user',user_id=persona['id'],name=persona['name'],role=changed_role,active=active,expected=400)
            training.command('update_user',user_id=persona['id'],name=persona['name']+' renamed',role=persona['role'],active=True)
            changed = filled('SBCO_Setup_Template.xlsx',{'xl/worksheets/sheet1.xml':{'A2':persona['name']+' renamed','B2':persona['email'],'C2':'Pa' if persona['role'] != 'Pa' else 'Supervisor'}})
            training.command('import_setup',filename='change-persona.xlsx',content_base64=base64.b64encode(changed).decode(),preview=False,expected=400)
        training.command('update_user',user_id=extra_admin,name='Ordinary training account',role='Pa',active=False)
        assert training.call('me')['role'] == 'Administrator'
        assert training_pa.call('me')['role'] == 'Pa'
        assert training_supervisor.call('me')['role'] == 'Supervisor'
        print('PASS built-in practice roles remain recoverable; renaming and ordinary user access edits still work')

        settings = training.query('settings')
        training.command('save_settings',random_percent=25,reminder_days=10,signatory='Practice signatory',designation='Training only',reasons=settings['reasons'])
        receipt = str(uuid.uuid4())
        admin.command('save_onboarding',request_id=receipt,step='team',completed=False)
        training.command('save_onboarding',request_id=receipt,step='preferences',completed=False)
        assert admin.query('onboarding')['step'] == 'team'
        assert training.query('onboarding')['step'] == 'preferences'
        assert r.sql(f"SELECT count(*) FROM command_receipts WHERE request_id='{receipt}'") == '1'
        schema = 'sbco_training_' + uuid.UUID(generation).hex
        assert r.sql(f'SELECT count(*) FROM {schema}._sqlx_migrations') == r.sql('SELECT count(*) FROM _sqlx_migrations')
        # Missing training relations must error, never read a same-named public relation.
        r.sql(f'ALTER TABLE {schema}.offices RENAME TO held_offices')
        training.call('query',{'kind':'offices'},expected=500)
        r.sql(f'ALTER TABLE {schema}.held_offices RENAME TO offices')
        print('PASS per-owner isolation, all live roles may practice, schema-only lookup and tracked migrations')

        rows = training_pa.query('transactions',filter=FILTER,cursor=None,limit=100)['rows']
        pending = next(row for row in rows if row['primary_status']=='Pending')
        training_pa.command('verify',id=pending['id'],revision=pending['revision'],status='Matched',reason='',notes='Training user action')
        assert training_pa.query('history',id=pending['id'])
        letter = training_pa.query('letters')[0]['id']
        training_pa.command('issue_letter',id=letter)
        for request in [{'report':'Transactions','filter':FILTER,'letter_id':None}, {'report':'Transactions','filter':FILTER,'letter_id':letter}]:
            pdf = training_pa.call('export',request)
            path = pathlib.Path(r.logs.name)/('letter.pdf' if request['letter_id'] else 'report.pdf')
            path.write_bytes(pdf)
            text = subprocess.check_output(['pdftotext',str(path),'-'],text=True)
            assert 'TRAINING' in text and 'NOT FOR OFFICIAL USE' in text, text[:400]
        r.start('sbco-worker')
        batch = training.command('import',filename='practice-upload.xlsx',content_base64=base64.b64encode(template('TRAINING-IMPORTED',12)).decode())['id']
        def imported():
            row = next(row for row in training.query('imports') if row['id']==batch)
            assert row['status'] != 'Failed', row
            return row if row['status']=='Completed' else None
        assert r.wait(imported)['inserted'] == 12
        assert r.sql('SELECT count(*) FROM imports') == '0'
        assert r.sql('SELECT count(*) FROM transactions') == '0'
        print('PASS practice verification/history, marked report and issued-letter PDFs, isolated worker import')

        process.terminate(); process.wait(timeout=15)
        r.start('sbco-api'); admin = r.wait(connect)
        assert admin.call('training')['generation'] == generation
        training = Practice(admin,generation)
        assert len(training.query('offices')) == 5
        admin.call('training/reset',{'generation':generation,'confirmation':'wrong'},expected=400)
        pa.call('training/reset',{'generation':generation,'confirmation':'DELETE TRAINING'},expected=409)
        # Slow an actual multi-chunk training import and reset while the worker
        # is inside its first chunk. Reset must wait through finalization, then
        # remove every chunk; the old worker must never recreate a new schema.
        r.sql(f'''CREATE FUNCTION {schema}.slow_practice_import() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(0.02); RETURN NEW; END $$;
            CREATE TRIGGER slow_training_insert BEFORE INSERT ON {schema}.transactions FOR EACH ROW EXECUTE FUNCTION {schema}.slow_practice_import();''')
        slow_batch = training.command('import',filename='reset-overlap.xlsx',content_base64=base64.b64encode(template('RESET-OVERLAP',251)).decode())['id']
        r.wait(lambda:r.sql(f"SELECT status FROM {schema}.imports WHERE id='{slow_batch}'") == 'Processing')
        started = time.monotonic()
        removed = admin.call('training/reset',{'generation':generation,'confirmation':'DELETE TRAINING'})
        assert time.monotonic()-started > 2
        assert not removed['available']
        assert r.sql(f"SELECT count(*) FROM pg_namespace WHERE nspname='{schema}'") == '0'
        time.sleep(.4)
        assert r.sql(f"SELECT count(*) FROM pg_namespace WHERE nspname='{schema}'") == '0'
        print('PASS reset during multi-chunk import waits for finalization and prevents stale-worker writes')
        # Use a fresh workspace for the independent shared-lock reset test.
        generation = admin.call('training/enable',{})['generation']
        schema = 'sbco_training_' + uuid.UUID(generation).hex
        training = Practice(admin,generation)
        # Explicitly hold the same lifecycle shared lock used by requests/workers.
        lock = subprocess.Popen(['docker','--context','default','exec','-i',r.container,'psql','-U','sbco','-d',r.database,'-v','ON_ERROR_STOP=1'],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
        lock.stdin.write(f"BEGIN; SELECT 1 FROM training_workspaces WHERE generation='{generation}' FOR SHARE; SELECT pg_sleep(2); COMMIT;\n"); lock.stdin.close()
        time.sleep(.3)
        started = time.monotonic()
        removed = admin.call('training/reset',{'generation':generation,'confirmation':'DELETE TRAINING'})
        assert time.monotonic()-started > 1.2
        lock.wait(timeout=10)
        assert not removed['available'] and removed['generation'] is None
        assert not any(removed['counts'].values())
        assert r.sql(f"SELECT count(*) FROM pg_namespace WHERE nspname='{schema}'") == '0'
        training.call('query',{'kind':'offices'},expected=409)
        training.command('save_office',id='STALE',name='Stale request',office_type='SO',parent_id=None,expected=409)
        training.call('export',{'report':'Transactions','filter':FILTER,'letter_id':None},expected=409)
        admin.call('training/reset',{'generation':generation,'confirmation':'DELETE TRAINING'},expected=409)
        assert pa.call('training')['generation'] == other_generation
        fresh = admin.call('training/enable',{})
        assert fresh['generation'] != generation and fresh['counts']['offices'] == 3
        assert fresh['counts']['transactions'] == 24
        for table,value in before.items():
            assert r.sql(f'SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),\'[]\'::jsonb) FROM {table} t') == value, table
        assert r.sql("SELECT count(*) FROM audit WHERE action='ResetTraining'") == '2'
        print('PASS persistence, reset confirmation/ownership, reset waits for in-flight work, complete removal, stale refusal, fresh generation and live records preserved')
    finally:
        for process in r.processes:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=15)
        # Retain diagnostics on failure without printing credentials.
        for log in pathlib.Path(r.logs.name).glob('*.log'):
            if 'ERROR' in log.read_text():
                pathlib.Path('/tmp/sbco-training-'+log.name).write_text(log.read_text())
        r.sql(f'DROP DATABASE {r.database} WITH (FORCE)', 'sbco')
        r.logs.cleanup()


if __name__ == '__main__':
    run()
