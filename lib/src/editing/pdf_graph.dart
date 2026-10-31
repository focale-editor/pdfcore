part of 'package:pdfcore/src/editing/pdf_editor.dart';

/// Isolates pending graph changes so validation failures cannot partially commit.
final class _PdfGraph {
  /// Source snapshot and limits.
  final PdfDocument original;

  /// Mutable object map owned only by this operation.
  final Map<PdfReference, PdfValue> objects;

  /// Pending trailer.
  PdfDictionary trailer;

  /// Reserved object numbers, including dangling references.
  final Set<int> _reserved = {};

  /// Immutable direct containers already scanned in this transaction.
  final Set<PdfValue> _visited = {};

  /// Next candidate identifier.
  int _next = 1;

  /// Copies the graph and records references without following their cycles.
  _PdfGraph({required PdfDocument document}) : original = document, objects = {...document.objects}, trailer = document.trailer {
    _reserved.addAll(objects.keys.map((reference) => reference.objectNumber));
    _reserveNew(trailer, 0);
    for (final PdfValue value in objects.values) {
      _reserveNew(value, 0);
    }
  }

  /// Reserves references in newly supplied direct containers before allocation.
  void _reserveNew(PdfValue value, int depth) {
    if (depth > original.limits.maxDepth) {
      throw const FormatException('PDF edit exceeds the value depth limit.');
    }
    if (!_visited.add(value)) {
      return;
    }
    switch (value) {
      case PdfReference(:final objectNumber):
        _reserved.add(objectNumber);
      case PdfArray(:final values):
        for (final PdfValue item in values) {
          _reserveNew(item, depth + 1);
        }
      case PdfDictionary(:final values):
        for (final PdfValue item in values.values) {
          _reserveNew(item, depth + 1);
        }
      case PdfStream(:final dictionary):
        _reserveNew(dictionary, depth + 1);
      default:
        break;
    }
  }

  /// Allocates a fresh number under the encoder's xref-range limit.
  PdfReference add(PdfValue value) {
    _reserveNew(value, 0);
    while (_reserved.contains(_next)) {
      _next++;
    }
    if (objects.length >= original.limits.maxObjects || _next >= original.limits.maxObjects) {
      throw const FormatException('PDF edit exceeds the object limit.');
    }
    final PdfReference reference = PdfReference(objectNumber: _next++);
    _reserved.add(reference.objectNumber);
    objects[reference] = value;
    return reference;
  }

  /// Updates one page in place, materializing only malformed direct page leaves.
  void page(int index, PdfDictionary Function(PdfDictionary) update) {
    final List<PdfPage> current = original.pages;
    final PdfPage selected = current[index];
    final PdfDictionary replacement = update(selected.dictionary);
    if (selected.reference case final PdfReference reference) {
      objects[reference] = replacement;
    } else {
      /// Locates the inherited attributes before the direct leaf's own entries.
      Map<String, PdfValue>? parentAttributes(PdfValue value, Map<String, PdfValue> inherited) {
        final PdfDictionary node = original.dictionary(value);
        if (identical(node, selected.dictionary)) {
          return inherited;
        }
        if (node.name('Type') != 'Pages') {
          return null;
        }
        final Map<String, PdfValue> attributes = {...inherited};
        for (final String key in ['Resources', 'MediaBox', 'CropBox', 'Rotate']) {
          if (node[key] case final PdfValue value when value is! PdfNull) {
            attributes[key] = value;
          }
        }
        final PdfArray children = original.resolve(node['Kids']!) as PdfArray;
        for (final PdfValue child in children.values) {
          final Map<String, PdfValue>? found = parentAttributes(child, attributes);
          if (found != null) {
            return found;
          }
        }
        return null;
      }

      final Map<String, PdfValue> inherited = parentAttributes(original.catalog['Pages']!, {}) ?? {};
      for (final String key in ['Resources', 'MediaBox', 'CropBox', 'Rotate']) {
        if (replacement[key] case final PdfValue value when value is! PdfNull) {
          inherited[key] = value;
        }
      }
      setPages([
        for (int position = 0; position < current.length; position++)
          if (position == index)
            PdfPage(
              dictionary: replacement,
              inherited: PdfDictionary(values: inherited),
            )
          else
            current[position],
      ]);
    }
  }

  /// Rebuilds only the page tree, materializing inherited values before moving.
  void setPages(List<PdfPage> pages) {
    if (pages.length > original.limits.maxPages) {
      throw const FormatException('PDF edit exceeds the page limit.');
    }
    final PdfValue originalRoot = original.catalog['Pages']!;
    final PdfReference root = originalRoot is PdfReference ? originalRoot : add(const PdfNull());
    final List<PdfReference> children = [];
    for (final PdfPage page in pages) {
      final PdfDictionary dictionary = page.dictionary.copyWith(values: {...page.inherited.values, 'Parent': root});
      final PdfReference reference = page.reference ?? add(dictionary);
      objects[reference] = dictionary;
      children.add(reference);
    }
    objects[root] = original
        .dictionary(originalRoot)
        .copyWith(
          values: {
            'Type': PdfName(value: 'Pages'),
            'Kids': PdfArray(values: children),
            'Count': PdfNumber(value: pages.length),
          },
          remove: {'Parent', 'Resources', 'MediaBox', 'CropBox', 'Rotate'},
        );
    setCatalog(original.catalog.copyWith(values: {'Pages': root}));
  }

  /// Keeps an indirect root identity when the original already has one.
  void setCatalog(PdfDictionary value) {
    final PdfValue? original = trailer['Root'];
    final PdfReference reference = original is PdfReference ? original : add(value);
    objects[reference] = value;
    trailer = trailer.copyWith(values: {'Root': reference});
  }

  /// Validates the resulting page graph before exposing an immutable snapshot.
  PdfDocument build() {
    final PdfDocument result = original.copyWith(objects: objects, trailer: trailer);
    if (result.catalog.name('Type') != 'Catalog') {
      throw const FormatException('Edited PDF root must remain a Catalog.');
    }
    result.pages;
    return result;
  }
}
