#!/usr/bin/env python3
"""Compare actual PdfCore edits with separately authored QPDF/Poppler expectations."""
import json
from pathlib import Path
import subprocess
import tempfile

import pikepdf

from verify_editing import render

ROOT = Path(__file__).resolve().parents[1]
N = pikepdf.Name
D = pikepdf.Dictionary
A = pikepdf.Array


def resources(document, changed=False):
    """Author independent font, image and transparent Form XObject resources."""
    font = document.make_indirect(D(Type=N.Font, Subtype=N.Type1, BaseFont=N.Helvetica, Encoding=N.WinAnsiEncoding))
    # A real ToUnicode program maps the glyph bytes used by both strings.
    mapping = b'''/CIDInit /ProcSet findresource begin 12 dict begin begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Test def /CMapType 2 def
1 begincodespacerange <00> <ff> endcodespacerange
2 beginbfrange <20> <7e> <0020> <a0> <ff> <00a0> endbfrange
1 beginbfchar <80> <20ac> endbfchar
endcmap CMapName currentdict /CMap defineresource pop end end'''
    font.ToUnicode = document.make_stream(mapping)
    image = document.make_stream(bytes([0, 0, 255] if changed else [255, 0, 0]))
    image.update(D(Type=N.XObject, Subtype=N.Image, Width=1, Height=1, BitsPerComponent=8, ColorSpace=N.DeviceRGB))
    form = document.make_stream(b'0 1 0 rg 2 2 6 6 re f' if changed else b'0 0 1 rg 0 0 10 10 re f')
    form.update(D(Type=N.XObject, Subtype=N.Form, FormType=1, BBox=A([0, 0, 10, 10]), Resources=D(), Group=D(S=N.Transparency, CS=N.DeviceRGB)))
    return D(Font=D(F1=font), XObject=D(Im=image, Fm=form))


def content(changed=False):
    """Author the expected program directly, without using PdfCore's serializer."""
    rectangle = b'30 20 40 20 re' if changed else b'10 20 40 20 re'
    text = b'After \x80' if changed else b'Before'
    inline = bytes([255, 0, 255, 0]) if changed else b' EI '
    return (b'q 1 0 0 rg ' + rectangle + b' f Q\nBT /F1 16 Tf 10 160 Td (' + text + b') Tj ET\n'
            b'q 40 0 0 40 10 70 cm /Im Do Q\nq 4 0 0 4 80 70 cm /Fm Do Q\n'
            b'q 60 0 0 20 10 120 cm BI /W 4 /H 1 /BPC 8 /CS /G ID\n' + inline + b'\nEI Q\n')


def create(path, changed=False):
    """Create two pages sharing resources; only the first expected page changes."""
    with pikepdf.new() as document:
        shared = resources(document)
        for index in range(2):
            page = document.add_blank_page(page_size=(200, 200))
            page.Resources = resources(document, True) if changed and index == 0 else shared
            page.Contents = document.make_stream(content(changed and index == 0))
        document.save(path)


def verify_example():
    """Compare actual edits against a separately authored QPDF reference page."""
    subprocess.run(['dart', 'run', 'example/pdfcore_editing.dart'], cwd=ROOT, check=True)
    folder = ROOT / 'test/corpus/output/editing-example'
    with pikepdf.open(folder / 'after.pdf', attempt_recovery=False) as edited:
        if edited.check_pdf_syntax():
            raise ValueError('Edited example has syntax warnings')
        page = edited.pages[0]
        if page.Resources.XObject.Image.read_bytes() != bytes([0, 255, 0]):
            raise ValueError('Image samples were not edited')
        if str(page.Annots[0].Contents) != 'Edited link' or str(page.Annots[0].Private) != '/Keep':
            raise ValueError('Annotation edit lost data')
        if page.Annots[0].P.objgen != page.obj.objgen or str(edited.docinfo.Title) != 'Edited PDF':
            raise ValueError('Annotation owner or document metadata changed incorrectly')
        if '/Metadata' not in edited.Root:
            raise ValueError('XMP packet is missing')
    with tempfile.TemporaryDirectory(prefix='pdfcore-edited-example-') as temporary:
        directory = Path(temporary)
        expected = directory / 'reference.pdf'
        with pikepdf.Pdf.new() as reference:
            page = reference.add_blank_page(page_size=(200, 140))
            font = reference.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Font, Subtype=pikepdf.Name.Type1, BaseFont=pikepdf.Name.Helvetica, Encoding=pikepdf.Name.WinAnsiEncoding))
            image = reference.make_stream(bytes([0, 255, 0]))
            image.update(pikepdf.Dictionary(Type=pikepdf.Name.XObject, Subtype=pikepdf.Name.Image, Width=1, Height=1, BitsPerComponent=8, ColorSpace=pikepdf.Name.DeviceRGB))
            form = reference.make_stream(b'BT /F1 12 Tf 0 10 Td (Done) Tj ET')
            form.update(pikepdf.Dictionary(Type=pikepdf.Name.XObject, Subtype=pikepdf.Name.Form, BBox=[0, 0, 60, 30], Resources=pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=font))))
            page.Resources = pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=font), XObject=pikepdf.Dictionary(Image=image, Form=form))
            page.Contents = reference.make_stream(b'0 0 1 rg 10 10 60 30 re f 0 g BT /F1 18 Tf 10 100 Td (After) Tj ET q 20 0 0 20 100 10 cm /Image Do Q q 1 0 0 1 100 60 cm /Form Do Q')
            reference.save(expected)
        after = render(folder / 'after.pdf', directory, 'after')
        before = render(folder / 'before.pdf', directory, 'before')
        target = render(expected, directory, 'target')
        if after != target or after == before:
            raise ValueError('Edited sample differs from its independent visual reference')
        extracted = subprocess.run(['/usr/bin/pdftotext', str(folder / 'after.pdf'), '-'], check=True, capture_output=True).stdout.decode()
        if 'After' not in extracted or 'Done' not in extracted or 'Before' in extracted or 'Form' in extracted:
            raise ValueError('Edited text was not independently extracted')
    return {'text_path_image_form_render': 'matches independent QPDF reference', 'annotations_metadata': 'verified', 'text_extraction': 'After and Done'}


def main():
    """Check text extraction, scoped edits, PDF syntax and independently drawn pixels."""
    with tempfile.TemporaryDirectory(prefix='pdfcore-edited-features-') as temporary:
        directory = Path(temporary)
        source, expected, actual = [directory / f'{name}.pdf' for name in ['source', 'expected', 'actual']]
        create(source)
        create(expected, True)
        subprocess.run(['dart', 'run', 'tool/edit_interop_fixture.dart', str(source), str(actual)], cwd=ROOT, check=True)
        with pikepdf.open(actual, attempt_recovery=False) as document:
            warnings = document.check_pdf_syntax()
            if warnings:
                raise ValueError(f'QPDF warnings: {warnings}')
            if str(document.docinfo.Title) != 'Edited by PdfCore':
                raise ValueError('Document information edit missing')
            if document.pages[0].Resources.XObject.Im.read_bytes() != bytes([0, 0, 255]):
                raise ValueError('Image sample edit missing')
            if document.pages[1].Resources.XObject.Im.read_bytes() != bytes([255, 0, 0]):
                raise ValueError('Shared image changed on untouched page')
            if str(document.pages[0].Resources.XObject.Fm.Group.S) != '/Transparency':
                raise ValueError('Form transparency group lost')
        expected_text = subprocess.check_output(['/usr/bin/pdftotext', str(expected), '-'])
        actual_text = subprocess.check_output(['/usr/bin/pdftotext', str(actual), '-'])
        if actual_text != expected_text or 'After €'.encode() not in actual_text or b'Before' not in actual_text:
            raise ValueError('Independent Unicode extraction does not match the expected edit')
        before = render(source, directory, 'before')
        after = render(actual, directory, 'after')
        reference = render(expected, directory, 'reference')
        if after != reference or after[0] == before[0] or after[1] != before[1]:
            raise ValueError('Edited rendering or unchanged shared page does not match')
        report = {'pikepdf': pikepdf.__version__, 'qpdf': pikepdf.__libqpdf_version__, 'expected_rendered_pages': len(after), 'unchanged_shared_pages': 1,
                  'features': ['ToUnicode text replacement', 'path geometry', 'image samples', 'form program with transparency group', 'binary inline image', 'document information'], 'qpdf_warnings': [], 'extended_example': verify_example()}
        output = ROOT / 'test/corpus/output/editing/features.json'
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + '\n')
        print('PdfCore editing features: QPDF, Unicode extraction and 2 Poppler pages match', flush=True)


if __name__ == '__main__':
    main()
