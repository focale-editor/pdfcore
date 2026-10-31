import 'dart:convert';
import 'dart:io';

import 'package:pdfcore/pdfcore.dart';

/// Demonstrates copied text, path, image, form, annotation and metadata edits.
Future<void> main(List<String> arguments) async {
  final Directory destination = Directory(arguments.isEmpty ? 'test/corpus/output/editing-example' : arguments.single);
  await destination.create(recursive: true);
  final PdfEditor editor = PdfEditor(
    document: PdfDocument.fromPages(pages: [PdfPageSource(width: 200, height: 140, content: [])]),
  );
  editor.setPageResource(pageIndex: 0, category: 'Font', name: 'F1', value: PdfResources.standardFont());
  editor.setPageResource(
    pageIndex: 0,
    category: 'XObject',
    name: 'Image',
    value: PdfResources.image(width: 1, height: 1, samples: [255, 0, 0]),
  );
  editor.setPageResource(
    pageIndex: 0,
    category: 'XObject',
    name: 'Form',
    value: PdfResources.form(
      operations: PdfContent.decode(ascii.encode('BT /F1 12 Tf 0 10 Td (Form) Tj ET')),
      resources: editor.pageResources(pageIndex: 0),
      bounds: PdfResources.box(left: 0, bottom: 0, right: 60, top: 30),
    ),
  );
  editor.setPageContent(pageIndex: 0, bytes: ascii.encode('0 0 1 rg 10 10 40 30 re f 0 g BT /F1 18 Tf 10 100 Td (Before) Tj ET q 20 0 0 20 100 10 cm /Image Do Q q 1 0 0 1 100 60 cm /Form Do Q'));
  editor.setPageAnnotationObjects(
    pageIndex: 0,
    annotations: [
      PdfAnnotation(
        dictionary: PdfDictionary(
          values: {
            'Subtype': PdfName(value: 'Link'),
            'Rect': PdfResources.box(left: 10, bottom: 100, right: 80, top: 120),
            'Border': PdfArray(values: [PdfNumber(value: 0), PdfNumber(value: 0), PdfNumber(value: 0)]),
            'A': PdfDictionary(
              values: {
                'S': PdfName(value: 'URI'),
                'URI': PdfString(bytes: ascii.encode('https://example.com')),
              },
            ),
            'Private': PdfName(value: 'Keep'),
          },
        ),
      ),
    ],
  );
  await File('${destination.path}/before.pdf').writeAsBytes(const PdfCodec().encode(editor.document));

  final PdfProgram content = PdfProgram.fromPage(
    document: editor.document,
    pageIndex: 0,
  ).withText(runIndex: 0, text: 'After').withPath(pathIndex: 0, commands: PdfContent.decode(ascii.encode('10 10 60 30 re')));
  editor.setPageOperations(pageIndex: 0, operations: content.operations);
  final PdfImage image = PdfImage(
    stream: editor.pageResource(pageIndex: 0, category: 'XObject', name: 'Image') as PdfStream,
    document: editor.document,
  );
  editor.setPageResource(
    pageIndex: 0,
    category: 'XObject',
    name: 'Image',
    value: image.withSampleData(samples: [0, 255, 0]).stream,
  );
  final PdfForm form = PdfForm(
    stream: editor.pageResource(pageIndex: 0, category: 'XObject', name: 'Form') as PdfStream,
    document: editor.document,
  );
  editor.setPageResource(
    pageIndex: 0,
    category: 'XObject',
    name: 'Form',
    value: form.withProgram(program: form.program.withText(runIndex: 0, text: 'Done')).stream,
  );
  editor.setPageAnnotationObjects(pageIndex: 0, annotations: [editor.pageAnnotationObjects(pageIndex: 0).single.withText(text: 'Edited link')]);
  editor.setInformation(values: {'Title': PdfString.text(text: 'Edited PDF')});
  editor.setMetadata(xml: utf8.encode('<?xpacket begin=""?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/></x:xmpmeta><?xpacket end="w"?>'));
  await File('${destination.path}/after.pdf').writeAsBytes(const PdfCodec().encode(editor.document));
  stdout.writeln('Wrote before.pdf and after.pdf to ${destination.path}.');
}
