"""Read-only report acceptance using the isolated API and production PDF renderer.

Run after integration.py. Artifacts are synthetic operator-review samples, never approval.
Requires Poppler tools and `cargo build -p sbco-documents --example render`.
"""
import json
import pathlib
import shutil
import subprocess
import xml.etree.ElementTree as ET

from integration import Client, FILTER

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'data/operator-review'
TEMP = pathlib.Path('/tmp/sbco-pdf-acceptance')
NS = {'h': 'http://www.w3.org/1999/xhtml'}


def check(path, markers=()):
    text = subprocess.check_output(['/usr/bin/pdftotext', '-layout', str(path), '-'], text=True)
    for marker in markers:
        assert marker in text, f'{path.name}: missing {marker}'
    xml = subprocess.check_output(['/usr/bin/pdftotext', '-bbox', str(path), '-'])
    root = ET.fromstring(xml)
    pages = root.findall('.//h:page', NS)
    assert pages, path
    for page in pages:
        width, height = float(page.attrib['width']), float(page.attrib['height'])
        for word in page.findall('h:word', NS):
            assert 5 <= float(word.attrib['xMin']) <= float(word.attrib['xMax']) <= width - 5, (path.name, word.text, word.attrib)
            assert 5 <= float(word.attrib['yMin']) <= float(word.attrib['yMax']) <= height - 5, (path.name, word.text, word.attrib)
    print(f'PASS {path.name}: {len(pages)} pages, expected text and page bounds')
    return len(pages)


def render(name, document):
    source = TEMP / f'{name}.json'
    source.write_text(json.dumps(document, ensure_ascii=False))
    target = OUTPUT / f'SAMPLE-{name}.pdf'
    subprocess.run([str(ROOT / 'target/debug/examples/render'), str(source), str(target)], check=True)
    return target


def run():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    TEMP.mkdir(exist_ok=True)
    account = json.loads(pathlib.Path('/tmp/sbco-test-session.json').read_text())
    client = Client()
    client.login(account['pa_email'], account['pa_password'])
    filters = {**FILTER, 'office': account['office']}
    for kind in ['DPR', 'MPR']:
        document = client.query('report', report=kind, filter=filters)['document']
        document['title'] = f'SAMPLE - {document["title"]}'
        document['notes'].insert(0, 'Synthetic test data. For office operator review only. Not approved for official use.')
        check(render(kind, document), ('SAMPLE', 'Synthetic test data'))
    letter = OUTPUT / 'SAMPLE-issued-letter.pdf'
    shutil.copyfile('/tmp/sbco-test-letter.pdf', letter)
    check(letter)
    scripts = 'हिंदी বাংলা ગુજરાતી ਪੰਜਾਬੀ ಕನ್ನಡ മലയാളം ଓଡ଼ିଆ தமிழ் తెలుగు اردو'
    long_text = ('The voucher discrepancy requires reconciliation against the original account ledger and supporting records. ' * 90)
    document = {
        'title': 'SAMPLE - Long-field and multilingual layout review',
        'subtitle': 'Synthetic test data only. This intentionally oversized remark checks continuation across pages.',
        'landscape': False,
        'sections': [
            {'title': 'Continuation table', 'columns': ['Account', 'Remark'], 'widths': [1, 4], 'rows': [
                ['000000000000001', 'BEGIN-LONG-REMARK ' + long_text + ' END-LONG-REMARK'],
                ['000000000000002', scripts],
                ['000000000000003', 'LAST-ROW-MARKER'],
            ]},
            {'title': 'Long reference', 'columns': ['Reference', 'Meaning'], 'widths': [1, 2], 'rows': [
                ['REFERENCE' + '0123456789' * 25, 'An uninterrupted identifier must wrap without crossing the table boundary.'],
            ]},
        ],
        'notes': ['NOT APPROVED - Office operator must check script shaping and business wording.'],
        'signatory': 'अनिता தமிழ் മലയാളം',
        'designation': 'SBCO Incharge - sample',
    }
    path = render('long-fields', document)
    pages = check(path, ('BEGIN-LONG-REMARK', 'END-LONG-REMARK', 'LAST-ROW-MARKER', 'NOT APPROVED'))
    assert pages >= 3, 'Expected a genuine multipage row continuation test'
    text = subprocess.check_output(['/usr/bin/pdftotext', '-layout', str(path), '-'], text=True)
    assert text.count('Account') >= 2, 'Table headers did not repeat across continuation pages'
    (OUTPUT / 'README.txt').write_text(
        'OFFICE OPERATOR REVIEW - SYNTHETIC TEST DATA\n\n'
        'These files are examples from the isolated test system, not official records.\n'
        'SAMPLE-issued-letter.pdf preserves the exact issued test bytes and therefore has no added watermark.\n'
        'Review DPR/MPR headings, columns, period rules, balances, staff totals, letter wording, address, due date, signature, pagination and language shaping.\n'
        'Record acceptance or required changes in docs/ACCEPTANCE_CHECKLIST.md. No operator approval is implied.\n'
    )


if __name__ == '__main__':
    run()
