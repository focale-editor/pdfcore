import 'dart:typed_data';

import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';
import 'package:zcodec/zcodec.dart';

/// Explicitly unsupported PDF features, distinct from damaged syntax.
final class PdfUnsupportedException extends FormatException {
  /// Describes a feature that requires another implementation.
  const PdfUnsupportedException({required String message}) : super(message);
}

/// Decodes portable PDF stream filters while retaining encoded originals.
abstract final class PdfFilters {
  /// Encodes bytes as PDF/PostScript ASCII85 with its required `~>` terminator.
  ///
  /// The result omits `<~`, which is not part of PDF stream filter data.
  /// Input and encoded output both obey [PdfLimits.maxStreamBytes].
  static Uint8List encodeAscii85({required List<int> bytes, PdfLimits limits = const PdfLimits()}) {
    limits.validate();
    if (bytes.length > limits.maxStreamBytes || bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('Invalid or excessive ASCII85 input.');
    }
    final BytesBuilder output = BytesBuilder(copy: false);
    for (int offset = 0; offset < bytes.length; offset += 4) {
      final int count = bytes.length - offset < 4 ? bytes.length - offset : 4;
      int value = 0;
      for (int index = 0; index < 4; index++) {
        value = value * 256 + (index < count ? bytes[offset + index] : 0);
      }
      final int encodedLength = value == 0 && count == 4 ? 1 : count + 1;
      if (output.length + encodedLength + 2 > limits.maxStreamBytes) {
        throw const FormatException('ASCII85 output exceeds the limit.');
      }
      if (encodedLength == 1) {
        output.addByte(122);
      } else {
        final Uint8List digits = Uint8List(5);
        for (int index = 4; index >= 0; index--) {
          digits[index] = value % 85 + 33;
          value ~/= 85;
        }
        output.add(Uint8List.sublistView(digits, 0, encodedLength));
      }
    }
    if (output.length + 2 > limits.maxStreamBytes) {
      throw const FormatException('ASCII85 output exceeds the limit.');
    }
    output.add([126, 62]);
    return output.takeBytes();
  }

  /// Decodes Flate, LZW, ASCIIHex, ASCII85 and RunLength filter chains.
  ///
  /// Image-specific filters and encryption remain opaque and throw here.
  /// They can still be retained in [PdfStream] and written unchanged.
  static Uint8List decode(PdfStream stream, {PdfLimits limits = const PdfLimits(), PdfValue Function(PdfValue)? resolve}) {
    limits.validate();
    if (stream.dictionary['F'] != null) {
      throw const PdfUnsupportedException(message: 'External PDF stream files are not resolved.');
    }

    /// Resolves optional dictionary values when a document is available.
    PdfValue? resolved(PdfValue? value) => value == null ? null : resolve?.call(value) ?? value;

    final PdfValue? filterValue = resolved(stream.dictionary['Filter']);
    final List<PdfValue> filters = switch (filterValue) {
      null || PdfNull() => [],
      PdfArray(:final values) => values,
      _ => [filterValue],
    };
    if (filters.length > limits.maxDepth) {
      throw const FormatException('Too many PDF stream filters.');
    }
    final PdfValue? parameterValue = resolved(stream.dictionary['DecodeParms']);
    final List<PdfValue?> parameters = parameterValue is PdfArray ? parameterValue.values : [parameterValue];
    Uint8List bytes = stream.data;
    for (int index = 0; index < filters.length; index++) {
      final PdfValue? filter = resolved(filters[index]);
      final PdfValue? parameter = index < parameters.length ? resolved(parameters[index]) : null;
      if (filter is! PdfName || (parameter != null && parameter is! PdfNull && parameter is! PdfDictionary)) {
        throw const FormatException('Invalid PDF filter or decode parameters.');
      }
      final PdfDictionary settings = parameter is PdfDictionary ? parameter : PdfDictionary();
      bytes = switch (filter.value) {
        'FlateDecode' || 'Fl' => ZlibDecoder(maxOutputBytes: limits.maxStreamBytes).convert(bytes),
        'ASCIIHexDecode' || 'AHx' => _asciiHex(bytes, limits.maxStreamBytes),
        'ASCII85Decode' || 'A85' => _ascii85(bytes, limits.maxStreamBytes),
        'RunLengthDecode' || 'RL' => _runLength(bytes, limits.maxStreamBytes),
        'LZWDecode' || 'LZW' => decodePdfLzwPrefix(bytes, limits.maxStreamBytes, settings.integer('EarlyChange') ?? 1).$1,
        _ => throw PdfUnsupportedException(message: 'Unsupported PDF stream filter /${filter.value}.'),
      };
      if (['FlateDecode', 'Fl', 'LZWDecode', 'LZW'].contains(filter.value)) {
        bytes = _predict(bytes, settings, limits.maxStreamBytes);
      }
      if (bytes.length > limits.maxStreamBytes) {
        throw const FormatException('PDF stream exceeds the decoded byte limit.');
      }
    }
    if (bytes.length > limits.maxStreamBytes) {
      throw const FormatException('PDF stream exceeds the decoded byte limit.');
    }
    return bytes;
  }
}

/// Tests PDF whitespace, including the NUL byte.
bool _space(int byte) => const [0, 9, 10, 12, 13, 32].contains(byte);

/// Converts a hexadecimal byte or rejects malformed filter data.
int _hex(int byte) => switch (byte) {
  >= 48 && <= 57 => byte - 48,
  >= 65 && <= 70 => byte - 55,
  >= 97 && <= 102 => byte - 87,
  _ => throw const FormatException('Invalid ASCIIHex digit.'),
};

/// Decodes the PDF ASCIIHex envelope, including a padded final nibble.
Uint8List _asciiHex(List<int> input, int limit) {
  final BytesBuilder output = BytesBuilder();
  int? high;
  for (final int byte in input) {
    if (byte == 62) {
      if (high != null) {
        output.addByte(high << 4);
      }
      if (output.length > limit) {
        throw const FormatException('ASCIIHex output exceeds the limit.');
      }
      return output.takeBytes();
    }
    if (_space(byte)) {
      continue;
    }
    final int value = _hex(byte);
    if (high == null) {
      high = value;
    } else {
      if (output.length >= limit) {
        throw const FormatException('ASCIIHex output exceeds the limit.');
      }
      output.addByte(high << 4 | value);
      high = null;
    }
  }
  throw const FormatException('ASCIIHex stream has no end marker.');
}

/// Decodes the PDF ASCII85 envelope and its zero abbreviation.
Uint8List _ascii85(List<int> input, int limit) {
  final BytesBuilder output = BytesBuilder();
  final List<int> group = [];
  bool ended = false;

  /// Writes one base-85 group with an optional short final payload.
  void flush(int count) {
    int value = 0;
    for (final int digit in group) {
      value = value * 85 + digit;
    }
    if (value > 0xffffffff || output.length + count > limit) {
      throw const FormatException('Invalid or excessive ASCII85 group.');
    }
    output.add([for (int index = 0; index < count; index++) (value ~/ (1 << ((3 - index) * 8))) & 255]);
    group.clear();
  }

  for (int index = 0; index < input.length; index++) {
    final int byte = input[index];
    if (_space(byte)) {
      continue;
    }
    if (byte == 126) {
      if (index + 1 >= input.length || input[index + 1] != 62) {
        throw const FormatException('Invalid ASCII85 terminator.');
      }
      ended = true;
      break;
    }
    if (byte == 122 && group.isEmpty) {
      if (output.length + 4 > limit) {
        throw const FormatException('ASCII85 output exceeds the limit.');
      }
      output.add(const [0, 0, 0, 0]);
    } else if (byte >= 33 && byte <= 117) {
      group.add(byte - 33);
      if (group.length == 5) {
        flush(4);
      }
    } else {
      throw const FormatException('Invalid ASCII85 byte.');
    }
  }
  if (!ended || group.length == 1) {
    throw const FormatException('Truncated ASCII85 stream.');
  }
  if (group.isNotEmpty) {
    final int count = group.length - 1;
    while (group.length < 5) {
      group.add(84);
    }
    flush(count);
  }
  return output.takeBytes();
}

/// Expands PDF RunLength packets under a strict output budget.
Uint8List _runLength(List<int> input, int limit) {
  final BytesBuilder output = BytesBuilder();
  int offset = 0;
  while (offset < input.length) {
    final int length = input[offset++];
    if (length == 128) {
      return output.takeBytes();
    }
    final int count = length < 128 ? length + 1 : 257 - length;
    if (output.length + count > limit || offset + (length < 128 ? count : 1) > input.length) {
      throw const FormatException('Truncated or excessive RunLength stream.');
    }
    if (length < 128) {
      output.add(input.sublist(offset, offset + count));
      offset += count;
    } else {
      output.add(List.filled(count, input[offset++]));
    }
  }
  throw const FormatException('RunLength stream has no end marker.');
}

/// Decodes PDF's MSB-first LZW variant with selectable early width growth.
(Uint8List, int) decodePdfLzwPrefix(List<int> input, int limit, int earlyChange) {
  if (earlyChange != 0 && earlyChange != 1) {
    throw const FormatException('Invalid LZW EarlyChange.');
  }
  final List<List<int>?> dictionary = List.filled(4096, null);
  for (int index = 0; index < 256; index++) {
    dictionary[index] = [index];
  }
  final BytesBuilder output = BytesBuilder();
  int bit = 0;
  int width = 9;
  int next = 258;
  List<int>? previous;
  while (bit + width <= input.length * 8) {
    int code = 0;
    for (int index = 0; index < width; index++, bit++) {
      code = code * 2 + ((input[bit ~/ 8] >> (7 - bit % 8)) & 1);
    }
    if (code == 257) {
      return (output.takeBytes(), (bit + 7) ~/ 8);
    }
    if (code == 256) {
      width = 9;
      next = 258;
      previous = null;
      continue;
    }
    final List<int>? value = code < next
        ? dictionary[code]
        : code == next && previous != null
        ? [...previous, previous.first]
        : null;
    if (value == null || output.length + value.length > limit) {
      throw const FormatException('Invalid or excessive LZW stream.');
    }
    output.add(value);
    if (previous != null && next < 4096) {
      dictionary[next++] = [...previous, value.first];
      if (width < 12 && next + earlyChange == 1 << width) {
        width++;
      }
    }
    previous = value;
  }
  throw const FormatException('LZW stream has no end marker.');
}

/// Reconstructs TIFF or PNG predictor rows after Flate/LZW decoding.
Uint8List _predict(Uint8List bytes, PdfDictionary parameters, int limit) {
  final int predictor = parameters.integer('Predictor') ?? 1;
  if (predictor == 1) {
    return bytes;
  }
  final int colors = parameters.integer('Colors') ?? 1;
  final int bits = parameters.integer('BitsPerComponent') ?? 8;
  final int columns = parameters.integer('Columns') ?? 1;
  if (colors <= 0 || columns <= 0 || colors > limit || columns > limit || ![1, 2, 4, 8, 16].contains(bits)) {
    throw const FormatException('Invalid PDF predictor dimensions.');
  }
  final int samples = colors * columns;
  final int rowBytes = (samples * bits + 7) ~/ 8;
  final int pixelBytes = (colors * bits + 7) ~/ 8;
  if (rowBytes > limit) {
    throw const FormatException('PDF predictor row exceeds the limit.');
  }
  if (predictor == 2) {
    if (bytes.length % rowBytes != 0) {
      throw const FormatException('Truncated TIFF predictor row.');
    }
    final Uint8List output = Uint8List.fromList(bytes);
    final int mask = (1 << bits) - 1;
    for (int row = 0; row < bytes.length; row += rowBytes) {
      final List<int> previous = List.filled(colors, 0);
      for (int sample = 0; sample < samples; sample++) {
        final int bit = sample * bits;
        final int offset = row + bit ~/ 8;
        final int shift = 8 - bits - bit % 8;
        final int encoded = bits == 16 ? bytes[offset] << 8 | bytes[offset + 1] : (bytes[offset] >> shift) & mask;
        final int value = (encoded + previous[sample % colors]) & mask;
        previous[sample % colors] = value;
        if (bits == 16) {
          output[offset] = value >> 8;
          output[offset + 1] = value & 255;
        } else {
          output[offset] = (output[offset] & ~(mask << shift)) | value << shift;
        }
      }
    }
    return output;
  }
  if (predictor < 10 || predictor > 15 || bytes.length % (rowBytes + 1) != 0) {
    throw const FormatException('Invalid PNG predictor or row length.');
  }
  final int rows = bytes.length ~/ (rowBytes + 1);
  final Uint8List output = Uint8List(rows * rowBytes);
  for (int row = 0; row < rows; row++) {
    final int filter = bytes[row * (rowBytes + 1)];
    for (int column = 0; column < rowBytes; column++) {
      final int target = row * rowBytes + column;
      final int left = column >= pixelBytes ? output[target - pixelBytes] : 0;
      final int up = row > 0 ? output[target - rowBytes] : 0;
      final int upperLeft = row > 0 && column >= pixelBytes ? output[target - rowBytes - pixelBytes] : 0;
      final int adjustment = switch (filter) {
        0 => 0,
        1 => left,
        2 => up,
        3 => (left + up) ~/ 2,
        4 => _paeth(left, up, upperLeft),
        _ => throw const FormatException('Invalid PNG predictor filter.'),
      };
      output[target] = (bytes[row * (rowBytes + 1) + column + 1] + adjustment) & 255;
    }
  }
  return output;
}

/// Selects PNG's closest neighboring predictor sample.
int _paeth(int left, int up, int upperLeft) {
  final int prediction = left + up - upperLeft;
  final int leftDistance = (prediction - left).abs();
  final int upDistance = (prediction - up).abs();
  final int diagonalDistance = (prediction - upperLeft).abs();
  return leftDistance <= upDistance && leftDistance <= diagonalDistance
      ? left
      : upDistance <= diagonalDistance
      ? up
      : upperLeft;
}
