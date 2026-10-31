import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdfcore/pdfcore.dart';

/// Checks the explicitly downloaded corpus and emits files for independent QA.
Future<void> main() async {
  final File manifestFile = File('test/corpus/manifest.json');
  final Map<String, Object?> manifest = (jsonDecode(await manifestFile.readAsString()) as Map).cast<String, Object?>();
  final List<Object?> entries = (manifest['files']! as List).cast<Object?>();
  final List<Map<String, Object?>> report = [];
  int failures = 0;
  await Directory('test/corpus/output').create(recursive: true);
  for (final Object? value in entries) {
    final Map<String, Object?> entry = (value! as Map).cast<String, Object?>();
    final String name = entry['file']! as String;
    final bool rejected = entry['expected'] == 'reject';
    try {
      final Uint8List bytes = await File('test/corpus/files/$name').readAsBytes();
      final PdfDocument decoded = const PdfCodec().decode(bytes);
      final Uint8List encoded = const PdfCodec().encode(decoded);
      final PdfDocument reopened = const PdfCodec().decode(encoded);
      if (decoded.pages.length != reopened.pages.length) {
        throw StateError('Page count changed');
      }
      for (final MapEntry<PdfReference, PdfValue> entry in decoded.objects.entries) {
        if (entry.value case final PdfStream stream) {
          final PdfStream other = reopened.objects[entry.key]! as PdfStream;
          if (!_same(stream.data, other.data)) {
            throw StateError('Encoded stream changed');
          }
        }
      }
      if (rejected) {
        throw StateError('Expected rejection but file decoded');
      }
      final Directory decodedDirectory = Directory('test/corpus/output/decoded/$name');
      await decodedDirectory.create(recursive: true);
      for (final MapEntry<PdfReference, PdfValue> entry in decoded.objects.entries) {
        if (entry.value case final PdfStream stream) {
          try {
            final Uint8List data = decoded.decodeStream(stream);
            await File('${decodedDirectory.path}/${entry.key.objectNumber}-${entry.key.generation}.bin').writeAsBytes(data);
          } on PdfUnsupportedException {
            // Encoded bytes remain covered by the preservation assertions.
          }
        }
      }
      await File('test/corpus/output/$name').writeAsBytes(encoded);
      report.add({'file': name, 'status': 'accepted', 'bytes': encoded.length});
    } on FormatException catch (error) {
      report.add({'file': name, 'status': rejected ? 'rejected' : 'failed', 'error': error.toString()});
      if (!rejected) {
        failures++;
        stdout.writeln('$name: $error');
      }
    } on Object catch (error) {
      failures++;
      report.add({'file': name, 'status': 'failed', 'error': error.toString()});
      stdout.writeln('$name: $error');
    }
  }
  await File('test/corpus/output/report.json').writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('PdfCore: ${entries.length - failures}/${entries.length} expected outcomes');
  if (failures != 0) {
    exitCode = 1;
  }
}

/// Compares exact encoded payloads independently of model identity.
bool _same(List<int> first, List<int> second) {
  if (first.length != second.length) {
    return false;
  }
  for (int index = 0; index < first.length; index++) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}
