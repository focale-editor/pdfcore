import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:test/test.dart';

/// Creates a small document with independently encoded page content.
PdfDocument pages(List<String> contents) => PdfDocument.fromPages(pages: [for (final String content in contents) PdfPageSource(width: 100, height: 100, content: latin1.encode(content))]);

/// Reopens edited snapshots through the actual writer and reader.
PdfDocument reopen(PdfDocument document) => const PdfCodec().decode(const PdfCodec().encode(document));

/// Reads one page's exact decoded graphics bytes.
String content(PdfDocument document, int index) => latin1.decode(document.pageContent(document.pages[index]));

/// Exercises copy-based editing, graph ownership and resource lifetimes.
void main() {
  test('editing snapshots leave source content and metadata unchanged', () {
    final PdfDocument source = pages(['0 0 10 10 re f']);
    final PdfDocument edited = source.edited((editor) {
      editor.setPageContent(pageIndex: 0, bytes: latin1.encode('20 20 10 10 re S'));
      editor.setInformation(values: {'Title': PdfString.text(text: 'Édition')});
    });
    final PdfDocument restored = reopen(edited);
    check(content(source, 0)).equals('0 0 10 10 re f');
    check(content(restored, 0)).equals('20 20 10 10 re S');
    check((restored.dictionary(restored.trailer['Info']!)['Title']! as PdfString).text).equals('Édition');
    check(source.trailer['Info']).isNull();
  });

  test('shared content and resource replacements affect only the selected page', () {
    final PdfDocument base = pages(['q Q', 'q Q']);
    final PdfReference first = base.pages[0].reference!;
    final PdfReference second = base.pages[1].reference!;
    const PdfReference resource = PdfReference(objectNumber: 20);
    final PdfDictionary resources = PdfDictionary(
      values: {
        'Font': PdfDictionary(values: {'F1': PdfResources.standardFont()}),
      },
    );
    final PdfDocument source = base.copyWith(
      objects: {
        ...base.objects,
        resource: resources,
        first: base.pages[0].dictionary.copyWith(values: {'Resources': resource}),
        second: base.pages[1].dictionary.copyWith(values: {'Contents': base.pages[0].dictionary['Contents']!, 'Resources': resource}),
      },
    );
    final PdfEditor editor = PdfEditor(document: source);
    editor.setPageContent(pageIndex: 0, bytes: latin1.encode('1 2 m 3 4 l S'));
    editor.setPageResource(
      pageIndex: 0,
      category: 'Font',
      name: 'F1',
      value: PdfResources.standardFont(baseFont: 'Courier'),
    );
    check(content(editor.document, 1)).equals('q Q');
    check((editor.pageResource(pageIndex: 0, category: 'Font', name: 'F1') as PdfDictionary).name('BaseFont')).equals('Courier');
    check((editor.pageResource(pageIndex: 1, category: 'Font', name: 'F1') as PdfDictionary).name('BaseFont')).equals('Helvetica');
    check(identical(editor.document.objects[resource], resources)).isTrue();
    reopen(editor.document);
  });

  test('resource allocation skips existing names and dangling object references', () {
    final PdfDocument base = pages(['']);
    final PdfDocument source = base.copyWith(trailer: base.trailer.copyWith(values: {'Unknown': const PdfReference(objectNumber: 5)}));
    final PdfEditor editor = PdfEditor(document: source);
    final PdfReference reference = editor.addObject(value: PdfDictionary(values: {'Dangling': const PdfReference(objectNumber: 6)}));
    check(reference.objectNumber).equals(7);
    check(editor.document.resolve(const PdfReference(objectNumber: 5))).isA<PdfNull>();
    check(editor.setPageResource(pageIndex: 0, category: 'Font', value: PdfResources.standardFont())).equals('R1');
    check(editor.setPageResource(pageIndex: 0, category: 'Font', value: PdfResources.standardFont())).equals('R2');
  });

  test('failed edits are atomic', () {
    final PdfDocument original = pages(['q Q']);
    final PdfEditor editor = PdfEditor(document: original);
    check(() => editor.insertPage(page: PdfPageSource(width: 10, height: 10, content: []), index: 9)).throws<RangeError>();
    check(identical(editor.document, original)).isTrue();
    check(() => editor.setPageAttributes(pageIndex: 0, values: {'Parent': const PdfNull()})).throws<ArgumentError>();
    check(identical(editor.document, original)).isTrue();
    check(() => editor.setPageContent(pageIndex: 5, bytes: [])).throws<RangeError>();
    check(identical(editor.document, original)).isTrue();
  });

  test('insert move duplicate remove retain inherited attributes and identities', () {
    final PdfDocument base = pages(['1 w', '2 w']);
    final PdfReference tree = base.catalog['Pages']! as PdfReference;
    final PdfReference first = base.pages[0].reference!;
    final PdfReference second = base.pages[1].reference!;
    final PdfDocument source = base.copyWith(
      objects: {
        ...base.objects,
        tree: base
            .dictionary(tree)
            .copyWith(
              values: {
                'Rotate': PdfNumber(value: 90),
                'CustomTree': PdfString.text(text: 'retained'),
              },
            ),
        first: base.pages[0].dictionary.copyWith(remove: {'Resources'}),
        second: base.pages[1].dictionary.copyWith(remove: {'Resources'}),
      },
    );
    final PdfEditor editor = PdfEditor(document: source);
    editor.movePage(from: 1, to: 0);
    check(editor.document.pages[0].reference).equals(second);
    check(editor.document.pages[0].inherited.integer('Rotate')).equals(90);
    check(editor.document.dictionary(editor.document.catalog['Pages']!)['CustomTree']).isNotNull();
    editor.duplicatePage(pageIndex: 0);
    editor.setPageContent(pageIndex: 1, bytes: latin1.encode('3 w'));
    editor.insertPage(page: PdfPageSource(width: 200, height: 300, content: latin1.encode('4 w')));
    editor.removePage(pageIndex: 2);
    final PdfDocument restored = reopen(editor.document);
    check(restored.pages.length).equals(3);
    check([for (int index = 0; index < 3; index++) content(restored, index)]).deepEquals(['2 w', '3 w', '4 w']);
    check(restored.pages[2].inherited['Rotate']).isNull();
  });

  test('direct pages are materialized without losing new content or resources', () {
    final PdfDocument base = pages(['1 w']);
    final PdfReference tree = base.catalog['Pages']! as PdfReference;
    final PdfDocument direct = base.copyWith(
      objects: {
        ...base.objects,
        tree: base
            .dictionary(tree)
            .copyWith(
              values: {
                'Kids': PdfArray(values: [base.pages.single.dictionary]),
              },
            ),
      },
    );
    final PdfEditor editor = PdfEditor(document: direct);
    editor.setPageResource(pageIndex: 0, category: 'Font', name: 'F1', value: PdfResources.standardFont());
    editor.setPageContent(pageIndex: 0, bytes: latin1.encode('2 w'));
    check(content(reopen(editor.document), 0)).equals('2 w');
    check(editor.pageResource(pageIndex: 0, category: 'Font', name: 'F1')).isA<PdfDictionary>();
  });

  test('multi-page imports remap shared resources, links and annotation cycles', () {
    final PdfDocument base = pages(['1 w', '2 w']);
    const PdfReference annotation = PdfReference(objectNumber: 30);
    const PdfReference font = PdfReference(objectNumber: 31);
    final PdfReference first = base.pages[0].reference!;
    final PdfReference second = base.pages[1].reference!;
    final PdfDictionary resources = PdfDictionary(
      values: {
        'Font': PdfDictionary(values: {'F': font}),
      },
    );
    final PdfDocument source = base.copyWith(
      version: '2.0',
      objects: {
        ...base.objects,
        first: base.pages[0].dictionary.copyWith(
          values: {
            'Resources': resources,
            'Annots': PdfArray(values: [annotation]),
          },
        ),
        second: base.pages[1].dictionary.copyWith(values: {'Resources': resources}),
        annotation: PdfDictionary(
          values: {
            'Type': PdfName(value: 'Annot'),
            'Subtype': PdfName(value: 'Link'),
            'P': first,
            'Rect': PdfResources.box(left: 0, bottom: 0, right: 10, top: 10),
            'Dest': PdfArray(
              values: [
                second,
                PdfName(value: 'Fit'),
              ],
            ),
          },
        ),
        font: PdfResources.standardFont(),
      },
    );
    final PdfEditor editor = PdfEditor(document: pages(['']));
    editor.importPages(source: source, pageIndices: [0, 1]);
    final PdfDocument imported = reopen(editor.document);
    final PdfArray annotations = imported.pages[1].dictionary['Annots']! as PdfArray;
    final PdfDictionary link = imported.dictionary(annotations.values.single);
    check(link['P']).equals(imported.pages[1].reference);
    check((link['Dest']! as PdfArray).values.first).equals(imported.pages[2].reference!);
    final PdfValue shared1 = imported.dictionary(imported.dictionary(imported.pages[1].inherited['Resources']!)['Font']!)['F']!;
    final PdfValue shared2 = imported.dictionary(imported.dictionary(imported.pages[2].inherited['Resources']!)['Font']!)['F']!;
    check(shared1).equals(shared2);
    check(imported.catalog.name('Version')).equals('2.0');
    final PdfEditor rejected = PdfEditor(document: pages(['']));
    final PdfDocument before = rejected.document;
    check(() => rejected.importPage(source: source, pageIndex: 0)).throws<PdfUnsupportedException>();
    check(identical(before, rejected.document)).isTrue();
  });

  test('global form and tagging imports fail explicitly', () {
    final PdfDocument base = pages(['']);
    final PdfDocument form = base.edited((editor) => editor.setCatalogEntries(values: {'AcroForm': PdfDictionary()}));
    final PdfEditor editor = PdfEditor(document: base);
    check(() => editor.importPage(source: form, pageIndex: 0)).throws<PdfUnsupportedException>();
    check(identical(editor.document, base)).isTrue();
  });

  test('stream replacement clears stale compression and external-file fields', () {
    final PdfStream stream = PdfStreams.encode(
      bytes: [1, 2, 3],
      compress: false,
      dictionary: PdfDictionary(
        values: {
          'Custom': PdfNumber(value: 7),
          'Filter': PdfName(value: 'DCTDecode'),
          'DecodeParms': PdfDictionary(),
          'F': PdfString.text(text: 'external'),
        },
      ),
    );
    check(stream.dictionary.values.keys).deepEquals(['Custom']);
    check(PdfFilters.decode(stream)).deepEquals([1, 2, 3]);
  });

  test('image sample edits preserve metadata and clear old masks and decode', () {
    final PdfDocument document = pages(['']);
    final PdfStream original = PdfResources.image(width: 1, height: 1, samples: [255, 0, 0]);
    final PdfImage image = PdfImage(
      document: document,
      stream: PdfStream(
        dictionary: original.dictionary.copyWith(
          values: {
            'Custom': PdfNumber(value: 7),
            'SMask': const PdfReference(objectNumber: 99),
            'Decode': PdfArray(values: []),
          },
        ),
        data: original.data,
      ),
    );
    final PdfImage edited = image.withSamples(samples: [0, 255, 0]);
    check(edited.samples).deepEquals([0, 255, 0]);
    check(edited.stream.dictionary['SMask']).isNull();
    check(edited.stream.dictionary['Decode']).isNull();
    check(edited.stream.dictionary.integer('Custom')).equals(7);
    check(image.samples).deepEquals([255, 0, 0]);
    check(() => image.withSamples(samples: [1])).throws<FormatException>();
  });

  test('form edits retain transparency groups, matrices and unrelated resources', () {
    final PdfDocument document = pages(['']);
    final PdfStream stream = PdfResources.form(operations: PdfContent.decode(latin1.encode('0 0 10 10 re f')), bounds: PdfResources.box(left: 0, bottom: 0, right: 10, top: 10));
    final PdfDictionary group = PdfDictionary(values: {'S': PdfName(value: 'Transparency')});
    final PdfForm form = PdfForm(
      document: document,
      stream: PdfStream(
        dictionary: stream.dictionary.copyWith(values: {'Group': group}),
        data: stream.data,
      ),
    );
    final PdfForm edited = form.withOperations(operations: PdfContent.decode(latin1.encode('1 1 8 8 re S'))).withResource(category: 'Font', name: 'F1', value: PdfResources.standardFont());
    check(edited.program.paths.single.paintOperator).equals('S');
    check(identical(edited.stream.dictionary['Group'], group)).isTrue();
    check(form.program.paths.single.paintOperator).equals('f');
    check(edited.resources['Font']).isNotNull();
  });

  test('replacing one XObject use leaves repeated uses and other pages alone', () {
    final PdfDocument base = pages(['/Im Do /Im Do', '/Im Do']);
    final PdfEditor editor = PdfEditor(document: base);
    final PdfStream red = PdfResources.image(width: 1, height: 1, samples: [255, 0, 0]);
    for (int page = 0; page < 2; page++) {
      editor.setPageResource(pageIndex: page, category: 'XObject', name: 'Im', value: red);
    }
    final String name = editor.replaceXObjectUse(pageIndex: 0, operationIndex: 0, value: PdfResources.image(width: 1, height: 1, samples: [0, 0, 255]));
    final List<PdfOperation> operations = editor.pageOperations(pageIndex: 0);
    check((operations[0].operands.single as PdfName).value).equals(name);
    check((operations[1].operands.single as PdfName).value).equals('Im');
    check(
      PdfImage(
        document: editor.document,
        stream: editor.pageResource(pageIndex: 1, category: 'XObject', name: 'Im') as PdfStream,
      ).samples,
    ).deepEquals([255, 0, 0]);
    check(
      PdfImage(
        document: editor.document,
        stream: editor.pageResource(pageIndex: 0, category: 'XObject', name: name) as PdfStream,
      ).samples,
    ).deepEquals([0, 0, 255]);
  });

  test('page boxes rotation and annotation arrays retain unedited metadata', () {
    final PdfEditor editor = PdfEditor(document: pages(['']));
    editor.setPageBox(pageIndex: 0, name: 'CropBox', bounds: PdfResources.box(left: 10, bottom: 10, right: 80, top: 80));
    editor.setPageRotation(pageIndex: 0, degrees: -90);
    final PdfReference annotation = editor.addObject(
      value: PdfDictionary(
        values: {
          'Subtype': PdfName(value: 'Text'),
          'Contents': PdfString.text(text: 'Comment'),
          'Custom': PdfNumber(value: 7),
        },
      ),
    );
    editor.setPageAnnotations(pageIndex: 0, annotations: [annotation]);
    check(editor.pageAnnotations(pageIndex: 0)).deepEquals([annotation]);
    check(reopen(editor.document).pages.single.dictionary.integer('Rotate')).equals(270);
    final PdfDocument before = editor.document;
    check(() => editor.setPageRotation(pageIndex: 0, degrees: 1)).throws<ArgumentError>();
    check(identical(before, editor.document)).isTrue();
    editor.setPageAnnotations(pageIndex: 0, annotations: []);
    check(editor.pageAnnotations(pageIndex: 0)).isEmpty();
    check(editor.document.dictionary(annotation).integer('Custom')).equals(7);
  });

  test('committing a program also commits its font resource replacement', () {
    final PdfDocument base = pages(['BT /F 12 Tf (text) Tj ET']);
    final PdfProgram program = PdfProgram.fromPage(document: base, pageIndex: 0).withResource(category: 'Font', name: 'F', value: PdfResources.standardFont());
    final PdfEditor editor = PdfEditor(document: base);
    editor.setPageProgram(pageIndex: 0, program: program);
    check(PdfProgram.fromPage(document: reopen(editor.document), pageIndex: 0).textRuns.single.text).equals('text');
    check(base.pages.single.inherited['Resources']! as PdfDictionary).has((value) => value.values, 'values').isEmpty();
  });

  test('editing enforces page and object budgets without publishing partial work', () {
    final PdfDocument base = pages(['']);
    final PdfDocument limited = PdfDocument(objects: base.objects, trailer: base.trailer, limits: const PdfLimits(maxPages: 1, maxObjects: 8));
    final PdfEditor editor = PdfEditor(document: limited);
    check(() => editor.insertPage(page: PdfPageSource(width: 10, height: 10, content: []))).throws<FormatException>();
    check(identical(editor.document, limited)).isTrue();
    check(() => editor.importPages(source: base, pageIndices: [0, 0])).throws<ArgumentError>();
    check(identical(editor.document, limited)).isTrue();
  });
}
