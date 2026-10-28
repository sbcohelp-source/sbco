"""Rehearse a logical major upgrade using disposable Docker clusters, never live databases."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
DOCKER = ['docker', '--context', os.environ.get('SBCO_DOCKER_CONTEXT', 'default')]

def run(*args, data=None, env=None):
    result = subprocess.run([*DOCKER, *args], input=data, text=True, capture_output=True, env=env)
    if result.returncode:
        raise RuntimeError(f'Docker operation failed: {args[0]}: {result.stderr[-1500:]}')
    return result.stdout.strip()

def main():
    tag = 'sbco-upgrade-' + uuid.uuid4().hex[:10]
    old, new = tag+'-17', tag+'-18'
    containers = []
    with tempfile.TemporaryDirectory(prefix='sbco-upgrade-') as temporary:
        secret = secrets.token_urlsafe(32)
        envfile = Path(temporary)/'database.env'
        envfile.write_text(f'POSTGRES_USER=sbco\nPOSTGRES_DB=sbco\nPOSTGRES_PASSWORD={secret}\nPGUSER=sbco\nPGPASSWORD={secret}\nPGDATABASE=sbco\n')
        envfile.chmod(0o600)
        run('network','create',tag)
        try:
            for name, image in [(old,'postgres:17'),(new,'postgres:18.6')]:
                run('run','-d','--name',name,'--network',tag,'--env-file',str(envfile),'-p','127.0.0.1::5432',image)
                containers.append(name)
                for _ in range(60):
                    ready = subprocess.run([*DOCKER,'exec',name,'pg_isready','-U','sbco'],capture_output=True)
                    if ready.returncode==0:break
                    time.sleep(.5)
                else:raise RuntimeError('Temporary PostgreSQL did not become ready')
            port = run('port',old,'5432/tcp').rsplit(':',1)[1]
            env = {**os.environ,'DATABASE_URL':f'postgresql://sbco:{secret}@127.0.0.1:{port}/sbco',
                   'SBCO_ADMIN_EMAIL':'upgrade@example.test','SBCO_ADMIN_NAME':'Upgrade fixture',
                   'SBCO_ADMIN_PASSWORD':secrets.token_urlsafe(24)}
            subprocess.run([str(ROOT/'target/debug/sbco-api'),'--bootstrap'],env=env,check=True,capture_output=True)
            fixture = """
            INSERT INTO offices VALUES('001200','परीक्षण कार्यालय','SO',NULL);
            INSERT INTO imports(id,filename,file_hash,content,imported_by,status,total,inserted)
              SELECT '10000000-0000-0000-0000-000000000001','upgrade-fixture.xlsx','fixture',decode('0001ffabcd','hex'),id,'Completed',1,1 FROM users;
            INSERT INTO transactions(id,office_id,report_type,report_date,value_date,account_number,credit,debit,import_id,source_sheet,source_row,fingerprint)
              VALUES('20000000-0000-0000-0000-000000000001','001200','SO','2026-10-01','2026-10-01','000012345678',123456789.25,0,'10000000-0000-0000-0000-000000000001','LongBook',6,'upgrade-fingerprint');
            INSERT INTO letters(id,number,office_id,kind,due_date,pdf,pdf_hash) VALUES('30000000-0000-0000-0000-000000000001','TEST/1','001200','Initial','2026-11-01',decode('255044462d312e370aff00','hex'),'fixture-pdf');
            """
            run('exec','-i',old,'psql','-U','sbco','-d','sbco','-v','ON_ERROR_STOP=1',data=fixture)
            snapshot = """SELECT json_build_object(
              'users',(SELECT json_agg(row_to_json(u) ORDER BY id) FROM users u),
              'offices',(SELECT json_agg(row_to_json(o) ORDER BY id) FROM offices o),
              'transactions',(SELECT json_agg(row_to_json(t) ORDER BY id) FROM transactions t),
              'source_bytes',(SELECT encode(content,'hex') FROM imports),
              'pdf_bytes',(SELECT encode(pdf,'hex') FROM letters),
              'migrations',(SELECT json_agg(version ORDER BY version) FROM _sqlx_migrations));"""
            before = json.loads(run('exec',old,'psql','-U','sbco','-d','sbco','-Atqc',snapshot))
            # Use the destination version's tools to dump the older server.
            run('run','--rm','--network',tag,'--env-file',str(envfile),'-e',f'PGHOST={old}',
                '-v',f'{temporary}:/backup','postgres:18.6','pg_dump','--format=custom','--file=/backup/upgrade.dump')
            run('run','--rm','--network',tag,'--env-file',str(envfile),'-e',f'PGHOST={new}',
                '-v',f'{temporary}:/backup:ro','postgres:18.6','pg_restore','--exit-on-error','--single-transaction','--no-owner','--no-acl','--dbname=sbco','/backup/upgrade.dump')
            after = json.loads(run('exec',new,'psql','-U','sbco','-d','sbco','-Atqc',snapshot))
            assert before == after, 'Restored application records or byte payloads changed'
            assert json.loads(run('exec',old,'psql','-U','sbco','-d','sbco','-Atqc',snapshot)) == before, 'Source cluster changed'
            versions = [run('exec',name,'psql','-U','sbco','-Atqc','SHOW server_version') for name in containers]
            print('PASS PostgreSQL '+' → '.join(versions)+': users/password hashes, Unicode offices, leading-zero accounts, exact money, source bytes, PDF bytes and migrations preserved; original cluster unchanged')
        finally:
            for name in containers:
                run('rm','-f','-v',name)
            run('network','rm',tag)

if __name__ == '__main__': main()
