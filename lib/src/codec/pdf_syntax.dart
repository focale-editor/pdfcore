import 'dart:convert';
import 'dart:typed_data';

import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// Byte-based PDF syntax reader shared by files and content streams.
final class PdfSyntaxReader {
  /// Bytes being inspected, without Unicode transcoding.
  final Uint8List bytes;

  /// Resource limits applied to syntax nesting.
  final PdfLimits limits;

  /// Explicitly permitted duplicate keys, resolved using their final value.
  final Set<String> duplicateKeys;

  /// Whether PDF 1.2 hexadecimal name escapes are enabled.
  final bool nameEscapes;

  /// Current byte position.
  int position;

  /// Creates a syntax reader at a known object boundary.
  PdfSyntaxReader({required this.bytes, this.limits = const PdfLimits(), this.position = 0, this.nameEscapes = true, this.duplicateKeys = const {}});

  /// Whether no tokens remain.
  bool get isDone {
    skipSpace();
    return position >= bytes.length;
  }

  /// Skips PDF whitespace and percent comments.
  void skipSpace() {
    while (position < bytes.length) {
      final int byte = bytes[position];
      if (isSpace(byte)) {
        position++;
      } else if (byte == 37) {
        while (position < bytes.length && bytes[position] != 10 && bytes[position] != 13) {
          position++;
        }
      } else {
        return;
      }
    }
  }

  /// Reads a regular keyword or number token.
  String token() {
    skipSpace();
    final int start = position;
    while (position < bytes.length && !isDelimiter(bytes[position])) {
      position++;
    }
    if (position == start) {
      throw FormatException('Expected a PDF token at byte $position.');
    }
    return latin1.decode(Uint8List.sublistView(bytes, start, position));
  }

  /// Reads an exact required keyword.
  void expect(String expected) {
    if (token() != expected) {
      throw FormatException('Expected PDF keyword $expected at byte $position.');
    }
  }

  /// Tests and consumes a keyword, preserving position on a mismatch.
  bool consume(String keyword) {
    skipSpace();
    if (position + keyword.length > bytes.length) {
      return false;
    }
    for (int index = 0; index < keyword.length; index++) {
      if (bytes[position + index] != keyword.codeUnitAt(index)) {
        return false;
      }
    }
    final int end = position + keyword.length;
    if (end < bytes.length && !isDelimiter(bytes[end])) {
      return false;
    }
    position = end;
    return true;
  }

  /// Reads a nonnegative integer token used for offsets and identifiers.
  int unsigned() {
    final String value = token();
    if (!RegExp(r'^\d+$').hasMatch(value)) {
      throw const FormatException('Expected a nonnegative PDF integer.');
    }
    final int? number = int.tryParse(value);
    if (number == null || number > 9007199254740991) {
      throw const FormatException('PDF integer exceeds the portable range.');
    }
    return number;
  }

  /// Reads a direct value or reference with bounded nesting.
  PdfValue value({int depth = 0, bool references = true}) {
    skipSpace();
    if (depth > limits.maxDepth || position >= bytes.length) {
      throw const FormatException('Truncated or excessively nested PDF value.');
    }
    final int byte = bytes[position];
    if (byte == 47) {
      position++;
      final List<int> name = [];
      while (position < bytes.length && !isDelimiter(bytes[position])) {
        final int next = bytes[position++];
        if (next == 35 && nameEscapes) {
          if (position + 2 > bytes.length) {
            throw const FormatException('Truncated PDF name escape.');
          }
          name.add(_hex(bytes[position++]) * 16 + _hex(bytes[position++]));
        } else {
          name.add(next);
        }
      }
      return PdfName(value: latin1.decode(name));
    }
    if (byte == 40) {
      return _literalString();
    }
    if (byte == 60) {
      position++;
      if (position < bytes.length && bytes[position] == 60) {
        position++;
        final Map<String, PdfValue> entries = {};
        int entryCount = 0;
        while (true) {
          skipSpace();
          if (position + 1 < bytes.length && bytes[position] == 62 && bytes[position + 1] == 62) {
            position += 2;
            return PdfDictionary(values: entries);
          }
          final PdfValue key = value(depth: depth + 1, references: references);
          if (key is! PdfName || (entries.containsKey(key.value) && !duplicateKeys.contains(key.value))) {
            throw const FormatException('Invalid or duplicate PDF dictionary key.');
          }
          if (entryCount++ >= limits.maxObjects) {
            throw const FormatException('PDF dictionary exceeds the entry limit.');
          }
          entries[key.value] = value(depth: depth + 1, references: references);
        }
      }
      final List<int> result = [];
      int? high;
      while (position < bytes.length) {
        final int next = bytes[position++];
        if (next == 62) {
          if (high != null) {
            result.add(high << 4);
          }
          return PdfString(bytes: result);
        }
        if (isSpace(next)) {
          continue;
        }
        final int digit = _hex(next);
        if (high == null) {
          high = digit;
        } else {
          result.add(high << 4 | digit);
          high = null;
        }
      }
      throw const FormatException('Unterminated PDF hexadecimal string.');
    }
    if (byte == 91) {
      position++;
      final List<PdfValue> values = [];
      while (true) {
        skipSpace();
        if (position < bytes.length && bytes[position] == 93) {
          position++;
          return PdfArray(values: values);
        }
        if (values.length >= limits.maxObjects) {
          throw const FormatException('PDF array exceeds the item limit.');
        }
        values.add(value(depth: depth + 1, references: references));
      }
    }
    final String word = token();
    if (word == 'true' || word == 'false') {
      return PdfBoolean(value: word == 'true');
    }
    if (word == 'null') {
      return const PdfNull();
    }
    if (!RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$').hasMatch(word)) {
      throw FormatException('Invalid PDF value token $word.');
    }
    final num? number = word.contains('.') ? double.tryParse(word) : int.tryParse(word);
    if (number == null) {
      throw const FormatException('PDF number is outside the supported range.');
    }
    if (references && number is int && number >= 0) {
      final int saved = position;
      skipSpace();
      if (position < bytes.length && bytes[position] >= 48 && bytes[position] <= 57) {
        final String candidate = token();
        final int? generation = RegExp(r'^\d+$').hasMatch(candidate) ? int.tryParse(candidate) : null;
        if (generation != null && consume('R')) {
          if (number <= 0 || generation > 65535) {
            throw const FormatException('Invalid PDF indirect reference.');
          }
          return PdfReference(objectNumber: number, generation: generation);
        }
      }
      position = saved;
    }
    return PdfNumber(value: number);
  }

  /// Reads a nested literal byte string with PostScript-style escapes.
  PdfString _literalString() {
    position++;
    int depth = 1;
    final List<int> result = [];
    while (position < bytes.length) {
      final int byte = bytes[position++];
      if (byte == 40) {
        if (++depth > limits.maxDepth) {
          throw const FormatException('PDF literal string nesting exceeds the limit.');
        }
        result.add(byte);
      } else if (byte == 41) {
        if (--depth == 0) {
          return PdfString(bytes: result);
        }
        result.add(byte);
      } else if (byte == 92) {
        if (position >= bytes.length) {
          break;
        }
        final int escaped = bytes[position++];
        if (escaped == 10 || escaped == 13) {
          if (escaped == 13 && position < bytes.length && bytes[position] == 10) {
            position++;
          }
        } else if (escaped >= 48 && escaped <= 55) {
          int octal = escaped - 48;
          for (int index = 0; index < 2 && position < bytes.length && bytes[position] >= 48 && bytes[position] <= 55; index++) {
            octal = octal * 8 + bytes[position++] - 48;
          }
          result.add(octal & 255);
        } else {
          result.add(switch (escaped) {
            110 => 10,
            114 => 13,
            116 => 9,
            98 => 8,
            102 => 12,
            _ => escaped,
          });
        }
      } else if (byte == 13) {
        if (position < bytes.length && bytes[position] == 10) {
          position++;
        }
        result.add(10);
      } else {
        result.add(byte);
      }
    }
    throw const FormatException('Unterminated PDF literal string.');
  }

  /// Recognizes PDF whitespace bytes.
  static bool isSpace(int byte) => const [0, 9, 10, 12, 13, 32].contains(byte);

  /// Recognizes token boundaries, including whitespace.
  static bool isDelimiter(int byte) => isSpace(byte) || const [40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(byte);
}

/// Parses one hexadecimal character.
int _hex(int byte) => switch (byte) {
  >= 48 && <= 57 => byte - 48,
  >= 65 && <= 70 => byte - 55,
  >= 97 && <= 102 => byte - 87,
  _ => throw const FormatException('Invalid hexadecimal PDF escape.'),
};

/// Bounded PDF syntax writer used for files and content streams.
final class PdfSyntaxWriter {
  /// Encoded bytes accumulated so far.
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// Resource policy.
  final PdfLimits limits;

  /// Creates an empty syntax writer.
  PdfSyntaxWriter({this.limits = const PdfLimits()});

  /// Current output offset.
  int get length => _bytes.length;

  /// Appends raw bytes under the file budget.
  void add(List<int> bytes) {
    if (_bytes.length + bytes.length > limits.maxFileBytes) {
      throw const FormatException('PDF output exceeds the byte limit.');
    }
    _bytes.add(bytes);
  }

  /// Appends Latin-1 syntax text.
  void text(String value) => add(latin1.encode(value));

  /// Returns and clears accumulated bytes.
  Uint8List takeBytes() => _bytes.takeBytes();

  /// Serializes a value, permitting a stream only as an indirect object body.
  void value(PdfValue value, {int depth = 0, bool allowStream = false}) {
    if (depth > limits.maxDepth) {
      throw const FormatException('PDF value nesting exceeds the output limit.');
    }
    switch (value) {
      case PdfNull():
        text('null');
      case PdfBoolean(:final value):
        text(value ? 'true' : 'false');
      case PdfNumber(:final value):
        text(_number(value));
      case PdfName(:final value):
        text('/');
        for (final int byte in value.codeUnits) {
          text(byte < 33 || byte > 126 || byte == 35 || PdfSyntaxReader.isDelimiter(byte) ? '#${byte.toRadixString(16).padLeft(2, '0')}' : String.fromCharCode(byte));
        }
      case PdfString(:final bytes):
        text('<');
        for (final int byte in bytes) {
          text(byte.toRadixString(16).padLeft(2, '0'));
        }
        text('>');
      case PdfReference(:final objectNumber, :final generation):
        if (objectNumber <= 0 || objectNumber > 9007199254740991 || generation < 0 || generation > 65535) {
          throw const FormatException('Invalid PDF output reference.');
        }
        text('$objectNumber $generation R');
      case PdfArray(:final values):
        text('[');
        for (final PdfValue item in values) {
          this.value(item, depth: depth + 1);
          text(' ');
        }
        text(']');
      case PdfDictionary(:final values):
        text('<<');
        for (final MapEntry<String, PdfValue> entry in values.entries) {
          this.value(PdfName(value: entry.key), depth: depth + 1);
          text(' ');
          this.value(entry.value, depth: depth + 1);
          text('\n');
        }
        text('>>');
      case PdfStream(:final dictionary, :final data):
        if (!allowStream) {
          throw const FormatException('PDF streams must be indirect objects.');
        }
        this.value(
          dictionary.copyWith(values: {'Length': PdfNumber(value: data.length)}),
          depth: depth + 1,
        );
        text('\nstream\n');
        add(data);
        text('\nendstream');
    }
  }
}

/// Expands exponent notation because PDF real syntax has no exponent form.
String _number(num value) {
  final String source = value.toString();
  if (!source.contains('e') && !source.contains('E')) {
    return source;
  }
  final List<String> parts = source.toLowerCase().split('e');
  final int exponent = int.parse(parts[1]);
  final bool negative = parts[0].startsWith('-');
  final String mantissa = negative ? parts[0].substring(1) : parts[0];
  final int dot = mantissa.indexOf('.');
  final String digits = mantissa.replaceAll('.', '');
  final int point = (dot < 0 ? mantissa.length : dot) + exponent;
  final String expanded = point <= 0
      ? '0.${'0' * -point}$digits'
      : point >= digits.length
      ? '$digits${'0' * (point - digits.length)}'
      : '${digits.substring(0, point)}.${digits.substring(point)}';
  return '${negative ? '-' : ''}$expanded';
}
