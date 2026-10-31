#!/usr/bin/env python3
"""Verify edited corpus PDFs with QPDF and compare independent Poppler renders."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import pikepdf

ROOT = Path(__file__).resolve().parents[1]


def render(document, directory, prefix):
    """Render every page and hash the PNG bytes at identical settings."""
    result = subprocess.run(
        ['/usr/bin/pdftoppm', '-r', '48', '-png', str(document), str(directory / prefix)],
        capture_output=True, timeout=60,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace'))
    return [hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(directory.glob(f'{prefix}-*.png'))]


def verify(entry):
    """Reopen without recovery and compare rewritten page-program rendering."""
    source = ROOT / 'test/corpus/files' / entry['file']
    output = ROOT / 'test/corpus/output/editing' / entry['file']
    with pikepdf.open(output, attempt_recovery=False) as document:
        warnings = document.check_pdf_syntax()
        if warnings:
            raise ValueError(f'QPDF syntax warnings: {warnings}')
        pages = len(document.pages)
    with tempfile.TemporaryDirectory(prefix='pdfcore-editing-render-') as temporary:
        directory = Path(temporary)
        reference = source
        if entry.get('render_reference') == 'qpdf-canonical':
            reference = directory / 'canonical.pdf'
            with pikepdf.open(source, attempt_recovery=False) as document:
                document.save(reference)
        before = render(reference, directory, 'before')
        after = render(output, directory, 'after')
        if len(after) != pages or before != after:
            raise ValueError('Page program rewrite changed independent rendered pixels')
    return {**entry, 'qpdf_warnings': [], 'identical_rendered_pages': pages}


def main():
    """Fail on missing files, syntax errors, render errors or pixel differences."""
    rows = json.loads((ROOT / 'test/corpus/output/editing/report.json').read_text())
    report = {'pikepdf': pikepdf.__version__, 'qpdf': pikepdf.__libqpdf_version__, 'files': []}
    failures = []
    for row in rows:
        try:
            report['files'].append(verify(row))
        except Exception as error:
            failures.append(f'{row["file"]}: {error}')
            report['files'].append({**row, 'failure': str(error)})
    destination = ROOT / 'test/corpus/output/editing/interop.json'
    destination.write_text(json.dumps(report, indent=2) + '\n')
    print(f'PdfCore editing: {len(rows) - len(failures)}/{len(rows)} independently checked files', flush=True)
    for failure in failures:
        print(failure, flush=True)
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
