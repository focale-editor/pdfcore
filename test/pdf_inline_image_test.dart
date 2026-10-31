import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

/// Wraps encoded image bytes with instructions before and after the image.
List<int> inline(String dictionary, List<int> data) => [...latin1.encode('q BI $dictionary ID\n'), ...data, ...latin1.encode('\nEI Q 1 w')];

/// Verifies filter-aware binary boundaries and image edit round trips.
void main() {
  test('inline image construction rejects values outside the byte range', () {
    check(() => PdfInlineImage(dictionary: PdfDictionary(), data: [256])).throws<FormatException>();
    check(() => PdfInlineImage(dictionary: PdfDictionary(), data: [-1])).throws<FormatException>();
  });

  test('unfiltered binary image can contain whitespace EI whitespace bytes', () {
    final List<int> data = latin1.encode(' EI ');
    final List<PdfOperation> operations = PdfContent.decode(inline('/W 4 /H 1 /BPC 8 /CS /G', data));
    check(operations.map((operation) => operation.operator)).deepEquals(['q', 'BI', 'Q', 'w']);
    check(operations[1].inlineImage!.data).deepEquals(data);
    final List<PdfOperation> restored = PdfContent.decode(PdfContent.encode(operations));
    check(restored[1].inlineImage!.dictionary.name('ColorSpace')).equals('DeviceGray');
    check(restored[1].inlineImage!.toXObject().dictionary.name('Subtype')).equals('Image');
    check(restored[1].inlineImage!.data).deepEquals(data);
  });

  test('raw row lengths include packed sample padding per row', () {
    final List<PdfOperation> operations = PdfContent.decode(inline('/W 3 /H 2 /BPC 1 /CS /G', [0xa0, 0x40]));
    check(operations[1].inlineImage!.data).deepEquals([0xa0, 0x40]);
  });

  test('image masks default to one bit per sample', () {
    check(PdfContent.decode(inline('/W 9 /H 1 /IM true', [128, 0]))[1].inlineImage!.data.length).equals(2);
  });

  test('ID consumes exactly one delimiter including leading newline sample', () {
    final List<PdfOperation> operations = PdfContent.decode(inline('/W 1 /H 1 /BPC 8 /CS /G', [10]));
    check(operations[1].inlineImage!.data).deepEquals([10]);
  });

  test('Flate uses ZCodec consumed prefix and validates its checksum', () {
    final List<int> data = const ZlibEncoder(level: 0).convert(latin1.encode(' EI '));
    final List<PdfOperation> operations = PdfContent.decode(inline('/W 4 /H 1 /BPC 8 /CS /G /F /Fl', data));
    check(PdfFilters.decode(operations[1].inlineImage!.toXObject())).deepEquals(latin1.encode(' EI '));
    final List<int> bad = [...data]..[data.length - 1] ^= 1;
    check(() => PdfContent.decode(inline('/W 4 /H 1 /BPC 8 /CS /G /F /Fl', bad))).throws<FormatException>();
  });

  for (final (String filter, List<int> data, List<int> expected) in [
    ('/AHx', latin1.encode('20454920>'), latin1.encode(' EI ')),
    ('/A85', latin1.encode('z~>'), [0, 0, 0, 0]),
    ('/RL', [3, ...latin1.encode(' EI '), 128], latin1.encode(' EI ')),
  ]) {
    test('finds the exact outer $filter filter boundary', () {
      final PdfInlineImage image = PdfContent.decode(inline('/W 4 /H 1 /BPC 8 /CS /G /F $filter', data))[1].inlineImage!;
      check(PdfFilters.decode(image.toXObject())).deepEquals(expected);
    });
  }

  test('LZW inline boundaries use end codes, including binary EI samples', () {
    final List<int> codes = [256, 32, 69, 73, 32, 257];
    final List<int> bits = [
      for (final int code in codes)
        for (int shift = 8; shift >= 0; shift--) (code >> shift) & 1,
    ];
    final List<int> bytes = [
      for (int offset = 0; offset < bits.length; offset += 8)
        [
          for (int bit = 0; bit < 8; bit++)
            if (offset + bit < bits.length) bits[offset + bit] else 0,
        ].fold(0, (value, bit) => value * 2 + bit),
    ];
    final PdfInlineImage image = PdfContent.decode(inline('/W 4 /H 1 /BPC 8 /CS /G /F /LZW', bytes))[1].inlineImage!;
    check(image.data).deepEquals(bytes);
    check(PdfFilters.decode(image.toXObject())).deepEquals(latin1.encode(' EI '));
  });

  test('JPEG EOI inside an APP segment is not the end of the image', () {
    final List<int> jpeg = [255, 216, 255, 224, 0, 6, 255, 217, 0, 0, 255, 218, 0, 2, 0, 255, 0, 12, 255, 217];
    final PdfInlineImage image = PdfContent.decode(inline('/W 1 /H 1 /BPC 8 /CS /RGB /F /DCT', jpeg))[1].inlineImage!;
    check(image.data).deepEquals(jpeg);
  });

  test('named color spaces resolve through resources without recursion loops', () {
    final PdfDictionary spaces = PdfDictionary(
      values: {
        'Custom': PdfArray(
          values: [
            PdfName(value: 'Indexed'),
            PdfName(value: 'DeviceRGB'),
            PdfNumber(value: 1),
            PdfString(bytes: [0, 0, 0, 255, 255, 255]),
          ],
        ),
      },
    );
    check(PdfContent.decode(inline('/W 2 /H 1 /BPC 8 /CS /Custom', [0, 1]), colorSpaces: spaces)[1].inlineImage!.data).deepEquals([0, 1]);
    final PdfDictionary cyclic = PdfDictionary(values: {'Custom': PdfName(value: 'Custom')});
    check(() => PdfContent.decode(inline('/W 2 /H 1 /BPC 8 /CS /Custom', [0, 1]), colorSpaces: cyclic, limits: const PdfLimits(maxDepth: 3))).throws<FormatException>();
  });

  test('inline Flate sample expansion has an aggregate budget', () {
    final List<int> data = const ZlibEncoder().convert(List.filled(1000, 0));
    final List<int> one = inline('/W 1000 /H 1 /BPC 8 /CS /G /F /Fl', data);
    check(() => PdfContent.decode([...one, 32, ...one], limits: const PdfLimits(maxStreamBytes: 10000, maxDecodedBytes: 1500))).throws<FormatException>();
  });

  test('content writers reject indirect references inside nested operands', () {
    check(
      () => PdfContent.encode([
        PdfOperation(
          operator: 'BDC',
          operands: [
            PdfName(value: 'Tag'),
            PdfDictionary(values: {'Invalid': const PdfReference(objectNumber: 1)}),
          ],
        ),
      ]),
    ).throws<FormatException>();
  });

  test('truncation, duplicate aliases, unknown filters and budgets are explicit', () {
    check(() => PdfContent.decode(inline('/W 100 /H 1 /BPC 8 /CS /G', [1]))).throws<FormatException>();
    check(() => PdfContent.decode(inline('/W 1 /Width 1 /H 1 /BPC 8 /CS /G', [1]))).throws<FormatException>();
    check(() => PdfContent.decode(inline('/W 1 /H 1 /BPC 8 /CS /G /F /Mystery', [1]))).throws<PdfUnsupportedException>();
    check(() => PdfContent.decode(inline('/W 9007199254740991 /H 8 /BPC 16 /CS /CMYK', []))).throws<FormatException>();
    check(() => PdfContent.decode(latin1.encode('ID x EI'))).throws<FormatException>();
    check(() => PdfContent.decode([256])).throws<FormatException>();
  });
}
