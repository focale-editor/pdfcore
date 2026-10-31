import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:test/test.dart';

/// Verifies font encoding without assuming Unicode strings are glyph bytes.
void main() {
  test('StandardEncoding supplies the base when a standard Type 1 has only Differences', () {
    final PdfFont font = PdfFont.read(
      document: PdfDocument.fromPages(pages: []),
      value: PdfDictionary(
        values: {
          'Subtype': PdfName(value: 'Type1'),
          'BaseFont': PdfName(value: 'Times-Roman'),
          'Encoding': PdfDictionary(
            values: {
              'Differences': PdfArray(
                values: [
                  PdfNumber(value: 233),
                  PdfName(value: 'eacute'),
                ],
              ),
            },
          ),
        },
      ),
    );
    check(font.decode([65, 233, 39, 96])).equals('Aé’‘');
    check(PdfFont.unicodeForGlyph('Aacute')).equals('Á');
    check(PdfFont.unicodeForGlyph('f_f_i.alt')).equals('ffi');
    check(PdfFont.unicodeForGlyph('a0')).isNull();
    check(PdfFont.unicodeForGlyph('UnknownGlyph')).isNull();
  });

  test('WinAnsi preserves accented text punctuation and euro characters', () {
    final PdfFont font = PdfFont.read(
      document: PdfDocument.fromPages(pages: []),
      value: PdfResources.standardFont(),
    );
    check(font.decode([0xc9, 0x74, 0xe9, 0x20, 0x80, 0x20, 0x93, 0x41, 0x94])).equals('Été € “A”');
    check(font.encode('Été € “A”')).deepEquals([0xc9, 0x74, 0xe9, 0x20, 0x80, 0x20, 0x93, 0x41, 0x94]);
    check(() => font.encode('漢')).throws<PdfUnsupportedException>();
  });

  test('ToUnicode supports bfchar bfrange arrays ligatures and surrogate pairs', () {
    final PdfFont font = _mapped('''
      1 begincodespacerange <0000> <ffff> endcodespacerange
      2 beginbfchar <0001> <00660069> <0002> <d83dde00> endbfchar
      2 beginbfrange <0003> <0005> <0041> <0006> <0007> [<00e9> <20ac>] endbfrange
    ''');
    check(font.decode([0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7])).equals('fi😀ABCé€');
    check(font.encode('fi😀ABCé€')).deepEquals([0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7]);
  });

  test('four-byte code spaces do not expand into billions of mappings', () {
    final PdfFont font = _mapped('1 begincodespacerange <00000000> <ffffffff> endcodespacerange 1 beginbfchar <ffffffff> <0041> endbfchar');
    check(font.decode([255, 255, 255, 255])).equals('A');
    check(font.decodeGlyphs([255, 255, 255, 255]).single.code).equals(0xffffffff);
  });

  test('glyph decoding preserves ligatures and duplicate Unicode source codes', () {
    final PdfFont font = _mapped('4 beginbfchar <0000> <0020> <0001> <00660069> <0002> <0041> <0003> <0041> endbfchar');
    final List<PdfDecodedGlyph> glyphs = font.decodeGlyphs([0, 0, 0, 1, 0, 3]);
    check(glyphs.map((glyph) => glyph.key).toList()).deepEquals(['0000', '0001', '0003']);
    check(glyphs.map((glyph) => glyph.text).toList()).deepEquals([' ', 'fi', 'A']);
    check(glyphs.map((glyph) => glyph.byteLength).toList()).deepEquals([2, 2, 2]);
    check(font.encode('A')).deepEquals([0, 2]);
    check(() => font.decodeGlyphs([0])).throws<PdfUnsupportedException>();
    check(() => font.decodeGlyphs([256])).throws<FormatException>();
    check(glyphs.clear).throws<UnsupportedError>();
  });

  test('variable-length mappings retain code lengths', () {
    final PdfFont font = _mapped('2 beginbfchar <01> <0041> <8102> <0042> endbfchar');
    check(font.decode([1, 129, 2])).equals('AB');
    check(font.encode('BA')).deepEquals([129, 2, 1]);
  });

  test('ligature encoding finds a complete segmentation instead of greedy failure', () {
    final PdfFont font = PdfFont(dictionary: PdfDictionary(), mappings: {'01': 'ab', '02': 'a', '03': 'bc'});
    check(font.encode('abc')).deepEquals([2, 3]);
    check(font.encode('')).isEmpty();
  });

  test('Differences remove unsupported glyph names rather than keep a wrong base glyph', () {
    final PdfFont font = PdfFont.read(
      document: PdfDocument.fromPages(pages: []),
      value: PdfDictionary(
        values: {
          'Subtype': PdfName(value: 'Type1'),
          'Encoding': PdfDictionary(
            values: {
              'BaseEncoding': PdfName(value: 'WinAnsiEncoding'),
              'Differences': PdfArray(
                values: [
                  PdfNumber(value: 65),
                  PdfName(value: 'uni03A9'),
                  PdfName(value: 'UnknownGlyph'),
                ],
              ),
            },
          ),
        },
      ),
    );
    check(font.decode([65, 67])).equals('ΩC');
    check(() => font.decode([66])).throws<PdfUnsupportedException>();
    check(() => font.encode('A')).throws<PdfUnsupportedException>();
  });

  for (final String cmap in [
    '1 beginbfchar <00> <d800> endbfchar',
    '1 beginbfchar <00> <dc00> endbfchar',
    '1 beginbfchar <00> <00> endbfchar',
    '1 beginbfrange <01> <03> [<0041>] endbfrange',
    '1 beginbfrange <01> <00> <0041> endbfrange',
    '1 beginbfrange <01> <03> <ffff> endbfrange',
  ]) {
    test('malformed Unicode mapping fails: $cmap', () {
      check(() => _mapped(cmap)).throws<FormatException>();
    });
  }

  test('inherited CMaps require a host mapping', () {
    check(() => _mapped('/OtherMap usecmap')).throws<PdfUnsupportedException>();
    check(() => _mapped('1 beginbfchar <00> <0041> endbfchar', inherited: true)).throws<PdfUnsupportedException>();
  });

  test('CMap expansion is bounded and prefix ambiguity is explicit', () {
    check(() => _mapped('1 beginbfrange <0000> <ffff> <0000> endbfrange', limits: const PdfLimits(maxObjects: 10))).throws<FormatException>();
    check(() => _mapped('2 beginbfchar <01> <0041> <0102> <0042> endbfchar')).throws<PdfUnsupportedException>();
  });

  test('composite font without ToUnicode never guesses Latin-1', () {
    check(
      () => PdfFont.read(
        document: PdfDocument.fromPages(pages: []),
        value: PdfDictionary(values: {'Subtype': PdfName(value: 'Type0')}),
      ),
    ).throws<PdfUnsupportedException>();
  });
}

/// Reads a separately authored ToUnicode program through an indirect stream.
PdfFont _mapped(String content, {PdfLimits limits = const PdfLimits(), bool inherited = false}) {
  final PdfDocument document = PdfDocument(
    objects: {
      const PdfReference(objectNumber: 1): PdfStream(
        dictionary: PdfDictionary(values: {if (inherited) 'UseCMap': PdfName(value: 'Identity-H')}),
        data: ascii.encode('/CIDInit /ProcSet findresource begin 12 dict begin begincmap $content endcmap end end'),
      ),
    },
    trailer: PdfDictionary(),
    limits: limits,
  );
  return PdfFont.read(
    document: document,
    value: PdfDictionary(
      values: {
        'Subtype': PdfName(value: 'Type0'),
        'ToUnicode': const PdfReference(objectNumber: 1),
      },
    ),
  );
}
