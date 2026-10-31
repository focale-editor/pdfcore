import 'dart:convert';
import 'dart:typed_data';

import 'package:pdfcore/pdfcore.dart';

/// Creates artwork, edits its text and path, and reopens the saved document.
void main() {
  final PdfDocument source = PdfDocument.fromPages(
    pages: [
      PdfPageSource(
        width: 240,
        height: 120,
        resources: PdfDictionary(
          values: {
            'Font': PdfDictionary(values: {'F1': PdfResources.standardFont()}),
          },
        ),
        content: latin1.encode('0.1 0.4 0.9 rg 20 20 160 60 re f 0 g BT /F1 14 Tf 20 95 Td (Original) Tj ET'),
      ),
    ],
  );
  final PdfProgram program = PdfProgram.fromPage(document: source, pageIndex: 0);
  final PdfProgram changed = program
      .withText(runIndex: 0, text: 'Edited with PdfCore')
      .withPath(
        pathIndex: 0,
        commands: [
          PdfOperation(operator: 're', operands: [PdfNumber(value: 30), PdfNumber(value: 20), PdfNumber(value: 180), PdfNumber(value: 60)]),
        ],
      );
  final PdfDocument edited = source.edited((editor) {
    editor.setPageProgram(pageIndex: 0, program: changed);
    editor.setInformation(values: {'Title': PdfString.text(text: 'Editable PDF example')});
    editor.duplicatePage(pageIndex: 0);
    editor.setPageRotation(pageIndex: 1, degrees: 90);
  });
  final Uint8List bytes = const PdfCodec().encode(edited);
  final PdfDocument reopened = const PdfCodec().decode(bytes);
  final PdfProgram restored = PdfProgram.fromPage(document: reopened, pageIndex: 0);
  if (restored.textRuns.single.text != 'Edited with PdfCore' || reopened.pages.length != 2 || program.textRuns.single.text != 'Original') {
    throw StateError('PDF editing round trip failed.');
  }
  print('${reopened.pages.length} pages; ${restored.textRuns.single.text}; ${bytes.length} bytes');
}
