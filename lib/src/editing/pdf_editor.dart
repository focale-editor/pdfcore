import 'dart:convert';

import 'package:pdfcore/src/codec/pdf_content.dart';
import 'package:pdfcore/src/codec/pdf_filters.dart';
import 'package:pdfcore/src/editing/pdf_program.dart';
import 'package:pdfcore/src/editing/pdf_resources.dart';
import 'package:pdfcore/src/editing/pdf_streams.dart';
import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

part 'package:pdfcore/src/editing/pdf_annotations.dart';
part 'package:pdfcore/src/editing/pdf_graph.dart';
part 'package:pdfcore/src/editing/pdf_page_import.dart';

/// A PDF edit transaction that publishes immutable, undo-friendly snapshots.
///
/// Each successful method replaces [document]. Failed methods leave it intact.
/// Page resources and content are detached before replacement; explicit
/// [replaceObject] edits intentionally affect every reference to that object.
final class PdfEditor {
  /// Current snapshot, never mutated in place.
  PdfDocument _document;

  /// Starts an editing session without changing the source graph.
  PdfEditor({required PdfDocument document}) : _document = document {
    document.limits.validate();
    if (document.resolve(document.trailer['Encrypt'] ?? const PdfNull()) is! PdfNull) {
      throw const PdfUnsupportedException(message: 'Editing encrypted PDF graphs is unsupported.');
    }
    document.pages;
  }

  /// Current immutable document, suitable for encoding or application history.
  PdfDocument get document => _document;

  /// Groups synchronous edits atomically, restoring the snapshot on failure.
  void transaction(void Function(PdfEditor editor) update) {
    final PdfDocument before = _document;
    try {
      update(this);
    } on Object {
      _document = before;
      rethrow;
    }
  }

  /// Returns decoded instructions with the page's inherited color spaces.
  List<PdfOperation> pageOperations({required int pageIndex}) {
    final PdfPage page = _document.pages[pageIndex];
    final PdfDictionary resources = pageResources(pageIndex: pageIndex);
    final PdfValue? spaces = resources['ColorSpace'];
    return PdfContent.decode(
      _document.pageContent(page),
      limits: _document.limits,
      colorSpaces: spaces == null || _document.resolve(spaces) is PdfNull ? null : _document.dictionary(spaces),
      resolve: _document.resolve,
    );
  }

  /// Returns effective resources without modifying a shared ancestor.
  PdfDictionary pageResources({required int pageIndex}) {
    final PdfValue? value = _document.pages[pageIndex].inherited['Resources'];
    return value == null || _document.resolve(value) is PdfNull ? PdfDictionary() : _document.dictionary(value);
  }

  /// Resolves a named resource, returning PDF null when it is absent.
  PdfValue pageResource({required int pageIndex, required String category, required String name}) {
    final PdfValue? resources = pageResources(pageIndex: pageIndex)[category];
    if (resources == null || _document.resolve(resources) is PdfNull) {
      return const PdfNull();
    }
    return _document.resolve(_document.dictionary(resources)[name] ?? const PdfNull());
  }

  /// Replaces page instructions while leaving shared original streams intact.
  void setPageOperations({required int pageIndex, required Iterable<PdfOperation> operations, bool compress = true}) => setPageContent(
    pageIndex: pageIndex,
    bytes: PdfContent.encode(operations, limits: _document.limits),
    compress: compress,
  );

  /// Replaces all page content with one new stream.
  void setPageContent({required int pageIndex, required List<int> bytes, bool compress = true}) {
    final _PdfGraph edit = _PdfGraph(document: _document);
    final PdfStream stream = PdfStreams.encode(bytes: bytes, compress: compress, limits: _document.limits);
    edit.page(pageIndex, (page) => page.copyWith(values: {'Contents': edit.add(stream)}));
    _document = edit.build();
  }

  /// Commits a program and its resource bindings together on one page.
  ///
  /// Indirect resource references must belong to this document; use page import
  /// when copying resources from a different document.
  void setPageProgram({required int pageIndex, required PdfProgram program, bool compress = true}) {
    final _PdfGraph edit = _PdfGraph(document: _document);
    final PdfReference stream = edit.add(PdfStreams.encode(bytes: program.encode(), compress: compress, limits: _document.limits));
    edit.page(pageIndex, (page) => page.copyWith(values: {'Contents': stream, 'Resources': program.resources}));
    _document = edit.build();
  }

  /// Replaces only one Do invocation by assigning a fresh page resource name.
  ///
  /// Other invocations of the original image or form retain their resources.
  String replaceXObjectUse({required int pageIndex, required int operationIndex, required PdfStream value}) {
    final List<PdfOperation> operations = pageOperations(pageIndex: pageIndex).toList();
    final PdfOperation operation = operations[operationIndex];
    if (operation.operator != 'Do' || operation.operands.length != 1 || operation.operands.single is! PdfName || !['Image', 'Form'].contains(value.dictionary.name('Subtype'))) {
      throw const FormatException('Expected a Do invocation and an image or form XObject.');
    }
    final PdfEditor pending = PdfEditor(document: _document);
    final String name = pending.setPageResource(pageIndex: pageIndex, category: 'XObject', prefix: 'X', value: value);
    operations[operationIndex] = PdfOperation(
      operator: 'Do',
      operands: [PdfName(value: name)],
    );
    pending.setPageOperations(pageIndex: pageIndex, operations: operations);
    _document = pending.document;
    return name;
  }

  /// Sets one page rectangle in native PDF user coordinates.
  void setPageBox({required int pageIndex, required PdfArray bounds, String name = 'MediaBox'}) {
    if (!['MediaBox', 'CropBox', 'BleedBox', 'TrimBox', 'ArtBox'].contains(name)) {
      throw ArgumentError.value(name, 'name', 'Unknown page box.');
    }
    PdfResources.validateBox(bounds);
    setPageAttributes(pageIndex: pageIndex, values: {name: bounds});
  }

  /// Sets a page's absolute clockwise display rotation in multiples of 90.
  void setPageRotation({required int pageIndex, required int degrees}) {
    if (degrees % 90 != 0) {
      throw ArgumentError.value(degrees, 'degrees', 'Rotation must be a multiple of 90.');
    }
    setPageAttributes(
      pageIndex: pageIndex,
      values: {'Rotate': PdfNumber(value: degrees % 360)},
    );
  }

  /// Returns annotation references or direct dictionaries in page order.
  List<PdfValue> pageAnnotations({required int pageIndex}) {
    final PdfValue? value = _document.pages[pageIndex].dictionary['Annots'];
    final PdfValue resolved = _document.resolve(value ?? const PdfNull());
    return switch (resolved) {
      PdfNull() => const [],
      PdfArray(:final values) => values,
      _ => throw const FormatException('Page Annots must be an array.'),
    };
  }

  /// Replaces page annotation bindings without deleting referenced objects.
  ///
  /// Appearance streams, AcroForm field trees and structure tags remain the
  /// caller's responsibility. This method does not flatten annotations.
  void setPageAnnotations({required int pageIndex, required Iterable<PdfValue> annotations}) {
    final PdfArray values = PdfArray(values: annotations);
    values.values.forEach(_document.dictionary);
    setPageAttributes(pageIndex: pageIndex, values: {'Annots': values});
  }

  /// Adds foreground or background instructions in an isolated graphics state.
  ///
  /// Existing page content must have balanced q/Q operators. Original content
  /// bytes, including unknown operators and unsupported inline images, survive.
  void addPageContent({required int pageIndex, required List<int> bytes, bool foreground = true, bool compress = true}) {
    final PdfPage page = _document.pages[pageIndex];
    final List<int> original = _document.pageContent(page);
    final List<int> isolatedOriginal = [...ascii.encode('q\n'), ...original, ...ascii.encode('\nQ\n')];
    final List<int> isolatedAdded = [...ascii.encode('q\n'), ...bytes, ...ascii.encode('\nQ\n')];
    setPageContent(pageIndex: pageIndex, bytes: foreground ? [...isolatedOriginal, ...isolatedAdded] : [...isolatedAdded, ...isolatedOriginal], compress: compress);
  }

  /// Changes page entries, including boxes, rotation, annotations and metadata.
  ///
  /// Type and Parent belong to the page-tree editor. Use [setPageResource] to
  /// detach an inherited resource category before changing one of its entries.
  void setPageAttributes({required int pageIndex, Map<String, PdfValue> values = const {}, Set<String> remove = const {}}) {
    if (['Type', 'Parent', 'Kids', 'Count'].any((key) => values.containsKey(key) || remove.contains(key))) {
      throw ArgumentError('Use page-tree operations to change Type or Parent.');
    }
    for (final String key in ['MediaBox', 'CropBox', 'BleedBox', 'TrimBox', 'ArtBox']) {
      if (values[key] case final PdfValue box) {
        PdfResources.validateBox(_document.resolve(box));
      }
    }
    if (values['Rotate'] case final PdfValue value) {
      final PdfValue rotation = _document.resolve(value);
      if (rotation is! PdfNumber || rotation.integer % 90 != 0) {
        throw const FormatException('PDF rotation must be a multiple of 90 degrees.');
      }
    }
    final _PdfGraph edit = _PdfGraph(document: _document);
    edit.page(pageIndex, (page) => page.copyWith(values: values, remove: remove));
    _document = edit.build();
  }

  /// Sets a resource on this page only, allocating streams indirectly.
  ///
  /// Omitting [name] chooses an unused name with [prefix]. An explicit name
  /// replaces that binding for all uses on this page. Nested resources inside a
  /// Form XObject belong to the form, and are edited through its own dictionary.
  String setPageResource({required int pageIndex, required String category, required PdfValue value, String? name, String prefix = 'R'}) {
    final PdfDictionary resources = pageResources(pageIndex: pageIndex);
    final PdfValue? group = resources[category];
    final PdfDictionary entries = group == null || _document.resolve(group) is PdfNull ? PdfDictionary() : _document.dictionary(group);
    String selected = name ?? '${prefix}1';
    int suffix = 1;
    while (name == null && entries.values.containsKey(selected)) {
      selected = '$prefix${++suffix}';
    }
    PdfName(value: selected);
    PdfName(value: category);
    final _PdfGraph edit = _PdfGraph(document: _document);
    final PdfValue replacement = value is PdfStream ? edit.add(value) : value;
    final PdfDictionary updated = resources.copyWith(
      values: {
        category: entries.copyWith(values: {selected: replacement}),
      },
    );
    edit.page(pageIndex, (page) => page.copyWith(values: {'Resources': updated}));
    _document = edit.build();
    return selected;
  }

  /// Removes a page-local resource binding without deleting shared objects.
  ///
  /// The caller must also remove or replace instructions that use the name.
  void removePageResource({required int pageIndex, required String category, required String name}) {
    final PdfDictionary resources = pageResources(pageIndex: pageIndex);
    final PdfValue? group = resources[category];
    if (group == null || _document.resolve(group) is PdfNull) {
      return;
    }
    final PdfDictionary entries = _document.dictionary(group).copyWith(remove: {name});
    setPageAttributes(
      pageIndex: pageIndex,
      values: {
        'Resources': resources.copyWith(values: {category: entries}),
      },
    );
  }

  /// Inserts an independent page before [index], or appends when it is omitted.
  void insertPage({required PdfPageSource page, int? index, bool compress = true}) {
    final _PdfGraph edit = _PdfGraph(document: _document);
    final List<PdfPage> pages = _document.pages.toList();
    final int position = index ?? pages.length;
    RangeError.checkValueInInterval(position, 0, pages.length, 'index');
    final PdfReference content = edit.add(PdfStreams.encode(bytes: page.content, compress: compress, limits: _document.limits));
    final PdfDictionary dictionary = PdfDictionary(
      values: {
        'Type': PdfName(value: 'Page'),
        'MediaBox': PdfArray(
          values: [
            PdfNumber(value: 0),
            PdfNumber(value: 0),
            PdfNumber(value: page.width),
            PdfNumber(value: page.height),
          ],
        ),
        'Resources': page.resources,
        'Contents': content,
      },
    );
    pages.insert(position, PdfPage(dictionary: dictionary, inherited: dictionary, reference: edit.add(dictionary)));
    edit.setPages(pages);
    _document = edit.build();
  }

  /// Removes one page from the tree, retaining objects for external references.
  ///
  /// Document-level destinations, page labels, tags and AcroForm trees are not
  /// repaired automatically. This is not secure redaction or data erasure.
  void removePage({required int pageIndex}) {
    final List<PdfPage> pages = _document.pages.toList()..removeAt(pageIndex);
    final _PdfGraph edit = _PdfGraph(document: _document)..setPages(pages);
    _document = edit.build();
  }

  /// Moves a page to a zero-based index in the resulting page order.
  void movePage({required int from, required int to}) {
    final List<PdfPage> pages = _document.pages.toList();
    RangeError.checkValidIndex(to, pages, 'to');
    final PdfPage page = pages.removeAt(from);
    pages.insert(to, page);
    final _PdfGraph edit = _PdfGraph(document: _document)..setPages(pages);
    _document = edit.build();
  }

  /// Imports pages together, retaining shared resources and selected-page links.
  ///
  /// Object identifiers are remapped, including annotation owner references.
  /// Imports requiring global form, tagging, optional-content or destination
  /// merges fail explicitly. Opaque private stream bytes are never rewritten.
  void importPages({required PdfDocument source, required List<int> pageIndices, int? index}) {
    final _PdfGraph edit = _PdfGraph(document: _document);
    edit.importPages(source: source, pageIndices: pageIndices, at: index ?? _document.pages.length);
    _document = edit.build();
  }

  /// Imports one page with the same preservation checks as [importPages].
  void importPage({required PdfDocument source, required int pageIndex, int? index}) => importPages(source: source, pageIndices: [pageIndex], index: index);

  /// Duplicates a page with independent resource objects and annotation owners.
  void duplicatePage({required int pageIndex, int? index}) => importPage(source: _document, pageIndex: pageIndex, index: index ?? pageIndex + 1);

  /// Adds a new indirect object without reusing any dangling reference number.
  PdfReference addObject({required PdfValue value}) {
    final _PdfGraph edit = _PdfGraph(document: _document);
    final PdfReference reference = edit.add(value);
    _document = edit.build();
    return reference;
  }

  /// Replaces an existing object globally, including all shared uses.
  void replaceObject({required PdfReference reference, required PdfValue value}) {
    if (!_document.objects.containsKey(reference)) {
      throw ArgumentError.value(reference, 'reference', 'No such PDF object');
    }
    final _PdfGraph edit = _PdfGraph(document: _document);
    edit.objects[reference] = value;
    _document = edit.build();
  }

  /// Replaces a shared decoded stream while retaining its other attributes.
  void replaceStream({required PdfReference reference, required List<int> bytes, bool compress = true}) {
    final PdfValue value = _document.resolve(reference);
    if (value is! PdfStream) {
      throw const FormatException('Expected a stream object to replace.');
    }
    replaceObject(
      reference: reference,
      value: PdfStreams.encode(bytes: bytes, dictionary: value.dictionary, compress: compress, limits: _document.limits),
    );
  }

  /// Replaces the catalog's XMP packet without changing information entries.
  void setMetadata({required List<int> xml}) => transaction((editor) {
    final PdfReference reference = editor.addObject(
      value: PdfStreams.encode(
        bytes: xml,
        compress: false,
        limits: _document.limits,
        dictionary: PdfDictionary(
          values: {
            'Type': PdfName(value: 'Metadata'),
            'Subtype': PdfName(value: 'XML'),
          },
        ),
      ),
    );
    editor.setCatalogEntries(values: {'Metadata': reference});
  });

  /// Updates catalog features while retaining unknown entries and root identity.
  void setCatalogEntries({Map<String, PdfValue> values = const {}, Set<String> remove = const {}}) {
    if (['Type', 'Pages'].any((key) => values.containsKey(key) || remove.contains(key))) {
      throw ArgumentError('Use page-tree operations to change Type or Pages.');
    }
    final _PdfGraph edit = _PdfGraph(document: _document)..setCatalog(_document.catalog.copyWith(values: values, remove: remove));
    _document = edit.build();
  }

  /// Updates the document information dictionary without discarding custom keys.
  void setInformation({Map<String, PdfValue> values = const {}, Set<String> remove = const {}}) {
    final PdfValue? old = _document.trailer['Info'];
    final PdfDictionary information = old == null || _document.resolve(old) is PdfNull ? PdfDictionary() : _document.dictionary(old);
    final _PdfGraph edit = _PdfGraph(document: _document);
    edit.trailer = edit.trailer.copyWith(
      values: {'Info': edit.add(information.copyWith(values: values, remove: remove))},
    );
    _document = edit.build();
  }
}

/// Copy-based document editing, matching the immutable format-kit convention.
extension PdfDocumentEditing on PdfDocument {
  /// Applies an isolated transaction and returns the new immutable document.
  PdfDocument edited(void Function(PdfEditor editor) update) {
    final PdfEditor editor = PdfEditor(document: this);
    update(editor);
    return editor.document;
  }
}
