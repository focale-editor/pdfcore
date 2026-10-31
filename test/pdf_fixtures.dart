import 'dart:convert';
import 'dart:typed_data';

/// Creates independent classic-xref syntax fixtures without PdfCore's writer.
Uint8List classicPdf({Map<int, String>? objects, String trailer = '', String version = '1.7'}) {
  final Map<int, String> bodies =
      objects ??
      {
        1: '<< /Type /Catalog /Pages 2 0 R >>',
        2: '<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 100] /Resources << >> >>',
        3: '<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>',
        4: '<< /Length 5 0 R >>\nstream\nq\nQ\nendstream',
        5: '4',
      };
  final StringBuffer output = StringBuffer('%PDF-$version\n');
  final Map<int, int> offsets = {};
  for (final MapEntry<int, String> entry in bodies.entries) {
    offsets[entry.key] = latin1.encode(output.toString()).length;
    output.write('${entry.key} 0 obj\n${entry.value}\nendobj\n');
  }
  final int xref = latin1.encode(output.toString()).length;
  output.write('xref\n0 1\n0000000000 65535 f \n');
  for (final MapEntry<int, int> entry in offsets.entries) {
    output.write('${entry.key} 1\n${entry.value.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write('trailer\n<< /Size ${bodies.keys.reduce((a, b) => a > b ? a : b) + 1} /Root 1 0 R $trailer >>\nstartxref\n$xref\n%%EOF\n');
  return latin1.encode(output.toString());
}

/// Appends a revision with replacements or free entries to a classic fixture.
Uint8List incrementalPdf({required Uint8List original, Map<int, String> replacements = const {}, Set<int> freed = const {}}) {
  final String text = latin1.decode(original);
  final int previous = int.parse(RegExp(r'startxref\s+(\d+)').allMatches(text).last[1]!);
  final StringBuffer output = StringBuffer(text);
  final Map<int, int> offsets = {};
  for (final MapEntry<int, String> entry in replacements.entries) {
    offsets[entry.key] = output.length;
    output.write('${entry.key} 0 obj\n${entry.value}\nendobj\n');
  }
  final int xref = output.length;
  output.write('xref\n');
  for (final MapEntry<int, int> entry in offsets.entries) {
    output.write('${entry.key} 1\n${entry.value.toString().padLeft(10, '0')} 00000 n \n');
  }
  for (final int number in freed) {
    output.write('$number 1\n0000000000 00001 f \n');
  }
  output.write('trailer\n<< /Size 99 /Root 1 0 R /Prev $previous >>\nstartxref\n$xref\n%%EOF\n');
  return latin1.encode(output.toString());
}

/// Creates a small PDF 1.5 object stream and xref stream independently.
Uint8List compressedPdf({bool hybrid = false, bool staleSelfEntry = false}) {
  final BytesBuilder output = BytesBuilder();
  output.add(latin1.encode('%PDF-1.5\n'));
  const String catalog = '<< /Type /Catalog /Pages 2 0 R >>';
  const String pages = '<< /Type /Pages /Kids [3 0 R] /Count 1 >>';
  const String page = '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] /Resources << >> >>';
  const String header = '1 0 2 ${catalog.length + 1} 3 ${catalog.length + pages.length + 2} ';
  const String data = '$header$catalog $pages $page';
  final int objectStreamOffset = output.length;
  output.add(latin1.encode('4 0 obj\n<< /Type /ObjStm /N 3 /First ${header.length} /Length ${data.length} >>\nstream\n$data\nendstream\nendobj\n'));
  final int xrefOffset = output.length;
  final List<List<int>> entries = [
    [0, 0, 65535],
    [2, 4, 0],
    [2, 4, 1],
    [2, 4, 2],
    [1, objectStreamOffset, 0],
    [1, if (staleSelfEntry) objectStreamOffset else xrefOffset, 0],
  ];
  final List<int> xrefData = [
    for (final List<int> entry in entries) ...[entry[0], entry[1] >> 8, entry[1] & 255, entry[2] >> 8, entry[2] & 255],
  ];
  output.add(latin1.encode('5 0 obj\n<< /Type /XRef /Size 6 /Root 1 0 R /W [1 2 2] /Length ${xrefData.length} >>\nstream\n'));
  output.add(xrefData);
  output.add(latin1.encode('\nendstream\nendobj\n'));
  int start = xrefOffset;
  if (hybrid) {
    start = output.length;
    output.add(latin1.encode('xref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 6 /Root 1 0 R /XRefStm $xrefOffset >>\n'));
  }
  output.add(latin1.encode('startxref\n$start\n%%EOF\n'));
  return output.takeBytes();
}
