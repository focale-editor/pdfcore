"""Independently verify PdfCore decryption/export using QPDF and Poppler.

Run check_security_corpus.dart first. Requires pikepdf, Pillow and Poppler.
Downloaded source PDFs and generated images stay in ignored corpus directories.
"""
import hashlib
import json
from pathlib import Path
import subprocess

import pikepdf
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'test/corpus/files/security'
OUTPUT = ROOT / 'test/corpus/output/security'


def streams(pdf):
    """Compare encoded, decrypted bytes even for filters outside PdfCore."""
    return {
        obj.objgen: hashlib.sha256(obj.read_raw_bytes()).hexdigest()
        for obj in pdf.objects
        if isinstance(obj, pikepdf.Stream) and obj.get('/Type') != pikepdf.Name.XRef
    }


def render(path, password, destination):
    """Render the first page with a separate implementation, using actual fonts."""
    subprocess.run(['/usr/bin/pdftoppm', '-upw', password, '-f', '1', '-singlefile', '-r', '72', '-png', str(path), str(destination)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return Image.open(destination.with_suffix('.png')).convert('RGB')


def main():
    """Require exact content preservation and independently authenticated output."""
    manifest = json.loads((ROOT / 'test/corpus/security_manifest.json').read_text())
    report = []
    for index, entry in enumerate(manifest['files']):
        source = SOURCE / entry['file']
        if entry['expected'] == 'password':
            try:
                pikepdf.open(source, password=entry['password'])
            except pikepdf.PasswordError:
                report.append({'file': entry['file'], 'passwordRequired': True})
                continue
            raise AssertionError('Expected password refusal')
        encrypted = OUTPUT / (entry['file'] + '.encrypted.pdf')
        plain = OUTPUT / (entry['file'] + '.plain.pdf')
        with pikepdf.open(source, password=entry['password']) as original:
            expected = streams(original)
            for path, password in [(plain, ''), (encrypted, 'export-user'), (encrypted, 'export-owner')]:
                with pikepdf.open(path, password=password) as converted:
                    assert len(converted.pages) == len(original.pages)
                    assert streams(converted) == expected, (entry['file'], 'changed stream bytes')
                    assert {str(k): str(v) for k, v in converted.docinfo.items()} == {str(k): str(v) for k, v in original.docinfo.items()}
                    if path == encrypted:
                        assert converted.encryption.R == 6 and converted.encryption.bits == 256
                        assert not converted.allow.extract and not converted.allow.modify_other
                        assert converted.owner_password_matched == (password == 'export-owner')
                    else:
                        assert not converted.is_encrypted
            try:
                pikepdf.open(encrypted, password='wrong')
            except pikepdf.PasswordError:
                pass
            else:
                raise AssertionError('Wrong password accepted')
        first = render(source, entry['password'], OUTPUT / f'{index}-source')
        second = render(encrypted, 'export-user', OUTPUT / f'{index}-encrypted')
        assert first.size == second.size and ImageChops.difference(first, second).getbbox() is None, (entry['file'], 'render changed')
        report.append({'file': entry['file'], 'decryptedStreamsEqual': True, 'userAndOwnerAccepted': True, 'wrongPasswordRejected': True, 'popplerPixelsEqual': True})
    (OUTPUT / 'independent-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'QPDF/Poppler: {len(report)} expected outcomes; all exported pages render identically.')


if __name__ == '__main__':
    main()
