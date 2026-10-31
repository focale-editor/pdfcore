import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:test/test.dart';

import 'pdf_fixtures.dart';

/// Verifies grouped rollback and direct-page attribute inheritance.
void main() {
  test('failed operations and transaction groups publish no partial snapshot', () {
    final PdfEditor editor = PdfEditor(document: _shared());
    final PdfDocument before = editor.document;
    check(
      () => editor.transaction((edit) {
        edit.setInformation(values: {'Title': PdfString.text(text: 'Changed')});
        edit.movePage(from: 0, to: 99);
      }),
    ).throws<RangeError>();
    check(identical(editor.document, before)).isTrue();
    check(() => editor.setPageContent(pageIndex: 0, bytes: [256])).throws<FormatException>();
    check(identical(editor.document, before)).isTrue();
    check(() => editor.setPageAttributes(pageIndex: 0, values: {'Rotate': PdfNumber(value: 45)})).throws<FormatException>();
    check(identical(editor.document, before)).isTrue();
  });

  test('direct page materialization retains edited resources instead of inherited ones', () {
    final PdfDocument source = _shared();
    final PdfDictionary root = source.dictionary(source.catalog['Pages']!);
    final PdfDocument direct = source.copyWith(
      objects: {
        ...source.objects,
        const PdfReference(objectNumber: 2): root.copyWith(
          values: {
            'Kids': PdfArray(
              values: [
                source.pages.first.dictionary.copyWith(values: {'Rotate': PdfNumber(value: 180)}),
              ],
            ),
          },
        ),
      },
    );
    final PdfEditor rotation = PdfEditor(document: direct);
    rotation.setPageAttributes(pageIndex: 0, remove: {'Rotate'});
    check(rotation.document.pages.single.inherited.integer('Rotate')).equals(90);
    final PdfEditor editor = PdfEditor(document: direct);
    editor.setPageResource(
      pageIndex: 0,
      category: 'Font',
      name: 'F1',
      value: PdfResources.standardFont(baseFont: 'Courier'),
    );
    check((editor.pageResource(pageIndex: 0, category: 'Font', name: 'F1') as PdfDictionary).name('BaseFont')).equals('Courier');
    check(_reopen(editor.document).pages.single.reference).isNotNull();
  });
}

/// Reads a hand-authored shared-resource page tree, independent of the writer.
PdfDocument _shared() => const PdfCodec().decode(
  classicPdf(
    objects: {
      1: '<< /Type /Catalog /Pages 2 0 R >>',
      2: '<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 /MediaBox [0 0 200 100] /Resources 6 0 R /Rotate 90 >>',
      3: '<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Private /Keep >>',
      4: '<< /Length 3 >>\nstream\nq Q\nendstream',
      5: '<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>',
      6: '<< /Font << /F1 7 0 R >> /Private /Preserved >>',
      7: '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    },
  ),
);

/// Reopens output to exercise the public codec after editing.
PdfDocument _reopen(PdfDocument document) => const PdfCodec().decode(const PdfCodec().encode(document));
