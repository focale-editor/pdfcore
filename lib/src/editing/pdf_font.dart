import 'dart:typed_data';

import 'package:pdfcore/src/codec/pdf_filters.dart';
import 'package:pdfcore/src/codec/pdf_syntax.dart';
import 'package:pdfcore/src/editing/pdf_glyph_names.dart';
import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// A font's proven character-code to Unicode mapping, without font shaping.
///
/// ToUnicode maps support variable-length codes and ligatures. Encoding only
/// uses codes present in the mapping; it never invents new subset glyphs.
final class PdfFont {
  /// Original font dictionary, including embedding and metric information.
  final PdfDictionary dictionary;

  /// Hexadecimal character codes mapped to Unicode strings.
  final Map<String, String> mappings;

  /// Accepted character-code lengths in bytes.
  final List<int> _lengths;

  /// Copies an explicit character mapping supplied by a font-aware host.
  PdfFont({required this.dictionary, required Map<String, String> mappings})
    : mappings = Map.unmodifiable(mappings),
      _lengths = (mappings.keys.map((key) => key.length ~/ 2).toSet().toList()..sort()) {
    for (final MapEntry<String, String> entry in mappings.entries) {
      if (!RegExp(r'^(?:[0-9a-f]{2}){1,4}$').hasMatch(entry.key) || entry.value.isEmpty) {
        throw const FormatException('Font mappings require lowercase 1–4-byte hex codes and nonempty Unicode.');
      }
    }
    // A prefix ambiguity cannot be decoded safely without a code-space policy.
    for (final String key in mappings.keys) {
      for (int length = 2; length < key.length; length += 2) {
        if (mappings.containsKey(key.substring(0, length))) {
          throw const PdfUnsupportedException(message: 'Ambiguous variable-length font character mapping.');
        }
      }
    }
  }

  /// Reads ToUnicode, or a supported explicit simple-font encoding.
  ///
  /// Without ToUnicode, WinAnsiEncoding, StandardEncoding and Adobe Glyph List
  /// Differences are supported. Unspecified nonstandard built-in encodings,
  /// Symbol, Dingbats and unknown names still require a host mapping.
  factory PdfFont.read({required PdfDocument document, required PdfValue value}) {
    final PdfDictionary dictionary = document.dictionary(value);
    if (dictionary['ToUnicode'] case final PdfValue unicode) {
      final PdfValue stream = document.resolve(unicode);
      if (stream is PdfStream) {
        if (document.resolve(stream.dictionary['UseCMap'] ?? const PdfNull()) is! PdfNull) {
          throw const PdfUnsupportedException(message: 'Inherited ToUnicode streams require a host mapping.');
        }
        return PdfFont(dictionary: dictionary, mappings: _readCMap(document.decodeStream(stream), document.limits));
      }
      if (stream is! PdfNull) {
        throw const FormatException('Font ToUnicode must be a stream.');
      }
    }
    if (dictionary.name('Subtype') == 'Type0') {
      throw const PdfUnsupportedException(message: 'Composite font Unicode editing requires ToUnicode or an explicit host mapping.');
    }
    final PdfValue encoding = document.resolve(dictionary['Encoding'] ?? const PdfNull());
    final String? base = encoding is PdfName
        ? encoding.value
        : encoding is PdfDictionary
        ? encoding.name('BaseEncoding')
        : null;
    final Map<String, String> mappings = {};
    if (base == 'WinAnsiEncoding') {
      for (int byte = 32; byte <= 255; byte++) {
        if (_winAnsi(byte) case final int scalar) {
          mappings[_hex([byte])] = String.fromCharCode(scalar);
        }
      }
    } else if (base == 'StandardEncoding' ||
        (base == null && dictionary.name('Subtype') == 'Type1' && ['Helvetica', 'Times', 'Courier'].any((name) => (dictionary.name('BaseFont') ?? '').startsWith(name)))) {
      for (int byte = 0; byte < 256; byte++) {
        if (_glyphUnicode(pdfStandardEncoding[byte]) case final String text) {
          mappings[_hex([byte])] = text;
        }
      }
    } else if (base != null) {
      throw PdfUnsupportedException(message: 'Font encoding /$base requires ToUnicode or an explicit host mapping.');
    }
    if ((encoding is PdfDictionary ? encoding['Differences'] : null) case final PdfValue differences) {
      final PdfValue resolved = document.resolve(differences);
      if (resolved is! PdfArray) {
        throw const FormatException('Font Differences must be an array.');
      }
      int? code;
      for (final PdfValue item in resolved.values) {
        if (item is PdfNumber) {
          code = item.integer;
        } else if (item is PdfName && code != null && code >= 0 && code < 256) {
          final String key = _hex([code]);
          mappings.remove(key);
          if (_glyphUnicode(item.value) case final String text) {
            mappings[key] = text;
          }
          code++;
        } else {
          throw const FormatException('Invalid font Differences entry.');
        }
      }
    }
    if (mappings.isEmpty) {
      throw const PdfUnsupportedException(message: 'Font has no supported Unicode mapping; use encoded text or supply a host mapping.');
    }
    return PdfFont(dictionary: dictionary, mappings: mappings);
  }

  /// Resolves Adobe glyph names, Unicode names and underscore-separated clusters.
  static String? unicodeForGlyph(String name) => _glyphUnicode(name);

  /// Converts character bytes to Unicode without splitting encoded ligatures.
  String decode(List<int> bytes) => decodeGlyphs(bytes).map((glyph) => glyph.text).join();

  /// Retains each encoded glyph's original code, width and Unicode cluster.
  List<PdfDecodedGlyph> decodeGlyphs(List<int> bytes) {
    if (bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('Font text contains a non-byte value.');
    }
    final List<PdfDecodedGlyph> result = [];
    int position = 0;
    while (position < bytes.length) {
      bool found = false;
      for (final int length in _lengths) {
        if (position + length > bytes.length) {
          continue;
        }
        final String code = _hex(bytes.sublist(position, position + length));
        final String? text = mappings[code];
        if (text != null) {
          result.add(PdfDecodedGlyph(code: int.parse(code, radix: 16), byteLength: length, text: text));
          position += length;
          found = true;
          break;
        }
      }
      if (!found) {
        throw PdfUnsupportedException(message: 'Font has no Unicode mapping at character byte $position.');
      }
    }
    return List.unmodifiable(result);
  }

  /// Encodes Unicode using existing codes, including multi-character ligatures.
  ///
  /// Duplicate Unicode mappings choose the shortest, then smallest code.
  /// Characters absent from the font require embedding a replacement font.
  Uint8List encode(String text) {
    final Map<String, String> inverse = {};
    final List<String> codes = mappings.keys.toList()..sort((a, b) => a.length == b.length ? a.compareTo(b) : a.length.compareTo(b.length));
    for (final String code in codes) {
      inverse.putIfAbsent(mappings[code]!, () => code);
    }
    final Map<int, List<String>> candidates = {};
    for (final String value in inverse.keys) {
      (candidates[value.codeUnitAt(0)] ??= []).add(value);
    }
    for (final List<String> values in candidates.values) {
      values.sort((a, b) => b.length.compareTo(a.length));
    }
    // Dynamic programming avoids a greedy ligature swallowing the only valid
    // encoding of a later character (for example 'ab' + missing 'c' vs 'a'+'bc').
    final Map<int, (String, int)> choices = {};
    final Set<int> reachable = {text.length};
    for (int offset = text.length - 1; offset >= 0; offset--) {
      for (final String candidate in candidates[text.codeUnitAt(offset)] ?? const <String>[]) {
        final int end = offset + candidate.length;
        if (reachable.contains(end) && text.startsWith(candidate, offset)) {
          choices[offset] = (inverse[candidate]!, end);
          reachable.add(offset);
          break;
        }
      }
    }
    if (!reachable.contains(0)) {
      throw const PdfUnsupportedException(message: 'Replacement text contains characters unavailable in this font mapping.');
    }
    final BytesBuilder bytes = BytesBuilder(copy: false);
    int offset = 0;
    while (offset < text.length) {
      final (String code, int next) = choices[offset]!;
      bytes.add([for (int index = 0; index < code.length; index += 2) int.parse(code.substring(index, index + 2), radix: 16)]);
      offset = next;
    }
    return bytes.takeBytes();
  }
}

/// One original PDF character code and its possibly multi-scalar Unicode text.
final class PdfDecodedGlyph {
  /// Unsigned source character code.
  final int code;

  /// Number of encoded bytes, including leading zeroes.
  final int byteLength;

  /// Unicode text belonging to this glyph, including ligatures and combining marks.
  final String text;

  /// Creates an immutable decoded glyph cluster.
  const PdfDecodedGlyph({required this.code, required this.byteLength, required this.text});

  /// Exact hexadecimal key used by the font mapping.
  String get key => code.toRadixString(16).padLeft(byteLength * 2, '0');
}

/// Parses bounded bfchar/bfrange mappings without executing PostScript.
Map<String, String> _readCMap(Uint8List bytes, PdfLimits limits) {
  final PdfSyntaxReader reader = PdfSyntaxReader(bytes: bytes, limits: limits);
  final Map<String, String> result = {};
  int? count;
  int tokens = 0;
  int mappedBytes = 0;

  /// Reads a required CMap string.
  PdfString string() => switch (reader.value(references: false)) {
    final PdfString value => value,
    _ => throw const FormatException('Expected a CMap hexadecimal string.'),
  };

  /// Adds one mapping while enforcing expansion budgets and source width.
  void add(List<int> code, List<int> unicode) {
    if (code.isEmpty || code.length > 4 || result.length >= limits.maxObjects) {
      throw const FormatException('CMap code width or mapping count exceeds the limit.');
    }
    mappedBytes += unicode.length + code.length;
    if (mappedBytes > limits.maxDecodedBytes) {
      throw const FormatException('CMap expansion exceeds the decoded byte limit.');
    }
    result[_hex(code)] = _unicode(unicode);
  }

  while (!reader.isDone) {
    if (++tokens > limits.maxObjects) {
      throw const FormatException('CMap token count exceeds the limit.');
    }
    final int byte = reader.bytes[reader.position];
    if ([47, 60, 40, 91].contains(byte) || byte >= 48 && byte <= 57) {
      final PdfValue value = reader.value(references: false);
      count = value is PdfNumber ? value.integer : null;
      continue;
    }
    final String token = reader.token();
    if (token == 'usecmap') {
      throw const PdfUnsupportedException(message: 'Inherited CMaps require a host-supplied character mapping.');
    }
    if (!['beginbfchar', 'beginbfrange', 'begincodespacerange'].contains(token)) {
      count = null;
      continue;
    }
    if (count == null || count < 0 || count > limits.maxObjects) {
      throw const FormatException('Invalid CMap section count.');
    }
    for (int index = 0; index < count; index++) {
      final Uint8List start = string().bytes;
      if (token == 'beginbfchar') {
        add(start, string().bytes);
        continue;
      }
      final Uint8List end = string().bytes;
      if (start.isEmpty || start.length > 4 || start.length != end.length) {
        throw const FormatException('Invalid CMap character-code range.');
      }
      final int first = _integer(start);
      final int last = _integer(end);
      if (last < first || (token != 'begincodespacerange' && last - first >= limits.maxObjects)) {
        throw const FormatException('Invalid or excessive CMap range.');
      }
      if (token == 'begincodespacerange') {
        continue;
      }
      final PdfValue target = reader.value(references: false);
      if (target is PdfArray && target.values.length != last - first + 1) {
        throw const FormatException('CMap range destination count does not match.');
      }
      final List<int>? consecutive = target is PdfString ? target.bytes.toList() : null;
      for (int code = first; code <= last; code++) {
        final List<int> source = [for (int shift = start.length - 1; shift >= 0; shift--) (code ~/ (1 << (shift * 8))) & 255];
        if (target is PdfArray) {
          final PdfValue item = target.values[code - first];
          if (item is! PdfString) {
            throw const FormatException('Invalid CMap range destination.');
          }
          add(source, item.bytes);
        } else if (consecutive != null) {
          add(source, consecutive);
          if (code < last) {
            int position = consecutive.length - 1;
            while (position >= 0 && consecutive[position] == 255) {
              consecutive[position--] = 0;
            }
            if (position < 0) {
              throw const FormatException('CMap destination range overflows.');
            }
            consecutive[position]++;
          }
        } else {
          throw const FormatException('Invalid CMap range destination.');
        }
      }
    }
    reader.expect(switch (token) {
      'beginbfchar' => 'endbfchar',
      'beginbfrange' => 'endbfrange',
      _ => 'endcodespacerange',
    });
    count = null;
  }
  return result;
}

/// Formats a byte sequence as a stable mapping key.
String _hex(List<int> bytes) => bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// Reads a portable big-endian character code.
int _integer(List<int> bytes) => bytes.fold(0, (value, byte) => value * 256 + byte);

/// Validates UTF-16BE destinations, including surrogate pairs and ligatures.
String _unicode(List<int> bytes) {
  if (bytes.isEmpty || bytes.length.isOdd) {
    throw const FormatException('CMap Unicode destinations must contain UTF-16BE units.');
  }
  final List<int> units = [for (int index = 0; index < bytes.length; index += 2) bytes[index] * 256 + bytes[index + 1]];
  for (int index = 0; index < units.length; index++) {
    final int unit = units[index];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= units.length || units[index] < 0xdc00 || units[index] > 0xdfff) {
        throw const FormatException('Unpaired CMap Unicode surrogate.');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException('Unpaired CMap Unicode surrogate.');
    }
  }
  return String.fromCharCodes(units);
}

/// Returns WinAnsi Unicode values, excluding unused character slots.
int? _winAnsi(int byte) {
  const List<int?> high = [
    0x20ac,
    null,
    0x201a,
    0x192,
    0x201e,
    0x2026,
    0x2020,
    0x2021,
    0x2c6,
    0x2030,
    0x160,
    0x2039,
    0x152,
    null,
    0x17d,
    null,
    null,
    0x2018,
    0x2019,
    0x201c,
    0x201d,
    0x2022,
    0x2013,
    0x2014,
    0x2dc,
    0x2122,
    0x161,
    0x203a,
    0x153,
    null,
    0x17e,
    0x178,
  ];
  return byte == 127
      ? null
      : byte >= 128 && byte <= 159
      ? high[byte - 128]
      : byte;
}

/// Resolves pinned Adobe Glyph List names and explicit Unicode clusters.
String? _glyphUnicode(String name) {
  final String base = name.split('.').first;
  if (RegExp(r'^[A-Za-z]$').hasMatch(base)) {
    return base;
  }
  if (base.contains('_')) {
    final List<String?> parts = base.split('_').map(_glyphUnicode).toList();
    return parts.any((part) => part == null) ? null : parts.join();
  }
  if (pdfGlyphNames[base] case final String text) {
    return text;
  }
  if (RegExp(r'^uni(?:[0-9A-Fa-f]{4})+$').hasMatch(base)) {
    final String hex = base.substring(3);
    return _unicode([for (int index = 0; index < hex.length; index += 2) int.parse(hex.substring(index, index + 2), radix: 16)]);
  }
  if (RegExp(r'^u[0-9A-Fa-f]{4,6}$').hasMatch(base)) {
    final int scalar = int.parse(base.substring(1), radix: 16);
    if (scalar <= 0x10ffff && (scalar < 0xd800 || scalar > 0xdfff)) {
      return String.fromCharCode(scalar);
    }
  }
  return null;
}
