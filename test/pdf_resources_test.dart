import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:test/test.dart';

/// Checks typed resource replacement and annotation reference ownership.
void main() {
  test('image samples retain mask and color attributes and reject wrong dimensions', () {
    final PdfDocument document = PdfDocument.fromPages(pages: []);
    final PdfStream source = PdfResources.image(width: 2, height: 1, samples: [1, 2, 3, 4, 5, 6]);
    final PdfImage image = PdfImage(
      stream: PdfStream(
        dictionary: source.dictionary.copyWith(
          values: {
            'SMask': const PdfReference(objectNumber: 50),
            'Private': PdfName(value: 'Keep'),
          },
        ),
        data: source.data,
      ),
      document: document,
    );
    final PdfImage changed = image.withSampleData(samples: [6, 5, 4, 3, 2, 1]);
    check(changed.samples).deepEquals([6, 5, 4, 3, 2, 1]);
    check(image.samples).deepEquals([1, 2, 3, 4, 5, 6]);
    check(changed.stream.dictionary['SMask']).equals(const PdfReference(objectNumber: 50));
    check(changed.stream.dictionary.name('Private')).equals('Keep');
    check(() => image.withSampleData(samples: [0])).throws<FormatException>();
  });

  test('packed mask samples use per-row padding', () {
    final PdfImage mask = PdfImage(
      stream: PdfStream(
        dictionary: PdfDictionary(
          values: {
            'Subtype': PdfName(value: 'Image'),
            'Width': PdfNumber(value: 3),
            'Height': PdfNumber(value: 2),
            'ImageMask': const PdfBoolean(value: true),
          },
        ),
        data: [0, 0],
      ),
      document: PdfDocument.fromPages(pages: []),
    );
    check(mask.withSampleData(samples: [0x80, 0x40]).samples).deepEquals([0x80, 0x40]);
    check(() => mask.withSampleData(samples: [0])).throws<FormatException>();
  });

  test('encoded image replacement preserves unrelated data without decoding pixels', () {
    final PdfDocument document = PdfDocument.fromPages(pages: []);
    final PdfImage image = PdfImage(
      stream: PdfStream(
        dictionary: PdfDictionary(
          values: {
            'Subtype': PdfName(value: 'Image'),
            'Width': PdfNumber(value: 1),
            'Height': PdfNumber(value: 1),
            'Filter': PdfName(value: 'DCTDecode'),
            'Private': PdfName(value: 'Keep'),
          },
        ),
        data: [255, 216, 255, 217],
      ),
      document: document,
    );
    final PdfImage changed = image.withEncodedData(
      bytes: [0, 255, 0],
      remove: {'Filter'},
      values: {
        'BitsPerComponent': PdfNumber(value: 8),
        'ColorSpace': PdfName(value: 'DeviceRGB'),
      },
    );
    check(changed.samples).deepEquals([0, 255, 0]);
    check(changed.stream.dictionary.name('Private')).equals('Keep');
    check(image.stream.data).deepEquals([255, 216, 255, 217]);
    check(image.stream.dictionary.name('Filter')).equals('DCTDecode');
    check(() => image.withEncodedData(bytes: [256])).throws<FormatException>();
  });

  test('form program and bounds edits retain encoded data and resource ownership', () {
    final PdfDocument document = PdfDocument.fromPages(pages: []);
    final PdfDictionary resources = PdfDictionary(
      values: {
        'Font': PdfDictionary(values: {'F1': PdfResources.standardFont()}),
      },
    );
    final PdfForm form = PdfForm(
      document: document,
      stream: PdfResources.form(
        operations: PdfContent.decode(ascii.encode('BT /F1 12 Tf (Before) Tj ET')),
        resources: resources,
        bounds: PdfResources.box(left: 0, bottom: 0, right: 100, top: 100),
      ),
    );
    final PdfProgram program = form.program
        .withText(runIndex: 0, text: 'After')
        .withResource(
          category: 'Font',
          name: 'F1',
          value: PdfResources.standardFont(baseFont: 'Courier'),
        );
    final PdfForm changed = form.withProgram(program: program);
    check(changed.program.textRuns.single.text).equals('After');
    check(changed.program.textRuns.single.font.dictionary.name('BaseFont')).equals('Courier');
    check(form.program.textRuns.single.text).equals('Before');
    check(form.withBounds(bounds: PdfResources.box(left: 0, bottom: 0, right: 50, top: 50)).stream.data).deepEquals(form.stream.data);
    final PdfProgram foreign = PdfProgram(
      operations: program.operations,
      resources: resources,
      document: PdfDocument.fromPages(pages: []),
    );
    check(() => form.withProgram(program: foreign)).throws<ArgumentError>();
  });

  test('annotations preserve identifiers used by reply references and page ownership', () {
    final PdfEditor editor = _editor();
    editor.setPageAnnotationObjects(pageIndex: 0, annotations: [_note('Before')]);
    final PdfAnnotation first = editor.pageAnnotationObjects(pageIndex: 0).single;
    editor.setPageAnnotationObjects(
      pageIndex: 0,
      annotations: [
        first,
        _note('Reply').withProperties(values: {'IRT': first.reference!}),
      ],
    );
    final PdfDocument before = editor.document;
    final List<PdfAnnotation> annotations = editor.pageAnnotationObjects(pageIndex: 0);
    editor.setPageAnnotationObjects(
      pageIndex: 0,
      annotations: [
        annotations.first.withText(text: 'Après'),
        annotations.last,
      ],
    );
    final List<PdfAnnotation> changed = editor.pageAnnotationObjects(pageIndex: 0);
    check(changed.first.reference).equals(first.reference);
    check(changed.last.dictionary['IRT']).equals(first.reference);
    check(changed.first.dictionary['P']).equals(editor.document.pages.single.reference);
    check(changed.first.dictionary.name('Private')).equals('Keep');
    check((before.dictionary(first.reference!)['Contents']! as PdfString).text).equals('Before');
    final PdfDocument reopened = const PdfCodec().decode(const PdfCodec().encode(editor.document));
    check((reopened.dictionary(first.reference!)['Contents']! as PdfString).text).equals('Après');
  });

  test('foreign and repeated annotation identities are rejected before publishing', () {
    final PdfEditor editor = _editor();
    editor.setPageAnnotationObjects(pageIndex: 0, annotations: [_note('Text')]);
    final PdfAnnotation annotation = editor.pageAnnotationObjects(pageIndex: 0).single;
    final PdfDocument before = editor.document;
    check(() => editor.setPageAnnotationObjects(pageIndex: 0, annotations: [annotation, annotation])).throws<ArgumentError>();
    check(
      () => editor.setPageAnnotationObjects(
        pageIndex: 0,
        annotations: [PdfAnnotation(dictionary: annotation.dictionary, reference: const PdfReference(objectNumber: 1000))],
      ),
    ).throws<ArgumentError>();
    check(identical(editor.document, before)).isTrue();
  });

  test('annotation removal detaches the list but preserves source object bytes', () {
    final PdfEditor editor = _editor();
    editor.setPageAnnotationObjects(pageIndex: 0, annotations: [_note('Text')]);
    final PdfReference reference = editor.pageAnnotationObjects(pageIndex: 0).single.reference!;
    editor.setPageAnnotationObjects(pageIndex: 0, annotations: []);
    check(editor.pageAnnotationObjects(pageIndex: 0)).isEmpty();
    check(editor.document.objects.containsKey(reference)).isTrue();
  });

  test('typed annotation edits retain untouched widgets and reject uncoordinated field changes', () {
    final PdfEditor editor = _editor();
    final PdfReference widget = editor.addObject(
      value: _note('Widget').dictionary.copyWith(values: {'Subtype': PdfName(value: 'Widget')}),
    );
    editor.setPageAnnotations(pageIndex: 0, annotations: [widget]);
    editor.setPageAnnotationObjects(pageIndex: 0, annotations: [...editor.pageAnnotationObjects(pageIndex: 0), _note('Note')]);
    final PdfDocument before = editor.document;
    final List<PdfAnnotation> annotations = editor.pageAnnotationObjects(pageIndex: 0);
    check(
      () => editor.setPageAnnotationObjects(
        pageIndex: 0,
        annotations: [
          annotations.first.withText(text: 'Changed'),
          annotations.last,
        ],
      ),
    ).throws<PdfUnsupportedException>();
    check(() => editor.setPageAnnotationObjects(pageIndex: 0, annotations: [annotations.last])).throws<PdfUnsupportedException>();
    check(identical(editor.document, before)).isTrue();
  });

  test('XMP replacement preserves the independent document information dictionary', () {
    final PdfEditor editor = _editor();
    editor.setInformation(values: {'Title': PdfString.text(text: 'Metadata')});
    editor.setMetadata(xml: utf8.encode('<example>é</example>'));
    final PdfDocument reopened = const PdfCodec().decode(const PdfCodec().encode(editor.document));
    final PdfStream metadata = reopened.resolve(reopened.catalog['Metadata']!) as PdfStream;
    check(utf8.decode(reopened.decodeStream(metadata))).equals('<example>é</example>');
    check(metadata.dictionary.name('Subtype')).equals('XML');
    check((reopened.dictionary(reopened.trailer['Info']!)['Title']! as PdfString).text).equals('Metadata');
  });
}

/// Creates a blank one-page editing fixture.
PdfEditor _editor() => PdfEditor(
  document: PdfDocument.fromPages(pages: [PdfPageSource(width: 100, height: 100, content: [])]),
);

/// Creates a standard text annotation with an opaque vendor property.
PdfAnnotation _note(String text) => PdfAnnotation(
  dictionary: PdfDictionary(
    values: {
      'Subtype': PdfName(value: 'Text'),
      'Rect': PdfResources.box(left: 1, bottom: 2, right: 20, top: 30),
      'Contents': PdfString.text(text: text),
      'Private': PdfName(value: 'Keep'),
    },
  ),
);
