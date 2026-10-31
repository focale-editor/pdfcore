import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

/// Creates an encoded stream fixture with direct filter parameters.
PdfStream filtered(String name, List<int> bytes, {PdfDictionary? parameters}) => PdfStream(
  dictionary: PdfDictionary(
    values: {
      'Filter': PdfName(value: name),
      'DecodeParms': ?parameters,
    },
  ),
  data: bytes,
);

/// Packs fixed-width LZW codes independently for short decoder fixtures.
Uint8List lzwCodes(List<int> codes) {
  final List<int> bits = [
    for (final int code in codes)
      for (int bit = 8; bit >= 0; bit--) (code >> bit) & 1,
  ];
  while (bits.length % 8 != 0) {
    bits.add(0);
  }
  return Uint8List.fromList([for (int index = 0; index < bits.length; index += 8) bits.sublist(index, index + 8).fold(0, (value, bit) => value * 2 + bit)]);
}

/// Checks standard PDF filters, predictors and graphics operation syntax.
void main() {
  test('encodes ASCII85 standard vectors, partial groups and bounded output', () {
    check(latin1.decode(PdfFilters.encodeAscii85(bytes: latin1.encode('Hello world!')))).equals('87cURD]j7BEbo80~>');
    check(latin1.decode(PdfFilters.encodeAscii85(bytes: [0, 0, 0, 0]))).equals('z~>');
    check(latin1.decode(PdfFilters.encodeAscii85(bytes: [255, 255, 255, 255]))).equals('s8W-!~>');
    for (int length = 0; length <= 257; length++) {
      final List<int> bytes = List.generate(length, (index) => index % 256);
      check(PdfFilters.decode(filtered('A85', PdfFilters.encodeAscii85(bytes: bytes)))).deepEquals(bytes);
    }
    check(() => PdfFilters.encodeAscii85(bytes: [256])).throws<FormatException>();
    check(() => PdfFilters.encodeAscii85(bytes: [], limits: const PdfLimits(maxStreamBytes: 1))).throws<FormatException>();
    check(() => PdfFilters.encodeAscii85(bytes: [255, 255, 255, 255], limits: const PdfLimits(maxStreamBytes: 6))).throws<FormatException>();
  });

  test('decodes Flate using ZCodec with a bounded output', () {
    final List<int> content = utf8.encode('vector data ' * 100);
    final PdfStream stream = filtered('FlateDecode', const ZlibEncoder().convert(content));
    check(PdfFilters.decode(stream)).deepEquals(content);
    check(() => PdfFilters.decode(stream, limits: const PdfLimits(maxStreamBytes: 20))).throws<FormatException>();
  });

  test('decodes ASCIIHex whitespace and odd nibble', () {
    check(PdfFilters.decode(filtered('ASCIIHexDecode', latin1.encode('61 62\n6>')))).deepEquals([97, 98, 96]);
    check(() => PdfFilters.decode(filtered('ASCIIHexDecode', latin1.encode('61')))).throws<FormatException>();
    check(() => PdfFilters.decode(filtered('ASCIIHexDecode', latin1.encode('GG>')))).throws<FormatException>();
  });

  test('decodes ASCII85 complete, partial and zero groups', () {
    check(latin1.decode(PdfFilters.decode(filtered('ASCII85Decode', latin1.encode('87cURD]j7BEbo80~>'))))).equals('Hello world!');
    check(PdfFilters.decode(filtered('A85', latin1.encode('z~>')))).deepEquals([0, 0, 0, 0]);
    check(() => PdfFilters.decode(filtered('A85', latin1.encode('!~>')))).throws<FormatException>();
    check(() => PdfFilters.decode(filtered('A85', latin1.encode('uuuuu~>')))).throws<FormatException>();
  });

  test('decodes literal and repeated RunLength packets', () {
    check(PdfFilters.decode(filtered('RunLengthDecode', [2, 65, 66, 67, 254, 88, 128]))).deepEquals([65, 66, 67, 88, 88, 88]);
    check(() => PdfFilters.decode(filtered('RunLengthDecode', [0]))).throws<FormatException>();
    check(() => PdfFilters.decode(filtered('RunLengthDecode', [129, 42, 128]), limits: const PdfLimits(maxStreamBytes: 10))).throws<FormatException>();
  });

  test('decodes LZW clear, dictionary lookup and KwKwK', () {
    check(PdfFilters.decode(filtered('LZWDecode', lzwCodes([256, 65, 66, 258, 257])))).deepEquals([65, 66, 65, 66]);
    check(PdfFilters.decode(filtered('LZWDecode', lzwCodes([256, 65, 258, 257])))).deepEquals([65, 65, 65]);
    check(() => PdfFilters.decode(filtered('LZWDecode', lzwCodes([256, 300, 257])))).throws<FormatException>();
  });

  for (final int filter in [0, 1, 2, 3, 4]) {
    test('decodes PNG predictor filter $filter', () {
      const List<int> first = [10, 20, 30];
      const List<int> second = [15, 35, 60];
      final List<List<int>> encoded = [
        [15, 35, 60],
        [15, 20, 25],
        [5, 15, 30],
        [10, 18, 28],
        [5, 15, 25],
      ];
      final PdfDictionary parameters = PdfDictionary(values: {'Predictor': PdfNumber(value: 15), 'Columns': PdfNumber(value: 3)});
      final PdfStream stream = filtered('FlateDecode', const ZlibEncoder().convert([0, ...first, filter, ...encoded[filter]]), parameters: parameters);
      check(PdfFilters.decode(stream)).deepEquals([...first, ...second]);
    });
  }

  for (final int bits in [1, 2, 4, 8, 16]) {
    test('decodes TIFF horizontal differences at $bits bits', () {
      final List<int> encoded = switch (bits) {
        1 => [0xe0],
        2 => [0x54],
        4 => [0x11, 0x10],
        8 => [1, 1, 1],
        _ => [0, 1, 0, 1, 0, 1],
      };
      final List<int> expected = switch (bits) {
        1 => [0xa0],
        2 => [0x6c],
        4 => [0x12, 0x30],
        8 => [1, 2, 3],
        _ => [0, 1, 0, 2, 0, 3],
      };
      final PdfDictionary parameters = PdfDictionary(
        values: {
          'Predictor': PdfNumber(value: 2),
          'Columns': PdfNumber(value: 3),
          'BitsPerComponent': PdfNumber(value: bits),
        },
      );
      check(PdfFilters.decode(filtered('FlateDecode', const ZlibEncoder().convert(encoded), parameters: parameters))).deepEquals(expected);
    });
  }

  test('resolves filter arrays and indirect parameters through the document', () {
    final PdfDictionary parameters = PdfDictionary(values: {'Predictor': PdfNumber(value: 1)});
    final PdfStream stream = PdfStream(
      dictionary: PdfDictionary(
        values: {
          'Filter': PdfArray(
            values: [
              const PdfReference(objectNumber: 10),
              PdfName(value: 'FlateDecode'),
            ],
          ),
          'DecodeParms': PdfArray(values: [const PdfNull(), const PdfReference(objectNumber: 11)]),
        },
      ),
      data: latin1.encode('${const ZlibEncoder().convert([1, 2, 3]).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}>'),
    );
    final PdfDocument document = PdfDocument(
      objects: {
        const PdfReference(objectNumber: 10): PdfName(value: 'ASCIIHexDecode'),
        const PdfReference(objectNumber: 11): parameters,
      },
      trailer: PdfDictionary(),
    );
    check(document.decodeStream(stream)).deepEquals([1, 2, 3]);
  });

  test('rejects external streams and unsupported filters explicitly', () {
    check(
      () => PdfFilters.decode(
        PdfStream(
          dictionary: PdfDictionary(values: {'F': PdfString.text(text: '/tmp/external')}),
          data: [],
        ),
      ),
    ).throws<PdfUnsupportedException>();
    check(() => PdfFilters.decode(filtered('JPXDecode', []))).throws<PdfUnsupportedException>();
  });

  test('reads and writes graphics operations, names and text arrays', () {
    final List<PdfOperation> operations = PdfContent.decode(latin1.encode('q 1 0 0 1 5.5 -4 cm /F1 12 Tf [(Hello) -20 <776f726c64>] TJ Q'));
    check(operations.map((operation) => operation.operator)).deepEquals(['q', 'cm', 'Tf', 'TJ', 'Q']);
    check(PdfContent.decode(PdfContent.encode(operations)).length).equals(5);
  });

  test('content parser rejects underspecified inline images and dangling operands', () {
    check(() => PdfContent.decode(latin1.encode('BI /W 1 /H 1 ID x EI'))).throws<PdfUnsupportedException>();
    check(() => PdfContent.decode(latin1.encode('1 2'))).throws<FormatException>();
    check(() => PdfOperation(operator: 'q /Inject')).throws<FormatException>();
  });
}
