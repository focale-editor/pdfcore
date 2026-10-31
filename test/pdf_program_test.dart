import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:test/test.dart';

/// Builds a program using explicit WinAnsi Helvetica and Courier fonts.
PdfProgram program(String content) {
  final PdfDictionary resources = PdfDictionary(
    values: {
      'Font': PdfDictionary(
        values: {
          'F1': PdfResources.standardFont(),
          'F2': PdfResources.standardFont(baseFont: 'Courier'),
        },
      ),
    },
  );
  final PdfDocument document = PdfDocument.fromPages(
    pages: [PdfPageSource(width: 100, height: 100, content: latin1.encode(content), resources: resources)],
  );
  return PdfProgram.fromPage(document: document, pageIndex: 0);
}

/// Creates a font with an independently authored ToUnicode stream.
PdfFont cmap(String content, {PdfLimits limits = const PdfLimits()}) {
  const PdfReference mapping = PdfReference(objectNumber: 10);
  final PdfDictionary dictionary = PdfDictionary(
    values: {
      'Type': PdfName(value: 'Font'),
      'Subtype': PdfName(value: 'Type0'),
      'ToUnicode': mapping,
    },
  );
  final PdfDocument document = PdfDocument(
    objects: {mapping: PdfStream(dictionary: PdfDictionary(), data: latin1.encode(content))},
    trailer: PdfDictionary(),
    limits: limits,
  );
  return PdfFont.read(document: document, value: dictionary);
}

/// Checks geometry, text semantics, font maps and preservation of graphics state.
void main() {
  test('path editing preserves interleaved style, clipping and extension operators', () {
    final PdfProgram source = program('q 0 0 m 1 1 l 1 0 0 RG 2 2 l W* S BX /Custom 8 Unknown EX Q');
    final PdfProgram edited = source.withPath(pathIndex: 0, commands: PdfContent.decode(latin1.encode('10 10 20 20 re')), paintOperator: 'B*');
    check(edited.operations.map((operation) => operation.operator)).deepEquals(['q', 're', 'RG', 'W*', 'B*', 'BX', 'Unknown', 'EX', 'Q']);
    check(source.paths.single.commands.length).equals(3);
    check(edited.paths.single.commands.length).equals(1);
    check(PdfContent.decode(edited.encode()).length).equals(9);
  });

  test('path geometry rejects interleaved transforms instead of changing coordinates', () {
    final PdfProgram source = program('0 0 m 1 0 0 1 10 10 cm 1 1 l S');
    check(() => source.withPath(pathIndex: 0, commands: PdfContent.decode(latin1.encode('0 0 5 5 re')))).throws<PdfUnsupportedException>();
    check(() => program('0 m S').paths).throws<FormatException>();
    check(() => program('0 0 m').paths).throws<FormatException>();
  });

  test('text edits preserve font selection, matrices, rendering mode and quote spacing', () {
    final PdfProgram source = program('BT /F1 12 Tf 1 0 0 1 10 20 Tm 2 Tr [(Hello) -50 ( world)] TJ 2 1 (old) " ET');
    check(source.textRuns[0].text).equals('Hello world');
    final PdfProgram edited = source.withText(runIndex: 0, text: 'Édition €').withText(runIndex: 1, text: 'new');
    check(edited.textRuns[0].text).equals('Édition €');
    check(edited.textRuns[1].text).equals('new');
    check((edited.textRuns[1].operation.operands.first as PdfNumber).value).equals(2);
    check(edited.operations.map((operation) => operation.operator)).deepEquals(source.operations.map((operation) => operation.operator));
    check(source.textRuns[0].strings.length).equals(2);
    check(edited.textRuns[0].strings.length).equals(1);
    check(() => source.withText(runIndex: 0, text: '漢字')).throws<PdfUnsupportedException>();
  });

  test('an unchanged text edit preserves TJ kerning and original glyph codes', () {
    final PdfProgram source = program('BT /F1 12 Tf [(Hello) -50 ( world)] TJ ET');
    final PdfProgram unchanged = source.withText(runIndex: 0, text: 'Hello world');
    check(identical(unchanged.textRuns.single.operation, source.textRuns.single.operation)).isTrue();
    check(unchanged.encode()).deepEquals(source.encode());
  });

  test('q/Q restores text fonts and Tf survives between text objects', () {
    final PdfProgram source = program('BT /F1 12 Tf (a) Tj ET q BT /F2 10 Tf (b) Tj ET Q BT (c) Tj ET');
    check(source.textRuns.map((run) => run.fontName)).deepEquals(['F1', 'F2', 'F1']);
    check(() => program('BT (a) Tj').textRuns).throws<FormatException>();
    check(() => program('(a) Tj').textRuns).throws<FormatException>();
    check(() => program('Q').textRuns).throws<FormatException>();
  });

  test('text without a known font remains editable as encoded bytes', () {
    final PdfProgram source = program('BT /Absent 12 Tf <aabb> Tj ET');
    check(source.textRuns.single.strings.single.bytes).deepEquals([0xaa, 0xbb]);
    check(() => source.textRuns.single.text).throws<FormatException>();
    final PdfProgram edited = source.withEncodedText(operationIndex: 2, bytes: [0xcc]);
    check(edited.textRuns.single.strings.single.bytes).deepEquals([0xcc]);
    check(() => source.withEncodedText(operationIndex: 2, bytes: [256])).throws<FormatException>();
  });

  test('ToUnicode reads single codes, array ranges, ligatures and supplementary text', () {
    final PdfFont font = cmap('''
/CIDInit /ProcSet findresource begin 12 dict begin begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Test def /CMapType 2 def
1 begincodespacerange <0000> <ffff> endcodespacerange
2 beginbfchar <0001> <00660069> <0002> <d83dde00> endbfchar
1 beginbfrange <0010> <0012> [<0041> <0042> <0043>] endbfrange
1 beginbfrange <0020> <0022> <0061> endbfrange
endcmap CMapName currentdict /CMap defineresource pop end end
''');
    check(font.decode([0, 1, 0, 2, 0, 16, 0, 17, 0, 18, 0, 32, 0, 33, 0, 34])).equals('fi😀ABCabc');
    check(font.encode('fi😀Cab')).deepEquals([0, 1, 0, 2, 0, 18, 0, 32, 0, 33]);
    check(() => font.encode('missing')).throws<PdfUnsupportedException>();
  });

  test('ToUnicode accepts unambiguous mixed-width codes and full 32-bit codes', () {
    final PdfFont font = cmap('3 beginbfchar <01> <0041> <8101> <0042> <ffffffff> <0043> endbfchar');
    check(font.decode([1, 129, 1, 255, 255, 255, 255])).equals('ABC');
    check(font.encode('CAB')).deepEquals([255, 255, 255, 255, 1, 129, 1]);
    check(() => cmap('2 beginbfchar <01> <0041> <0101> <0042> endbfchar')).throws<PdfUnsupportedException>();
  });

  test('font encoding uses a valid ligature segmentation instead of greedy loss', () {
    final PdfFont font = PdfFont(dictionary: PdfDictionary(), mappings: {'01': 'ab', '02': 'a', '03': 'bc', '04': 'a'});
    check(font.encode('abc')).deepEquals([2, 3]);
    check(font.encode('a')).deepEquals([2]);
    check(font.encode('')).isEmpty();
    check(() => font.decode([255])).throws<PdfUnsupportedException>();
  });

  test('CMap hostile expansion, invalid strings and inherited maps fail explicitly', () {
    check(() => cmap('1 beginbfrange <0000> <ffff> <0041> endbfrange', limits: const PdfLimits(maxObjects: 16))).throws<FormatException>();
    check(() => cmap('1 beginbfchar <01> <d800> endbfchar')).throws<FormatException>();
    check(() => cmap('1 beginbfchar <01> <00> endbfchar')).throws<FormatException>();
    check(() => cmap('/Parent usecmap')).throws<PdfUnsupportedException>();
    check(() => cmap('1 beginbfrange <01> <03> [<0041>] endbfrange')).throws<FormatException>();
    check(() => cmap('1 beginbfrange <01> <00> <0041> endbfrange')).throws<FormatException>();
  });

  test('Differences overrides only mapped glyphs and does not guess unknown names', () {
    final PdfDictionary dictionary = PdfResources.standardFont().copyWith(
      values: {
        'Encoding': PdfDictionary(
          values: {
            'BaseEncoding': PdfName(value: 'WinAnsiEncoding'),
            'Differences': PdfArray(
              values: [
                PdfNumber(value: 65),
                PdfName(value: 'uni03A9'),
                PdfName(value: 'UnmappedGlyph'),
                PdfName(value: 'u1F600'),
              ],
            ),
          },
        ),
      },
    );
    final PdfFont font = PdfFont.read(document: program('').document, value: dictionary);
    check(font.decode([65, 67])).equals('Ω😀');
    check(font.encode('Ω😀')).deepEquals([65, 67]);
    check(() => font.decode([66])).throws<PdfUnsupportedException>();
  });

  test('ExtGState Font selects an indirect font without requiring a Tf name', () {
    final PdfDocument source = program('').document;
    final PdfDictionary resources = PdfDictionary(
      values: {
        'ExtGState': PdfDictionary(
          values: {
            'GS': PdfDictionary(
              values: {
                'Font': PdfArray(values: [PdfResources.standardFont(), PdfNumber(value: 12)]),
              },
            ),
          },
        ),
      },
    );
    final PdfProgram value = PdfProgram.decode(bytes: latin1.encode('/GS gs BT (state) Tj ET'), resources: resources, document: source);
    check(value.textRuns.single.fontName).isNull();
    check(value.textRuns.single.text).equals('state');
  });
}
