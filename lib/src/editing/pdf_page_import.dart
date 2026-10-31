part of 'package:pdfcore/src/editing/pdf_editor.dart';

/// Clones page-local graphs while retaining sharing and reference cycles.
extension _PdfPageImport on _PdfGraph {
  /// Imports a bounded selection with an explicit policy for global structures.
  void importPages({required PdfDocument source, required List<int> pageIndices, required int at}) {
    final List<PdfPage> destinationPages = original.pages.toList();
    RangeError.checkValueInInterval(at, 0, destinationPages.length, 'at');
    if (pageIndices.isEmpty) {
      return;
    }
    source.limits.validate();
    if (source.resolve(source.trailer['Encrypt'] ?? const PdfNull()) is! PdfNull) {
      throw const PdfUnsupportedException(message: 'Importing encrypted PDFs is unsupported.');
    }
    for (final String key in ['AcroForm', 'StructTreeRoot', 'OCProperties', 'Dests']) {
      if (source.resolve(source.catalog[key] ?? const PdfNull()) is! PdfNull) {
        throw PdfUnsupportedException(message: 'Importing /$key requires an explicit document merge policy.');
      }
    }
    final PdfValue names = source.resolve(source.catalog['Names'] ?? const PdfNull());
    if (names is PdfDictionary && names['Dests'] != null) {
      throw const PdfUnsupportedException(message: 'Importing named destinations requires a document merge policy.');
    }
    final List<PdfPage> sourcePages = source.pages;
    final Set<int> selected = {};
    final Map<PdfReference, PdfReference> references = {};
    final List<PdfReference> targets = [];
    for (final int index in pageIndices) {
      RangeError.checkValidIndex(index, sourcePages, 'pageIndices');
      if (!selected.add(index)) {
        throw ArgumentError('Import each page once per operation; use another import to duplicate it.');
      }
      final PdfReference target = add(const PdfNull());
      targets.add(target);
      if (sourcePages[index].reference case final PdfReference reference) {
        references[reference] = target;
      }
    }

    /// Copies values without ever interpreting binary payloads as references.
    PdfValue clone(PdfValue value, int depth) {
      if (depth > original.limits.maxDepth) {
        throw const FormatException('PDF import exceeds the reference depth limit.');
      }
      switch (value) {
        case PdfReference():
          if (references[value] case final PdfReference mapped) {
            return mapped;
          }
          final PdfValue? resolved = source.objects[value];
          if (resolved == null) {
            return const PdfNull();
          }
          if (resolved is PdfDictionary && ['Page', 'Pages', 'Catalog'].contains(resolved.name('Type'))) {
            throw const PdfUnsupportedException(message: 'Imported content links outside the selected pages.');
          }
          final PdfReference target = add(const PdfNull());
          references[value] = target;
          objects[target] = clone(resolved, depth + 1);
          return target;
        case PdfArray(:final values):
          return PdfArray(values: values.map((item) => clone(item, depth + 1)));
        case PdfDictionary(:final values):
          if (value.name('Subtype') == 'Widget' || value['StructParent'] != null || value['StructParents'] != null || value['OC'] != null) {
            throw const PdfUnsupportedException(message: 'Importing forms, structure tags or optional content needs a document merge policy.');
          }
          for (final String key in ['Dest', if (value.name('S') == 'GoTo') 'D']) {
            final PdfValue destination = source.resolve(value[key] ?? const PdfNull());
            if (destination is PdfName || destination is PdfString) {
              throw const PdfUnsupportedException(message: 'Importing named destinations requires a document merge policy.');
            }
          }
          return PdfDictionary(values: {for (final MapEntry<String, PdfValue> entry in values.entries) entry.key: clone(entry.value, depth + 1)});
        case PdfStream(:final dictionary, :final data):
          return PdfStream(dictionary: clone(dictionary, depth + 1) as PdfDictionary, data: data);
        default:
          return value;
      }
    }

    final List<PdfPage> imported = [];
    for (int index = 0; index < pageIndices.length; index++) {
      final PdfPage page = sourcePages[pageIndices[index]];
      final PdfDictionary materialized = page.dictionary.copyWith(values: page.inherited.values, remove: {'Parent'});
      final PdfDictionary dictionary = clone(materialized, 0) as PdfDictionary;
      objects[targets[index]] = dictionary;
      imported.add(
        PdfPage(
          dictionary: dictionary,
          inherited: dictionary.copyWith(remove: dictionary.values.keys.where((key) => !['Resources', 'MediaBox', 'CropBox', 'Rotate'].contains(key)).toSet()),
          reference: targets[index],
        ),
      );
    }
    destinationPages.insertAll(at, imported);
    setPages(destinationPages);
    final String sourceVersion = source.catalog.name('Version') ?? source.version;
    final String destinationVersion = original.catalog.name('Version') ?? original.version;
    if (sourceVersion.compareTo(destinationVersion) > 0) {
      setCatalog(build().catalog.copyWith(values: {'Version': PdfName(value: sourceVersion)}));
    }
  }
}
