import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:test/test.dart';

import 'pdf_fixtures.dart';

/// Tests PDF graph ownership, cross references, editing and bounded failures.
void main() {
  test('duplicate-key compatibility is explicit, selective and canonical on rewrite', () {
    final Uint8List bytes = classicPdf(
      objects: {
        1: '<< /Type /Catalog /Pages 2 0 R /Group << /K true >> /Group << /K false >> >>',
        2: '<< /Type /Pages /Kids [] /Count 0 >>',
      },
    );
    check(() => const PdfCodec().decode(bytes)).throws<FormatException>();
    final PdfDocument document = const PdfCodec(duplicateKeys: {'Group'}).decode(bytes);
    check((document.dictionary(document.catalog['Group']!)['K'] as PdfBoolean).value).isFalse();
    check(const PdfCodec().decode(const PdfCodec().encode(document)).pages).isEmpty();
    final Uint8List other = classicPdf(
      objects: {
        1: '<< /Type /Catalog /Pages 2 0 R /Pages 2 0 R >>',
        2: '<< /Type /Pages /Kids [] /Count 0 >>',
      },
    );
    check(() => const PdfCodec(duplicateKeys: {'Group'}).decode(other)).throws<FormatException>();
  });

  test('reads independently authored classic xrefs and indirect stream length', () {
    final PdfDocument document = const PdfCodec().decode(classicPdf());
    check(document.pages.length).equals(1);
    check(latin1.decode(document.pageContent(document.pages.single))).equals('q\nQ\n');
    check((document.pages.single.inherited['MediaBox']! as PdfArray).values.length).equals(4);
  });

  for (final bool hybrid in [false, true]) {
    for (final bool stale in [false, true]) {
      test('reads compressed objects: hybrid=$hybrid, stale xref self-entry=$stale', () {
        final PdfDocument document = const PdfCodec().decode(compressedPdf(hybrid: hybrid, staleSelfEntry: stale));
        check(document.pages.length).equals(1);
        check(document.catalog.name('Type')).equals('Catalog');
        check(const PdfCodec().decode(const PdfCodec().encode(document)).pages.length).equals(1);
      });
    }
  }

  test('latest incremental objects replace previous versions', () {
    final Uint8List bytes = incrementalPdf(original: classicPdf(), replacements: {4: '<< /Length 4 >>\nstream\nq Q\n\nendstream'});
    final PdfDocument document = const PdfCodec().decode(bytes);
    check(latin1.decode(document.pageContent(document.pages.single))).equals('q Q\n');
    check(const PdfCodec().decode(const PdfCodec().encode(document)).pages.length).equals(1);
  });

  test('free entries shadow live objects in older revisions', () {
    final Uint8List bytes = incrementalPdf(original: classicPdf(), replacements: {4: '<< /Length 4 >>\nstream\nq Q\n\nendstream'}, freed: {5});
    final PdfDocument document = const PdfCodec().decode(bytes);
    check(document.objects.containsKey(const PdfReference(objectNumber: 5))).isFalse();
  });

  test('preserves unknown dictionaries, names, strings and encoded image streams', () {
    final PdfDocument original = const PdfCodec().decode(classicPdf());
    final PdfStream opaque = PdfStream(
      dictionary: PdfDictionary(
        values: {
          'Filter': PdfName(value: 'DCTDecode'),
          'Author/Key#': PdfString(bytes: [0, 255, 10]),
        },
      ),
      data: [255, 216, 255, 217],
    );
    final PdfDocument extended = original.copyWith(objects: {...original.objects, const PdfReference(objectNumber: 50, generation: 3): opaque});
    final PdfDocument reopened = const PdfCodec().decode(const PdfCodec().encode(extended));
    final PdfStream restored = reopened.objects[const PdfReference(objectNumber: 50, generation: 3)]! as PdfStream;
    check(restored.data).deepEquals(opaque.data);
    check((restored.dictionary['Author/Key#']! as PdfString).bytes).deepEquals([0, 255, 10]);
    check(() => reopened.decodeStream(restored)).throws<PdfUnsupportedException>();
  });

  test('creates and edits multipage vector documents', () {
    final PdfDocument document = PdfDocument.fromPages(
      pages: [
        PdfPageSource(width: 200, height: 100, content: latin1.encode('1 0 0 rg 10 10 80 60 re f')),
        PdfPageSource(width: 100, height: 200, content: latin1.encode('0 0 1 RG 1 w 0 0 m 30 40 l S')),
      ],
    );
    final PdfDocument reopened = const PdfCodec().decode(const PdfCodec().encode(document));
    check(reopened.pages.length).equals(2);
    check(PdfContent.decode(reopened.pageContent(reopened.pages.first)).last.operator).equals('f');
    final PdfDocument replacement = reopened.copyWith(
      objects: {
        ...reopened.objects,
        const PdfReference(objectNumber: 4): PdfStream(dictionary: PdfDictionary(), data: latin1.encode('q Q')),
      },
    );
    check(latin1.decode(const PdfCodec().decode(const PdfCodec().encode(replacement)).pageContent(replacement.pages.first))).equals('q Q');
  });

  test('copies mutable inputs and exposes read-only snapshots', () {
    final Uint8List bytes = Uint8List.fromList([1, 2, 3]);
    final PdfString string = PdfString(bytes: bytes);
    final PdfStream stream = PdfStream(dictionary: PdfDictionary(), data: bytes);
    bytes[0] = 99;
    check(string.bytes.first).equals(1);
    check(stream.data.first).equals(1);
    check(() => string.bytes[0] = 8).throws<UnsupportedError>();
    final List<PdfValue> values = [const PdfNull()];
    final PdfArray array = PdfArray(values: values);
    values.clear();
    check(array.values.length).equals(1);
  });

  test('supports Unicode PDF text and PDFDocEncoding', () {
    check(PdfString.text(text: 'Café 😀').text).equals('Café 😀');
    check(PdfString(bytes: [0x80, 0xa0, 0x93]).text).equals('•€ﬁ');
    check(PdfString(bytes: [239, 187, 191, ...utf8.encode('été')]).text).equals('été');
  });

  test('parses real numbers next to integers without mistaking references', () {
    final PdfDocument document = const PdfCodec().decode(classicPdf(trailer: '/Numbers [0 1.5 2 3.25 -1 +2 .5 1.]'));
    final PdfArray numbers = document.trailer['Numbers']! as PdfArray;
    check(numbers.values.map((value) => (value as PdfNumber).value)).deepEquals([0, 1.5, 2, 3.25, -1, 2, .5, 1]);
  });

  test('retains pre-1.2 literal hash names and upgrades canonical output', () {
    final PdfDocument document = const PdfCodec().decode(classicPdf(version: '1.1', trailer: '/Hash /a#20b /Bare /#'));
    check(document.trailer.name('Hash')).equals('a#20b');
    final PdfDocument reopened = const PdfCodec().decode(const PdfCodec().encode(document));
    check(reopened.version).equals('1.2');
    check(reopened.trailer.name('Hash')).equals('a#20b');
    check(reopened.trailer.name('Bare')).equals('#');
  });

  test('literal strings handle nesting, octal escapes and line continuation', () {
    final PdfDocument document = const PdfCodec().decode(classicPdf(trailer: '/Text (a(b)\\040c\\\r\nd\r\ne) /Hex <A B C>'));
    check((document.trailer['Text']! as PdfString).text).equals('a(b) cd\ne');
    check((document.trailer['Hex']! as PdfString).bytes).deepEquals([171, 192]);
  });

  test('writes tiny finite numbers without unsupported exponent notation', () {
    final PdfDocument document = const PdfCodec().decode(classicPdf());
    final PdfDocument changed = document.copyWith(trailer: document.trailer.copyWith(values: {'Small': PdfNumber(value: 1e-20)}));
    final PdfDocument reopened = const PdfCodec().decode(const PdfCodec().encode(changed));
    check((reopened.trailer['Small']! as PdfNumber).value).equals(1e-20);
  });

  test('removes obsolete linearization and revision pointers when writing', () {
    final PdfDocument document = const PdfCodec().decode(classicPdf());
    final PdfDocument changed = document.copyWith(
      objects: {
        ...document.objects,
        const PdfReference(objectNumber: 10): PdfDictionary(values: {'Linearized': PdfNumber(value: 1)}),
      },
    );
    final PdfDocument reopened = const PdfCodec().decode(const PdfCodec().encode(changed));
    check((reopened.objects[const PdfReference(objectNumber: 10)]! as PdfDictionary)['Linearized']).isNull();
    check(reopened.trailer['Prev']).isNull();
  });

  test('rejects encrypted documents explicitly', () {
    check(() => const PdfCodec().decode(classicPdf(trailer: '/Encrypt << /Filter /Standard >>'))).throws<PdfUnsupportedException>();
  });

  test('rejects broken xref offsets instead of scanning for object-like bytes', () {
    final String source = latin1.decode(classicPdf());
    final Uint8List broken = latin1.encode(source.replaceFirst('0000000009 00000 n', '0000000010 00000 n'));
    check(() => const PdfCodec().decode(broken)).throws<FormatException>();
  });

  test('rejects page-tree cycles', () {
    final Uint8List bytes = classicPdf(objects: {1: '<< /Type /Catalog /Pages 2 0 R >>', 2: '<< /Type /Pages /Kids [2 0 R] /Count 1 >>'});
    check(() => const PdfCodec().decode(bytes)).throws<FormatException>();
  });

  test('rejects length-reference cycles and truncated streams', () {
    final Uint8List bytes = classicPdf(objects: {1: '<< /Type /Catalog /Pages 2 0 R >>', 2: '<< /Type /Pages /Kids [] /Count 0 >>', 4: '<< /Length 4 0 R >>\nstream\nx\nendstream'});
    check(() => const PdfCodec().decode(bytes)).throws<FormatException>();
    check(() => const PdfCodec().decode(classicPdf(objects: {1: '<< /Length 99999 >>\nstream\nx\nendstream'}))).throws<FormatException>();
  });

  test('enforces file, graph, nesting and aggregate structural budgets', () {
    check(() => const PdfCodec(limits: PdfLimits(maxFileBytes: 10)).decode(classicPdf())).throws<FormatException>();
    check(() => const PdfCodec(limits: PdfLimits(maxObjects: 2)).decode(classicPdf())).throws<FormatException>();
    check(() => const PdfCodec(limits: PdfLimits(maxDepth: 3)).decode(classicPdf(trailer: '/Nested [[[[[0]]]]]'))).throws<FormatException>();
    check(() => const PdfCodec(limits: PdfLimits(maxDecodedBytes: 10)).decode(compressedPdf())).throws<FormatException>();
    check(() => const PdfCodec(limits: PdfLimits(maxDepth: 0)).decode(classicPdf())).throws<ArgumentError>();
  });

  test('rejects duplicate dictionary keys, invalid values and missing EOF', () {
    check(() => const PdfCodec().decode(classicPdf(trailer: '/X 1 /X 2'))).throws<FormatException>();
    check(() => const PdfCodec().decode(classicPdf(trailer: '/X nan'))).throws<FormatException>();
    final Uint8List bytes = classicPdf();
    check(() => const PdfCodec().decode(bytes.sublist(0, bytes.length - 10))).throws<FormatException>();
  });

  test('supports empty documents and standard codec composition', () {
    final PdfDocument empty = PdfDocument.fromPages(pages: []);
    final Codec<PdfDocument, String> codec = const PdfCodec().fuse(base64);
    check(codec.decode(codec.encode(empty)).pages).isEmpty();
  });

  test('reference traversal detects cycles without stack overflow', () {
    final PdfDocument document = PdfDocument(
      objects: {const PdfReference(objectNumber: 1): const PdfReference(objectNumber: 2), const PdfReference(objectNumber: 2): const PdfReference(objectNumber: 1)},
      trailer: PdfDictionary(),
    );
    check(() => document.resolve(const PdfReference(objectNumber: 1))).throws<FormatException>();
  });

  test('writer rejects invalid identifiers and direct streams in dictionaries', () {
    final PdfDocument document = PdfDocument.fromPages(pages: []);
    check(() => const PdfCodec().encode(document.copyWith(objects: {...document.objects, const PdfReference(objectNumber: 0): const PdfNull()}))).throws<FormatException>();
    check(
      () => const PdfCodec().encode(
        document.copyWith(
          trailer: document.trailer.copyWith(
            values: {'DirectStream': PdfStream(dictionary: PdfDictionary(), data: [])},
          ),
        ),
      ),
    ).throws<FormatException>();
  });
  test('undefined references are PDF null and deleted content stays absent', () {
    final PdfDocument document = const PdfCodec().decode(incrementalPdf(original: classicPdf(), freed: {4}));
    check(document.resolve(const PdfReference(objectNumber: 4))).isA<PdfNull>();
    check(document.pageContent(document.pages.single)).isEmpty();
    final PdfDocument reopened = const PdfCodec().decode(const PdfCodec().encode(document));
    check(reopened.pageContent(reopened.pages.single)).isEmpty();
  });

  test('concatenates content bytes without changing split strings', () {
    final PdfDocument document = PdfDocument.fromPages(pages: [PdfPageSource(width: 10, height: 10, content: [])]);
    final PdfReference page = document.pages.single.reference!;
    final PdfDictionary dictionary = document.objects[page]! as PdfDictionary;
    final PdfDocument split = document.copyWith(
      objects: {
        ...document.objects,
        page: dictionary.copyWith(
          values: {
            'Contents': PdfArray(values: [const PdfReference(objectNumber: 4), const PdfReference(objectNumber: 5)]),
          },
        ),
        const PdfReference(objectNumber: 4): PdfStream(dictionary: PdfDictionary(), data: latin1.encode('(hel')),
        const PdfReference(objectNumber: 5): PdfStream(dictionary: PdfDictionary(), data: latin1.encode('lo) Tj')),
      },
    );
    check(latin1.decode(split.pageContent(split.pages.single))).equals('(hello) Tj');
  });

  test('rejects non-byte input instead of silently truncating it', () {
    check(() => const PdfCodec().decode([...classicPdf(), 256])).throws<FormatException>();
  });
}
