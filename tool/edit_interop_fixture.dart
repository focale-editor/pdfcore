import 'dart:convert';
import 'dart:io';

import 'package:pdfcore/pdfcore.dart';

/// Edits an independently authored fixture for QPDF and Poppler comparison.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError('Usage: dart run tool/edit_interop_fixture.dart input.pdf output.pdf');
  }
  final PdfDocument source = const PdfCodec().decode(await File(arguments[0]).readAsBytes());
  final PdfProgram before = PdfProgram.fromPage(document: source, pageIndex: 0);
  final PdfProgram changed = before.withText(runIndex: 0, text: 'After €').withPath(pathIndex: 0, commands: PdfContent.decode(latin1.encode('30 20 40 20 re')));
  final PdfEditor editor = PdfEditor(document: source);
  editor.setPageProgram(pageIndex: 0, program: changed);
  final PdfImage image = PdfImage(
    document: source,
    stream: editor.pageResource(pageIndex: 0, category: 'XObject', name: 'Im') as PdfStream,
  );
  editor.setPageResource(
    pageIndex: 0,
    category: 'XObject',
    name: 'Im',
    value: image.withSamples(samples: [0, 0, 255]).stream,
  );
  final PdfForm form = PdfForm(
    document: source,
    stream: editor.pageResource(pageIndex: 0, category: 'XObject', name: 'Fm') as PdfStream,
  );
  editor.setPageResource(
    pageIndex: 0,
    category: 'XObject',
    name: 'Fm',
    value: form.withOperations(operations: PdfContent.decode(latin1.encode('0 1 0 rg 2 2 6 6 re f'))).stream,
  );
  final List<PdfOperation> operations = editor.pageOperations(pageIndex: 0).toList();
  final int inlineIndex = operations.indexWhere((operation) => operation.inlineImage != null);
  operations[inlineIndex] = PdfOperation.image(
    image: PdfInlineImage(dictionary: operations[inlineIndex].inlineImage!.dictionary, data: [255, 0, 255, 0]),
  );
  editor.setPageOperations(pageIndex: 0, operations: operations);
  editor.setInformation(values: {'Title': PdfString.text(text: 'Edited by PdfCore')});
  await File(arguments[1]).writeAsBytes(const PdfCodec().encode(editor.document));
}
