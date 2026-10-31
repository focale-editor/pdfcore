import 'dart:convert';
import 'dart:typed_data';

/// A PDF syntax value, independent of graphics or application models.
sealed class PdfValue {
  /// Allows immutable concrete syntax values.
  const PdfValue();
}

/// The PDF null object.
final class PdfNull extends PdfValue {
  /// Creates a null value.
  const PdfNull();
}

/// A PDF boolean.
final class PdfBoolean extends PdfValue {
  /// Stored truth value.
  final bool value;

  /// Creates a boolean.
  const PdfBoolean({required this.value});
}

/// A finite PDF integer or real number.
final class PdfNumber extends PdfValue {
  /// Stored numeric value; integers retain their integer representation.
  final num value;

  /// Creates a number representable on both the VM and JavaScript.
  PdfNumber({required this.value}) {
    if (!value.isFinite || value.abs() > 9007199254740991) {
      throw const FormatException('PDF number is outside the portable range.');
    }
  }

  /// Requires an integer without truncating real values.
  int get integer {
    if (value is! int) {
      throw const FormatException('Expected a PDF integer.');
    }
    return value as int;
  }
}

/// A PDF name, represented as decoded Latin-1 bytes without its slash.
final class PdfName extends PdfValue {
  /// Name bytes mapped one-to-one to code points.
  final String value;

  /// Creates a name; escaped characters are handled by the writer.
  PdfName({required this.value}) {
    if (value.codeUnits.any((unit) => unit == 0 || unit > 255)) {
      throw const FormatException('PDF names require nonzero Latin-1 bytes.');
    }
  }
}

/// An immutable PDF byte string, independent of text encoding.
final class PdfString extends PdfValue {
  /// Owned string bytes.
  final Uint8List _bytes;

  /// Copies arbitrary string bytes.
  PdfString({required List<int> bytes}) : _bytes = Uint8List.fromList(bytes);

  /// Creates a Unicode text string with a UTF-16BE byte-order mark.
  factory PdfString.text({required String text}) => PdfString(
    bytes: [
      0xfe,
      0xff,
      for (final int unit in text.codeUnits) ...[unit >> 8, unit & 255],
    ],
  );

  /// Returns a read-only view of the stored bytes.
  Uint8List get bytes => _bytes.asUnmodifiableView();

  /// Decodes Unicode text, or PDFDocEncoding when there is no BOM.
  String get text {
    if (_bytes.length >= 2 && _bytes[0] == 0xfe && _bytes[1] == 0xff) {
      if (_bytes.length.isOdd) {
        throw const FormatException('Truncated PDF UTF-16 string.');
      }
      return String.fromCharCodes([for (int i = 2; i < _bytes.length; i += 2) _bytes[i] << 8 | _bytes[i + 1]]);
    }
    if (_bytes.length >= 3 && _bytes[0] == 0xef && _bytes[1] == 0xbb && _bytes[2] == 0xbf) {
      return utf8.decode(_bytes);
    }
    const List<int> accents = [0x2d8, 0x2c7, 0x2c6, 0x2d9, 0x2dd, 0x2db, 0x2da, 0x2dc];
    const List<int> punctuation = [
      0x2022,
      0x2020,
      0x2021,
      0x2026,
      0x2014,
      0x2013,
      0x192,
      0x2044,
      0x2039,
      0x203a,
      0x2212,
      0x2030,
      0x201e,
      0x201c,
      0x201d,
      0x2018,
      0x2019,
      0x201a,
      0x2122,
      0xfb01,
      0xfb02,
      0x141,
      0x152,
      0x160,
      0x178,
      0x17d,
      0x131,
      0x142,
      0x153,
      0x161,
      0x17e,
      0xfffd,
    ];
    return String.fromCharCodes(
      _bytes.map(
        (byte) => switch (byte) {
          >= 0x18 && <= 0x1f => accents[byte - 0x18],
          >= 0x80 && <= 0x9f => punctuation[byte - 0x80],
          0xa0 => 0x20ac,
          0x7f || 0xad => 0xfffd,
          _ => byte,
        },
      ),
    );
  }
}

/// An immutable ordered PDF array.
final class PdfArray extends PdfValue {
  /// Array items in source order.
  final List<PdfValue> values;

  /// Copies an array's values.
  PdfArray({required Iterable<PdfValue> values}) : values = List.unmodifiable(values);
}

/// An immutable PDF dictionary keyed by decoded PDF names.
final class PdfDictionary extends PdfValue {
  /// Dictionary entries in insertion order.
  final Map<String, PdfValue> values;

  /// Copies dictionary entries.
  PdfDictionary({Map<String, PdfValue> values = const {}}) : values = Map.unmodifiable(values);

  /// Reads an optional entry without resolving references.
  PdfValue? operator [](String key) => values[key];

  /// Reads a direct name, returning null for other value types.
  String? name(String key) => switch (values[key]) {
    PdfName(:final String value) => value,
    _ => null,
  };

  /// Reads a direct integer, rejecting a real or differently typed value.
  int? integer(String key) => switch (values[key]) {
    null || PdfNull() => null,
    final PdfNumber value => value.integer,
    _ => throw FormatException('Expected integer /$key.'),
  };

  /// Returns a dictionary with replacements and optional removed entries.
  PdfDictionary copyWith({Map<String, PdfValue> values = const {}, Set<String> remove = const {}}) => PdfDictionary(
    values: {
      for (final MapEntry<String, PdfValue> entry in this.values.entries)
        if (!remove.contains(entry.key)) entry.key: entry.value,
      ...values,
    },
  );
}

/// A reference to an indirect PDF object.
final class PdfReference extends PdfValue {
  /// Positive object number.
  final int objectNumber;

  /// Object generation, from 0 through 65535.
  final int generation;

  /// Creates an indirect reference.
  const PdfReference({required this.objectNumber, this.generation = 0});

  @override
  bool operator ==(Object other) => other is PdfReference && objectNumber == other.objectNumber && generation == other.generation;

  @override
  int get hashCode => Object.hash(objectNumber, generation);

  @override
  String toString() => '$objectNumber $generation R';
}

/// An immutable encoded PDF stream and its interpretation dictionary.
final class PdfStream extends PdfValue {
  /// Stream attributes, including filters and decode parameters.
  final PdfDictionary dictionary;

  /// Owned bytes in their original encoded form.
  final Uint8List _data;

  /// Copies an encoded stream without decoding or recompressing it.
  PdfStream({required this.dictionary, required List<int> data}) : _data = Uint8List.fromList(data);

  /// Returns a read-only view of the encoded stream.
  Uint8List get data => _data.asUnmodifiableView();
}
