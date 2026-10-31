import 'dart:convert';
import 'dart:io';

import 'package:pdfcore/pdfcore.dart';

/// Rewrites real page programs through editing APIs for independent render QA.
Future<void> main() async {
  final Map<String, Object?> manifest = (jsonDecode(await File('test/corpus/manifest.json').readAsString()) as Map).cast<String, Object?>();
  final List<Object?> entries = (manifest['files']! as List).cast<Object?>();
  final List<Map<String, Object?>> results = [];
  final Directory directory = await Directory('test/corpus/output/editing').create(recursive: true);
  int failures = 0;
  for (final Object? value in entries) {
    final Map<String, Object?> entry = (value! as Map).cast<String, Object?>();
    if (entry['expected'] != 'accept') {
      continue;
    }
    final String name = entry['file']! as String;
    try {
      final PdfDocument original = const PdfCodec().decode(await File('test/corpus/files/$name').readAsBytes());
      final PdfEditor editor = PdfEditor(document: original);
      final List<Map<String, Object?>> preserved = [];
      int edited = 0;
      int inlineImages = 0;
      for (int index = 0; index < original.pages.length; index++) {
        try {
          final PdfProgram program = PdfProgram.fromPage(document: original, pageIndex: index);
          inlineImages += program.operations.where((operation) => operation.inlineImage != null).length;
          editor.setPageOperations(pageIndex: index, operations: program.operations);
          edited++;
        } on PdfUnsupportedException catch (error) {
          preserved.add({'page': index, 'reason': error.message});
        }
      }
      // Exercise page-tree rebuilding without changing final display order.
      if (original.pages.length > 1) {
        editor.movePage(from: 0, to: original.pages.length - 1);
        editor.movePage(from: original.pages.length - 1, to: 0);
      }
      final List<int> encoded = const PdfCodec().encode(editor.document);
      final PdfDocument restored = const PdfCodec().decode(encoded);
      if (restored.pages.length != original.pages.length) {
        throw StateError('Page count changed');
      }
      await File('${directory.path}/$name').writeAsBytes(encoded);
      results.add({
        'file': name,
        'pages_rewritten': edited,
        'inline_images': inlineImages,
        'pages_preserved_opaque': preserved,
        if (entry['render_reference'] != null) 'render_reference': entry['render_reference'],
      });
    } on Object catch (error) {
      failures++;
      results.add({'file': name, 'error': error.toString()});
      stderr.writeln('$name: $error');
    }
  }
  await File('${directory.path}/report.json').writeAsString('${const JsonEncoder.withIndent('  ').convert(results)}\n');
  stdout.writeln('PdfCore editing: ${results.length - failures}/${results.length} files rewritten');
  if (failures > 0) {
    exitCode = 1;
  }
}
