import 'dart:typed_data';

import 'package:pdfcore/src/codec/pdf_filters.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// Resource limits for PDF syntax, graphs and stream decoding.
final class PdfLimits {
  /// Maximum source or encoded file size.
  final int maxFileBytes;

  /// Maximum decoded bytes in one stream.
  final int maxStreamBytes;

  /// Aggregate decoded bytes used while reading object and xref streams.
  final int maxDecodedBytes;

  /// Maximum number of cross-reference entries and objects.
  final int maxObjects;

  /// Maximum nesting, reference chain or page-tree depth.
  final int maxDepth;

  /// Maximum pages visited in a page tree.
  final int maxPages;

  /// Creates portable in-memory limits.
  const PdfLimits({
    this.maxFileBytes = 128 * 1024 * 1024,
    this.maxStreamBytes = 64 * 1024 * 1024,
    this.maxDecodedBytes = 256 * 1024 * 1024,
    this.maxObjects = 200000,
    this.maxDepth = 128,
    this.maxPages = 10000,
  });

  /// Rejects unusable limits before parsing or writing.
  void validate() {
    if ([maxFileBytes, maxStreamBytes, maxDecodedBytes, maxObjects, maxDepth, maxPages].any((value) => value <= 0)) {
      throw ArgumentError('PDF limits must be positive.');
    }
  }
}

/// A complete immutable PDF object graph at the latest file revision.
final class PdfDocument {
  /// Header version, such as 1.7 or 2.0.
  final String version;

  /// Live indirect objects, preserving their identifiers and generations.
  final Map<PdfReference, PdfValue> objects;

  /// Latest effective trailer, including catalog and optional metadata links.
  final PdfDictionary trailer;

  /// Resource policy for graph traversal and stream decoding.
  final PdfLimits limits;

  /// Copies the object map without altering immutable values.
  PdfDocument({this.version = '1.7', required Map<PdfReference, PdfValue> objects, required this.trailer, this.limits = const PdfLimits()}) : objects = Map.unmodifiable(objects);

  /// Creates a PDF from independent page content streams.
  ///
  /// Resources are direct dictionaries; the caller supplies font or image
  /// objects through [copyWith] when content refers to indirect resources.
  factory PdfDocument.fromPages({required List<PdfPageSource> pages}) {
    const PdfReference catalog = PdfReference(objectNumber: 1);
    const PdfReference tree = PdfReference(objectNumber: 2);
    final Map<PdfReference, PdfValue> objects = {};
    final List<PdfValue> children = [];
    for (int index = 0; index < pages.length; index++) {
      final PdfPageSource page = pages[index];
      final PdfReference reference = PdfReference(objectNumber: 3 + index * 2);
      final PdfReference content = PdfReference(objectNumber: 4 + index * 2);
      children.add(reference);
      objects[reference] = PdfDictionary(
        values: {
          'Type': PdfName(value: 'Page'),
          'Parent': tree,
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
      objects[content] = PdfStream(dictionary: PdfDictionary(), data: page.content);
    }
    objects[catalog] = PdfDictionary(
      values: {
        'Type': PdfName(value: 'Catalog'),
        'Pages': tree,
      },
    );
    objects[tree] = PdfDictionary(
      values: {
        'Type': PdfName(value: 'Pages'),
        'Kids': PdfArray(values: children),
        'Count': PdfNumber(value: pages.length),
      },
    );
    return PdfDocument(
      objects: objects,
      trailer: PdfDictionary(values: {'Root': catalog}),
    );
  }

  /// Replaces selected document components while preserving other objects.
  PdfDocument copyWith({Map<PdfReference, PdfValue>? objects, PdfDictionary? trailer, String? version}) =>
      PdfDocument(version: version ?? this.version, objects: objects ?? this.objects, trailer: trailer ?? this.trailer, limits: limits);

  /// Resolves references; undefined objects are PDF null, and cycles fail.
  PdfValue resolve(PdfValue value) {
    PdfValue current = value;
    final Set<PdfReference> visited = {};
    while (current is PdfReference) {
      if (!visited.add(current) || visited.length > limits.maxDepth) {
        throw const FormatException('Cyclic or excessive PDF reference chain.');
      }
      current = objects[current] ?? const PdfNull();
    }
    return current;
  }

  /// Requires a resolved dictionary.
  PdfDictionary dictionary(PdfValue value) => switch (resolve(value)) {
    final PdfDictionary dictionary => dictionary,
    _ => throw const FormatException('Expected PDF dictionary.'),
  };

  /// Root catalog dictionary.
  PdfDictionary get catalog => dictionary(trailer['Root'] ?? (throw const FormatException('PDF trailer has no Root.')));

  /// Ordered page leaves with inherited resources, boxes and rotation.
  List<PdfPage> get pages {
    final List<PdfPage> result = [];
    final Set<PdfReference> visited = {};

    /// Visits each page-tree node once and carries inherited attributes.
    void visit(PdfValue value, Map<String, PdfValue> inherited, int depth) {
      if (depth > limits.maxDepth || (value is PdfReference && !visited.add(value))) {
        throw const FormatException('Cyclic or excessive PDF page tree.');
      }
      final PdfDictionary node = dictionary(value);
      final Map<String, PdfValue> attributes = {...inherited};
      for (final String key in ['Resources', 'MediaBox', 'CropBox', 'Rotate']) {
        if (node[key] case final PdfValue item when item is! PdfNull) {
          attributes[key] = item;
        }
      }
      if (node.name('Type') == 'Page') {
        if (result.length >= limits.maxPages) {
          throw const FormatException('PDF page count exceeds the limit.');
        }
        result.add(
          PdfPage(
            dictionary: node,
            inherited: PdfDictionary(values: attributes),
            reference: value is PdfReference ? value : null,
          ),
        );
        return;
      }
      if (node.name('Type') != 'Pages') {
        throw const FormatException('Invalid PDF page-tree node type.');
      }
      final PdfValue? kids = node['Kids'];
      if (kids == null || resolve(kids) is! PdfArray) {
        throw const FormatException('PDF page tree has no Kids array.');
      }
      for (final PdfValue child in (resolve(kids) as PdfArray).values) {
        visit(child, attributes, depth + 1);
      }
    }

    visit(catalog['Pages'] ?? (throw const FormatException('PDF catalog has no Pages.')), {}, 0);
    return List.unmodifiable(result);
  }

  /// Decodes a stream's filter chain under this document's byte limit.
  Uint8List decodeStream(PdfStream stream) => PdfFilters.decode(stream, limits: limits, resolve: resolve);

  /// Concatenates decoded page content exactly, including tokens split across streams.
  Uint8List pageContent(PdfPage page) {
    final PdfValue? contents = page.dictionary['Contents'];
    if (contents == null || contents is PdfNull) {
      return Uint8List(0);
    }
    final PdfValue resolved = resolve(contents);
    if (resolved is PdfNull) {
      return Uint8List(0);
    }
    final List<PdfValue> streams = resolved is PdfArray ? resolved.values : [resolved];
    final BytesBuilder result = BytesBuilder(copy: false);
    for (final PdfValue value in streams) {
      final PdfValue stream = resolve(value);
      if (stream is! PdfStream) {
        throw const FormatException('Page content must be a stream.');
      }
      final Uint8List bytes = decodeStream(stream);
      if (result.length + bytes.length > limits.maxDecodedBytes) {
        throw const FormatException('Page content exceeds the decoded byte limit.');
      }
      result.add(bytes);
    }
    return result.takeBytes();
  }
}

/// A PDF page leaf plus inherited page-tree attributes.
final class PdfPage {
  /// Page's own entries, including content references and annotations.
  final PdfDictionary dictionary;

  /// Effective inherited Resources, MediaBox, CropBox and Rotate entries.
  final PdfDictionary inherited;

  /// Original indirect reference, when the page is indirect.
  final PdfReference? reference;

  /// Creates an immutable page view.
  const PdfPage({required this.dictionary, required this.inherited, this.reference});
}

/// A page supplied to [PdfDocument.fromPages].
final class PdfPageSource {
  /// Positive width in PDF points.
  final double width;

  /// Positive height in PDF points.
  final double height;

  /// Owned uncompressed PDF graphics instructions.
  final Uint8List _content;

  /// Resources used by the instructions.
  final PdfDictionary resources;

  /// Creates one page without imposing any drawing API.
  PdfPageSource({required this.width, required this.height, required List<int> content, PdfDictionary? resources}) : _content = Uint8List.fromList(content), resources = resources ?? PdfDictionary() {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      throw const FormatException('PDF page dimensions must be positive and finite.');
    }
  }

  /// Read-only uncompressed content bytes.
  Uint8List get content => _content.asUnmodifiableView();
}
