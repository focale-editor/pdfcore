import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfcore/src/codec/pdf_filters.dart';
import 'package:pdfcore/src/codec/pdf_syntax.dart';
import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// One live or free cross-reference entry.
final class _Entry {
  /// Free, uncompressed or compressed entry type.
  final int type;

  /// Byte offset, object-stream number or free-list link.
  final int first;

  /// Generation or object-stream index.
  final int second;

  /// Creates an xref record.
  const _Entry({required this.type, required this.first, required this.second});
}

/// Parsed indirect object and its identifier.
typedef _Indirect = ({PdfReference reference, PdfValue value});

/// Resolves the latest PDF revision using authoritative cross references.
final class PdfFileReader {
  /// Owned source bytes.
  final Uint8List bytes;

  /// Bounded parsing policy.
  final PdfLimits limits;

  /// Explicitly permitted duplicate dictionary keys.
  final Set<String> duplicateKeys;

  /// Latest effective entries, including tombstones.
  final Map<int, _Entry> _entries = {};

  /// Decoded live object cache.
  final Map<PdfReference, PdfValue> _objects = {};

  /// Objects currently being resolved, to detect length/reference cycles.
  final Set<PdfReference> _reading = {};

  /// Cached decoded object-stream payloads and headers.
  final Map<int, ({Uint8List bytes, List<int> numbers, List<int> offsets, int first})> _objectStreams = {};

  /// Offsets already visited in the revision chain.
  final Set<int> _sections = {};

  /// Version-dependent PDF name escape policy.
  bool _nameEscapes = true;

  /// Aggregate decoded xref and object-stream bytes.
  int _decodedBytes = 0;

  /// Creates a complete-file parser.
  PdfFileReader({required this.bytes, required this.limits, this.duplicateKeys = const {}});

  /// Reads header, revisions, all live objects and the page tree.
  PdfDocument read() {
    limits.validate();
    if (bytes.length > limits.maxFileBytes || bytes.length < 8) {
      throw const FormatException('Invalid or excessive PDF file size.');
    }
    final String header = latin1.decode(Uint8List.sublistView(bytes, 0, math.min(32, bytes.length)));
    final RegExpMatch? version = RegExp(r'^%PDF-(1\.[0-7]|2\.0)(?:\s|%)').firstMatch(header);
    if (version == null) {
      throw const FormatException('Unsupported PDF header.');
    }
    _nameEscapes = version[1] != '1.0' && version[1] != '1.1';
    final int tailStart = math.max(0, bytes.length - 65536);
    final String tail = latin1.decode(Uint8List.sublistView(bytes, tailStart));
    final List<RegExpMatch> starts = RegExp(r'startxref[\x00\t\n\f\r ]+(\d+)[\x00\t\n\f\r ]+%%EOF').allMatches(tail).toList();
    if (starts.isEmpty) {
      throw const FormatException('PDF has no final startxref/EOF.');
    }
    final RegExpMatch last = starts.last;
    if (tail.substring(last.end).codeUnits.any((byte) => !PdfSyntaxReader.isSpace(byte))) {
      throw const FormatException('Unexpected data after PDF EOF.');
    }
    int? offset = int.tryParse(last[1]!);
    if (offset == null) {
      throw const FormatException('Invalid PDF xref offset.');
    }
    final Map<String, PdfValue> trailer = {};
    while (offset != null) {
      final ({Map<int, _Entry> entries, PdfDictionary trailer}) section = _section(offset);
      final Map<int, _Entry> entries = section.entries;
      final int? hybrid = section.trailer.integer('XRefStm');
      if (hybrid != null) {
        final ({Map<int, _Entry> entries, PdfDictionary trailer}) supplement = _section(hybrid, streamOnly: true);
        entries.addAll(supplement.entries);
      }
      for (final MapEntry<int, _Entry> entry in entries.entries) {
        _entries.putIfAbsent(entry.key, () => entry.value);
      }
      if (_entries.length > limits.maxObjects) {
        throw const FormatException('PDF object count exceeds the limit.');
      }
      for (final MapEntry<String, PdfValue> entry in section.trailer.values.entries) {
        trailer.putIfAbsent(entry.key, () => entry.value);
      }
      offset = section.trailer.integer('Prev');
    }
    if (trailer['Encrypt'] != null && trailer['Encrypt'] is! PdfNull) {
      throw const PdfUnsupportedException(message: 'Encrypted PDFs require a decryption provider.');
    }
    for (final MapEntry<int, _Entry> entry in _entries.entries) {
      if (entry.value.type != 0 && entry.key != 0) {
        _resolve(PdfReference(objectNumber: entry.key, generation: entry.value.type == 2 ? 0 : entry.value.second));
      }
    }
    final PdfDocument document = PdfDocument(
      version: version[1]!,
      objects: _objects,
      trailer: PdfDictionary(values: trailer),
      limits: limits,
    );
    if (document.catalog.name('Type') != 'Catalog') {
      throw const FormatException('PDF Root is not a catalog.');
    }
    document.pages;
    return document;
  }

  /// Reads one xref section without applying its precedence yet.
  ({Map<int, _Entry> entries, PdfDictionary trailer}) _section(int offset, {bool streamOnly = false}) {
    if (offset < 0 || offset >= bytes.length || !_sections.add(offset) || _sections.length > limits.maxDepth) {
      throw const FormatException('Invalid, cyclic or excessive PDF revision chain.');
    }
    final PdfSyntaxReader reader = PdfSyntaxReader(bytes: bytes, limits: limits, duplicateKeys: duplicateKeys, position: offset, nameEscapes: _nameEscapes);
    final Map<int, _Entry> entries = {};
    if (!streamOnly && reader.consume('xref')) {
      while (!reader.consume('trailer')) {
        final int first = reader.unsigned();
        final int count = reader.unsigned();
        if (count > limits.maxObjects || entries.length + count > limits.maxObjects || first + count > 9007199254740991) {
          throw const FormatException('PDF xref subsection exceeds the limit.');
        }
        for (int index = 0; index < count; index++) {
          final int position = reader.unsigned();
          final int generation = reader.unsigned();
          final String kind = reader.token();
          if (generation > 65535 || (kind != 'n' && kind != 'f') || entries.containsKey(first + index)) {
            throw const FormatException('Invalid PDF cross-reference entry.');
          }
          entries[first + index] = _Entry(type: kind == 'n' ? 1 : 0, first: position, second: generation);
        }
      }
      final PdfValue trailer = reader.value();
      if (trailer is! PdfDictionary) {
        throw const FormatException('PDF trailer must be a dictionary.');
      }
      return (entries: entries, trailer: trailer);
    }
    final _Indirect object = _indirect(offset, resolveLength: false);
    final PdfValue value = object.value;
    if (value is! PdfStream || value.dictionary.name('Type') != 'XRef') {
      throw const FormatException('Expected a PDF xref stream.');
    }
    final PdfDictionary dictionary = value.dictionary;
    final PdfValue? widthsValue = dictionary['W'];
    if (widthsValue is! PdfArray || widthsValue.values.length != 3) {
      throw const FormatException('Invalid PDF xref stream widths.');
    }
    final List<int> widths = widthsValue.values.map(_integer).toList();
    if (widths.any((width) => width < 0 || width > 6) || widths.reduce((a, b) => a + b) == 0) {
      throw const PdfUnsupportedException(message: 'Unsupported PDF xref field width.');
    }
    final int? size = dictionary.integer('Size');
    if (size == null || size <= 0) {
      throw const FormatException('Invalid PDF xref Size.');
    }
    final PdfValue? rangesValue = dictionary['Index'];
    if (rangesValue != null && rangesValue is! PdfArray) {
      throw const FormatException('Invalid PDF xref Index.');
    }
    final List<int> ranges = rangesValue is PdfArray ? rangesValue.values.map(_integer).toList() : [0, size];
    if (ranges.length.isOdd) {
      throw const FormatException('Invalid PDF xref Index pairs.');
    }
    final Uint8List data = _decode(value);
    int position = 0;
    for (int range = 0; range < ranges.length; range += 2) {
      final int first = ranges[range];
      final int count = ranges[range + 1];
      if (first < 0 || count < 0 || first + count > size || entries.length + count > limits.maxObjects) {
        throw const FormatException('Invalid or excessive PDF xref Index range.');
      }
      for (int index = 0; index < count; index++) {
        final List<int> fields = [];
        for (int field = 0; field < 3; field++) {
          int number = field == 0 && widths[0] == 0 ? 1 : 0;
          for (int byte = 0; byte < widths[field]; byte++) {
            if (position >= data.length) {
              throw const FormatException('Truncated PDF xref stream.');
            }
            number = number * 256 + data[position++];
          }
          fields.add(number);
        }
        if (fields[0] > 2 || entries.containsKey(first + index)) {
          throw const FormatException('Invalid PDF xref stream entry.');
        }
        entries[first + index] = _Entry(type: fields[0], first: fields[1], second: fields[2]);
      }
    }
    if (position != data.length) {
      throw const FormatException('Unexpected PDF xref stream trailing bytes.');
    }
    // The section pointer identifies the xref stream itself authoritatively;
    // hybrid producers can retain an outdated self-entry in its payload.
    entries[object.reference.objectNumber] = _Entry(type: 1, first: offset, second: object.reference.generation);
    return (entries: entries, trailer: dictionary);
  }

  /// Reads an indirect body using its exact declared stream length.
  _Indirect _indirect(int offset, {bool resolveLength = true}) {
    if (offset < 0 || offset >= bytes.length) {
      throw const FormatException('PDF object offset is outside the file.');
    }
    final PdfSyntaxReader reader = PdfSyntaxReader(bytes: bytes, limits: limits, duplicateKeys: duplicateKeys, position: offset, nameEscapes: _nameEscapes);
    final int number = reader.unsigned();
    final int generation = reader.unsigned();
    if (number <= 0 || generation > 65535) {
      throw const FormatException('Invalid PDF object identifier.');
    }
    reader.expect('obj');
    PdfValue value = reader.value();
    if (value is PdfDictionary && reader.consume('stream')) {
      if (reader.position < bytes.length && bytes[reader.position] == 13) {
        reader.position++;
        if (reader.position < bytes.length && bytes[reader.position] == 10) {
          reader.position++;
        }
      } else if (reader.position < bytes.length && bytes[reader.position] == 10) {
        reader.position++;
      } else {
        throw const FormatException('PDF stream requires an end-of-line marker.');
      }
      PdfValue? lengthValue = value['Length'];
      if (lengthValue is PdfReference && resolveLength) {
        lengthValue = _resolve(lengthValue);
      }
      final int length = _integer(lengthValue);
      if (length < 0 || length > bytes.length - reader.position) {
        throw const FormatException('Invalid or truncated PDF stream length.');
      }
      final Uint8List data = Uint8List.sublistView(bytes, reader.position, reader.position + length);
      reader.position += length;
      reader.expect('endstream');
      value = PdfStream(dictionary: value, data: data);
    }
    reader.expect('endobj');
    return (reference: PdfReference(objectNumber: number, generation: generation), value: value);
  }

  /// Resolves an object once, including objects compressed into ObjStm streams.
  PdfValue _resolve(PdfReference reference) {
    if (_objects[reference] case final PdfValue cached) {
      return cached;
    }
    if (!_reading.add(reference) || _reading.length > limits.maxDepth) {
      throw const FormatException('Cyclic or excessive PDF object dependency.');
    }
    try {
      final _Entry? entry = _entries[reference.objectNumber];
      if (entry == null || entry.type == 0 || (entry.type == 1 && entry.second != reference.generation) || (entry.type == 2 && reference.generation != 0)) {
        throw FormatException('Missing live PDF object $reference.');
      }
      final PdfValue value;
      if (entry.type == 1) {
        final _Indirect object = _indirect(entry.first);
        if (object.reference != reference) {
          throw const FormatException('PDF xref does not match object header.');
        }
        value = object.value;
      } else {
        final ({Uint8List bytes, List<int> numbers, List<int> offsets, int first}) stream = _loadObjectStream(entry.first);
        if (entry.second >= stream.numbers.length || stream.numbers[entry.second] != reference.objectNumber) {
          throw const FormatException('PDF compressed object index does not match.');
        }
        final int start = stream.first + stream.offsets[entry.second];
        final int end = entry.second + 1 < stream.offsets.length ? stream.first + stream.offsets[entry.second + 1] : stream.bytes.length;
        final PdfSyntaxReader reader = PdfSyntaxReader(bytes: Uint8List.sublistView(stream.bytes, start, end), limits: limits, duplicateKeys: duplicateKeys);
        value = reader.value();
        if (!reader.isDone) {
          throw const FormatException('Unexpected compressed object trailing tokens.');
        }
      }
      _objects[reference] = value;
      return value;
    } finally {
      _reading.remove(reference);
    }
  }

  /// Decodes and validates an object-stream header once.
  ({Uint8List bytes, List<int> numbers, List<int> offsets, int first}) _loadObjectStream(int number) {
    if (_objectStreams[number] case final cached?) {
      return cached;
    }
    final _Entry? entry = _entries[number];
    if (entry == null || entry.type != 1) {
      throw const FormatException('PDF object stream must be uncompressed.');
    }
    final PdfValue value = _resolve(PdfReference(objectNumber: number, generation: entry.second));
    if (value is! PdfStream || value.dictionary.name('Type') != 'ObjStm') {
      throw const FormatException('Expected PDF object stream.');
    }
    final int? count = value.dictionary.integer('N');
    final int? first = value.dictionary.integer('First');
    final Uint8List data = _decode(value);
    if (count == null || first == null || count < 0 || count > limits.maxObjects || first < 0 || first > data.length) {
      throw const FormatException('Invalid PDF object stream header.');
    }
    final PdfSyntaxReader reader = PdfSyntaxReader(bytes: Uint8List.sublistView(data, 0, first), limits: limits, duplicateKeys: duplicateKeys);
    final List<int> numbers = [];
    final List<int> offsets = [];
    final Set<int> seen = {};
    for (int index = 0; index < count; index++) {
      final int object = reader.unsigned();
      final int offset = reader.unsigned();
      if (object <= 0 || !seen.add(object) || first + offset >= data.length || (offsets.isNotEmpty && offset <= offsets.last)) {
        throw const FormatException('Invalid PDF object stream index.');
      }
      numbers.add(object);
      offsets.add(offset);
    }
    if (!reader.isDone) {
      throw const FormatException('Unexpected object stream header tokens.');
    }
    final ({Uint8List bytes, List<int> numbers, List<int> offsets, int first}) result = (bytes: data, numbers: numbers, offsets: offsets, first: first);
    _objectStreams[number] = result;
    return result;
  }

  /// Charges decoded structural streams against a global budget.
  Uint8List _decode(PdfStream stream) {
    final int remaining = limits.maxDecodedBytes - _decodedBytes;
    if (remaining <= 0) {
      throw const FormatException('PDF structural streams exceed the byte limit.');
    }
    final Uint8List data = PdfFilters.decode(
      stream,
      limits: PdfLimits(maxStreamBytes: math.min(limits.maxStreamBytes, remaining), maxDepth: limits.maxDepth),
    );
    _decodedBytes += data.length;
    return data;
  }
}

/// Requires an integer PDF syntax value.
int _integer(PdfValue? value) => value is PdfNumber ? value.integer : throw const FormatException('Expected a PDF integer.');
